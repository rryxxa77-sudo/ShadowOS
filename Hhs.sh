#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT
set -eo pipefail

# --- 0. Pre-Flight ---
ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux"
}

ui_banner
echo "Verifying network connectivity..."

# Internet Setup TUI
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "No internet detected. Setting up connection..."
    NET_TYPE=$(gum choose "Ethernet (Already connected)" "Wi-Fi Scan")
    if [[ "$NET_TYPE" == "Wi-Fi Scan" ]]; then
        nmcli dev wifi rescan
        SSID=$(nmcli -t -f SSID dev wifi list | grep -v '^--' | grep . | sort -u | gum filter --placeholder "Select Wi-Fi Network")
        PASS=$(gum input --password --placeholder "Enter Wi-Fi Password")
        nmcli dev wifi connect "$SSID" password "$PASS" || { echo "Connection failed!"; exit 1; }
    fi
fi

ping -c 3 archlinux.org >/dev/null 2>&1 || { echo "ERROR: No internet."; exit 1; }

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

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

# Keyboard Layout Picker
KBD_LAYOUT=$(localectl list-keymaps | gum filter --placeholder "Select Keyboard Layout")

TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")
KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")

# Swap Logic Selection
SWAP_STRATEGY=$(gum choose "Only ZRAM" "Only Swapfile" "Both" "None")
ZRAM_SIZE="0"
SWAPFILE_SIZE="0"

if [[ "$SWAP_STRATEGY" == "Only ZRAM" || "$SWAP_STRATEGY" == "Both" ]]; then
    ZRAM_SIZE=$(gum input --placeholder "ZRAM size in MB (e.g. 8192)")
fi
if [[ "$SWAP_STRATEGY" == "Only Swapfile" || "$SWAP_STRATEGY" == "Both" ]]; then
    SWAPFILE_SIZE=$(gum input --placeholder "Swapfile size in GB (e.g. 16)")
fi

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

# Swapfile Logic
if [[ "$SWAPFILE_SIZE" != "0" ]]; then
    echo "Creating Swapfile..."
    truncate -s 0 /mnt/swapfile
    [[ "$FS_TYPE" == "btrfs" ]] && chattr +C /mnt/swapfile
    fallocate -l "${SWAPFILE_SIZE}G" /mnt/swapfile
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
fi

# --- 4. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers $(grep -q "GenuineIntel" /proc/cpuinfo && echo "intel-ucode" || echo "amd-ucode") bluez bluez-utils f2fs-tools xfsprogs
genfstab -U /mnt >> /mnt/etc/fstab

# Add swapfile to fstab if created
[[ "$SWAPFILE_SIZE" != "0" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- 5. Chroot ---
arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    pacman -Syu --noconfirm

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc
    sed -i "s/#$LOCALE_ESC/$LOCALE/" /etc/locale.gen && locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf
    echo "KEYMAP=$KBD_LAYOUT" > /etc/vconsole.conf
    echo "$HOSTNAME" > /etc/hostname
    
    sed -i 's/^NAME=.*/NAME="Shitsmell Linux"/' /etc/os-release
    sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Shitsmell Linux"/' /etc/os-release

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

    pacman -S --noconfirm flatpak

    # --- MANUAL CACHYOS REPO SETUP ---
    echo "Configuring CachyOS repositories..."
    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47

    CACHYOS_MIRROR="https://mirror.cachyos.org/repo/x86_64/cachyos"
    get_pkg() { curl -s "\$CACHYOS_MIRROR/" | grep -oP "(?<=href=\")\${1}[^\"]+\.pkg\.tar\.zst" | sort -V | tail -1; }

    pacman -U --noconfirm \
        "\$CACHYOS_MIRROR/cachyos-keyring-20240331-1-any.pkg.tar.zst" \
        "\$CACHYOS_MIRROR/\$(get_pkg cachyos-mirrorlist)" \
        "\$CACHYOS_MIRROR/\$(get_pkg cachyos-v3-mirrorlist)" \
        "\$CACHYOS_MIRROR/\$(get_pkg cachyos-v4-mirrorlist)"

    if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
        SUPPORTS_V4=\$(/lib/ld-linux-x86-64.so.2 --help | grep -c "x86-64-v4 (supported)" || true)
        SUPPORTS_V3=\$(/lib/ld-linux-x86-64.so.2 --help | grep -c "x86-64-v3 (supported)" || true)

        if [[ "\$SUPPORTS_V4" -gt 0 ]]; then
            printf '\n[cachyos-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n' >> /etc/pacman.conf
        fi
        if [[ "\$SUPPORTS_V3" -gt 0 ]]; then
            printf '\n[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n' >> /etc/pacman.conf
        fi
        printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' >> /etc/pacman.conf
    fi

    # Performance
    pacman -Syu --noconfirm
    pacman -S --noconfirm chwd power-profiles-daemon zram-generator
    chwd -a || true
    systemctl enable power-profiles-daemon
    
    # ZRAM Configuration
    if [[ "$ZRAM_SIZE" != "0" ]]; then
        echo -e "[zram0]\nzram-size = $ZRAM_SIZE\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
    fi

    # AUR & Apps
    su - $USERNAME -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"
    
    su - $USERNAME -c "yay -S --noconfirm --needed steam mangohud micro fastfetch vacuumtube krita kitty kate gparted pipewire-pulse"
    
    su - $USERNAME -c "yay -S --noconfirm obsidian-bin discord zen-browser-bin heroic-games-launcher-bin onlyoffice-bin lact-bin atlauncher-bin faugus-launcher hytale-launcher-bin protontricks goverlay protonplus gpu-screen-recorder shelly-bin || true"

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

    # Finishing QoL
    mkdir -p /etc/skel/.config/fish
    echo -e "set -g fish_greeting\nfastfetch" > /etc/skel/.config/fish/config.fish
    mkdir -p /home/$USERNAME/.config/fish
    cp /etc/skel/.config/fish/config.fish /home/$USERNAME/.config/fish/config.fish
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/fish

    su - $USERNAME -c "yay -S --noconfirm plasma-pa lact proton-vpn-gtk-app lutris opengamepadui-bin filelight arch-update cachyos-hello || true"

    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub com.dec05eba.gpu_screen_recorder com.usebottles.bottles org.kde.Platform//6.10 io.qt.qtwebengine.BaseApp//6.10

    flatpak remote-add --if-not-exists trinity https://github.com/Trinity-LA/Trinity-Launcher/releases/download/flatpak/com.trench.trinity.launcher.flatpakrepo
    flatpak install -y trinity com.trench.trinity.launcher

    systemctl enable lactd

EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux has been deployed successfully."
gum confirm "Reboot?" && reboot

