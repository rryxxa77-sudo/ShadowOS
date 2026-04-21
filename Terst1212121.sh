#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT
set -eo pipefail

# --- 0. Pre-Flight ---
echo "Verifying network connectivity..."
ping -c 3 archlinux.org >/dev/null 2>&1 || { echo "ERROR: No internet."; exit 1; }

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux"
}

# --- 1. System Configuration ---
ui_banner
USERNAME=$(gum input --placeholder "Username")
PASS=$(gum input --password --placeholder "User Password")
ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"
HOSTNAME="shitsmell"

ui_banner
LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter --placeholder "Select Locale")
LOCALE_ESC="${LOCALE//./\\.}"
TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")
KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")
DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "XFCE" "Cinnamon" "Budgie" "MATE" "LXQt")

# --- 2. Storage Strategy ---
ui_banner
DEVICE_INFO=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop" | gum filter --placeholder "Select target drive")
DEVICE="/dev/$(echo $DEVICE_INFO | awk '{print $1}')"

STRATEGY=$(gum choose "Erase Disk" "Manual Partitioning" "Replace Partition")

if [[ "$STRATEGY" == "Erase Disk" ]]; then
    sgdisk -Z "$DEVICE"
    sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    if [[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]]; then
        P1="${DEVICE}p1"; P2="${DEVICE}p2"
    else
        P1="${DEVICE}1"; P2="${DEVICE}2"
    fi
elif [[ "$STRATEGY" == "Manual Partitioning" ]]; then
    cfdisk "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Root Partition")
else
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition (Existing)")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Partition to REPLACE with Root")
    gum style --foreground 196 "CAUTION: $P2 will be formatted. EFI ($P1) will be preserved."
    gum confirm "Proceed with replacement?" || exit 1
fi

# --- 3. Formatting & Mounting ---
gum confirm "Format target partitions now?" || exit 1

# Preservation Logic: Only format EFI if we are wiping the disk or setting up manually
if [[ "$STRATEGY" != "Replace Partition" ]]; then
    mkfs.fat -F32 "$P1"
fi

case "$FS_TYPE" in
    "btrfs")
        mkfs.btrfs -f "$P2"
        mount "$P2" /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        umount /mnt
        mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
        mkdir -p /mnt/{home,boot}
        mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
        ;;
    "xfs")
        mkfs.xfs -f "$P2"
        mount "$P2" /mnt
        mkdir -p /mnt/boot
        ;;
    "f2fs")
        mkfs.f2fs -f "$P2"
        mount -o noatime "$P2" /mnt
        mkdir -p /mnt/boot
        ;;
    "ext4")
        mkfs.ext4 -F "$P2"
        mount "$P2" /mnt
        mkdir -p /mnt/boot
        ;;
esac

mount "$P1" /mnt/boot

# --- 4. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers $(grep -q "GenuineIntel" /proc/cpuinfo && echo "intel-ucode" || echo "amd-ucode") bluez bluez-utils f2fs-tools xfsprogs
genfstab -U /mnt >> /mnt/etc/fstab

# --- 5. Chroot ---
arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    pacman -Syu --noconfirm

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc
    sed -i "s/#$LOCALE_ESC/$LOCALE/" /etc/locale.gen && locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf && echo "KEYMAP=us" > /etc/vconsole.conf
    echo "$HOSTNAME" > /etc/hostname
    # Set OS Name in os-release
    sed -i 's/^NAME=.*/NAME="Shitsmell Linux"/' /etc/os-release
    sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Shitsmell Linux"/' /etc/os-release

    # Optional: Change the lsb-release as well for compatibility
    echo "DISTRIB_ID=Shitsmell" > /etc/lsb-release
    echo "DISTRIB_RELEASE=rolling" >> /etc/lsb-release
    echo "DISTRIB_DESCRIPTION=\"Shitsmell Linux\"" >> /etc/lsb-release
    echo -e "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t$HOSTNAME.localdomain\t$HOSTNAME" > /etc/hosts

    useradd -m -G wheel -s /usr/bin/fish $USERNAME
    printf '%s:%s\n' "$USERNAME" "$PASS" | chpasswd
    printf 'root:%s\n' "$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow && chmod 440 /etc/sudoers.d/10-shadow

    case "$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin plasma-nm bluedevil; DM="sddm" ;;
        "GNOME") pacman -S --noconfirm gnome gnome-tweaks gdm; DM="gdm" ;;
        "XFCE") pacman -S --noconfirm xfce4 xfce4-goodies sddm; DM="sddm" ;;
        "Cinnamon") pacman -S --noconfirm cinnamon sddm nemo; DM="sddm" ;;
        "Budgie") pacman -S --noconfirm budgie sddm; DM="sddm" ;;
        "MATE") pacman -S --noconfirm mate mate-extra sddm; DM="sddm" ;;
        "LXQt") pacman -S --noconfirm lxqt sddm; DM="sddm" ;;
    esac
    systemctl enable \$DM NetworkManager bluetooth

    # --- FIX: Ensure flatpak is installed before using it ---
    pacman -S --noconfirm flatpak

    # CachyOS Integration
    curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
    tar xvf cachyos-repo.tar.xz && cd cachyos-repo
    sed -i 's/pacman -Sy/pacman --noconfirm -Sy/g' cachyos-repo.sh
    sed -i 's/pacman -S/pacman --noconfirm -S/g' cachyos-repo.sh
    yes | ./cachyos-repo.sh || true
    cd .. && rm -rf cachyos-repo*

    # Performance
    pacman -Syu --noconfirm
    pacman -S --noconfirm chwd power-profiles-daemon zram-generator
    chwd -a || true
    systemctl enable power-profiles-daemon
    echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

    # AUR & Apps
    su - $USERNAME -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"
    su - $USERNAME -c "yay -S --noconfirm --needed steam atlauncher-bin faugus-launcher hytale-launcher-bin mangohud protontricks obsidian-bin discord bazaar micro fastfetch zen-browser-bin vacuumtube krita goverlay heroic-games-launcher-bin protonplus kitty onlyoffice-bin gpu-screen-recorder shelly-bin lact-bin kate gparted pipewire-pulse || true"
    
    # Bootloader
    bootctl install
    echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /boot/loader/loader.conf
    ROOT_UUID=\$(blkid -s PARTUUID -o value $P2)
    
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        OPTS="root=PARTUUID=\$ROOT_UUID rootflags=subvol=@ rw quiet"
    else
        OPTS="root=PARTUUID=\$ROOT_UUID rw quiet"
    fi

    cat <<EOT > /boot/loader/entries/arch.conf
title   Shitsmell Linux
linux   /vmlinuz-$KERN_PKG
initrd  /$(grep -q "GenuineIntel" /proc/cpuinfo && echo "intel-ucode" || echo "amd-ucode").img
initrd  /initramfs-$KERN_PKG.img
options \$OPTS
EOT

    mkinitcpio -P && bootctl update
    # (Existing bootloader commands)
    mkinitcpio -P && bootctl update

    # ---Finishing Install & QoL ---
    # 1. Configure Fish (No Greeting + Auto-Fastfetch)
    mkdir -p /etc/skel/.config/fish
    echo -e "set -g fish_greeting\nfastfetch" > /etc/skel/.config/fish/config.fish

    # 2. Apply to primary user
    mkdir -p /home/$USERNAME/.config/fish
    cp /etc/skel/.config/fish/config.fish /home/$USERNAME/.config/fish/config.fish
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/fish

    # 2. Gaming & System Apps
    su - $USERNAME -c "yay -S --noconfirm plasma-pa lact proton-vpn-gtk-app lutris opengamepadui-bin filelight arch-update cachyos-hello"

    # 3. Flatpak Setup
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub com.dec05eba.gpu_screen_recorder com.usebottles.bottles org.kde.Platform//6.10 io.qt.qtwebengine.BaseApp//6.10

    # 4. Trinity Launcher
    flatpak remote-add --if-not-exists trinity https://github.com/Trinity-LA/Trinity-Launcher/releases/download/flatpak/com.trench.trinity.launcher.flatpakrepo
    flatpak install -y trinity com.trench.trinity.launcher

    # 5. Enable Hardware Daemons
    systemctl enable lactd

EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux has been deployed successfully."
gum confirm "Reboot?" && reboot
