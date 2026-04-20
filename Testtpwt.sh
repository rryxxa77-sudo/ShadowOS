#!/bin/bash
set -e

# --- Core Setup ---
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
ui_header() { clear; gum style --foreground 39 --border double --margin "1 1" --padding "1 2" "SHADOWOS: $1"; }
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. Identity ---
ui_header "Identity"
HOSTNAME="shadow"
USERNAME=$(gum input --placeholder "Username")
PASS=$(gum input --password --placeholder "Password")
ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"

# --- 2. Regional & Keyboard ---
ui_header "Regional"
KEYMAP=$(localectl list-keymaps | gum filter --placeholder "Select Layout")
loadkeys "$KEYMAP"
LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter)
TIMEZONE=$(timedatectl list-timezones | gum filter)

# --- 3. Storage & Memory ---
ui_header "Storage"
DEVICE=$(lsblk -dno NAME,SIZE,MODEL | gum filter | awk '{print "/dev/"$1}')
FS_TYPE=$(gum choose "btrfs" "f2fs" "ext4")
MODE=$(gum choose "Wipe (2GB EFI)" "Manual (cfdisk)")
SWAP_CHOICE=$(gum choose "Both (zRAM + 4GB Swap + Hibernation)" "zRAM Only" "None")

# --- 4. Desktop Selection ---
ui_header "Desktop Selection"
DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "Cinnamon" "LXQt" "None (CLI)")

# --- 5. Performance ---
ui_header "Mirror Optimization"
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

ui_header "Kernel Selection"
KERNELS=$(gum choose --no-limit --header "Select Kernels" "linux-zen" "linux" "linux-lts")
KERNEL_LIST=$(echo "$KERNELS" | tr '\n' ' ')

# --- 6. The Master App List ---
REPO_APPS="steam power-profiles-daemon mangohud protontricks discord flatpak spotify micro fastfetch kitty popsicle gparted networkmanager"
AUR_APPS="atlauncher-bin faugus-launcher hytale-launcher-bin obsidian-bin bazaar zen-browser-bin vacuumtube krita-git goverlay heroic-games-launcher-bin protonplus onlyoffice-bin shelly-bin lact-git fresh"

# --- Execution ---
clear
gum style --foreground 196 "STARTING FULL INSTALL ON $DEVICE"
gum confirm "Proceed?" || exit 1

# --- Partitioning ---
if [[ "$MODE" == "Wipe (2GB EFI)" ]]; then
    sgdisk -Z "$DEVICE"
    sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    partprobe "$DEVICE" && sleep 5
    
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        P1="${DEVICE}p1"; P2="${DEVICE}p2"
    else
        P1="${DEVICE}1"; P2="${DEVICE}2"
    fi
else
    cfdisk "$DEVICE"
    P1=$(gum input --placeholder "Enter EFI Partition Path")
    P2=$(gum input --placeholder "Enter Root Partition Path")
fi

# Formatting & Mounts
mkfs.fat -F32 "$P1"
if [[ "$FS_TYPE" == "btrfs" ]]; then
    mkfs.btrfs -f "$P2"
    mount "$P2" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && btrfs subvolume create /mnt/@swap
    umount /mnt
    mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
    mkdir -p /mnt/{home,boot}
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && mkdir -p /mnt/swap && mount -o subvol=@swap,noatime "$P2" /mnt/swap
    mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
else
    mkfs.$FS_TYPE -F "$P2"
    mount "$P2" /mnt
    mkdir -p /mnt/boot
fi
mount "$P1" /mnt/boot

# Base Install
pacstrap /mnt base base-devel linux-firmware git fish sudo networkmanager btrfs-progs $KERNEL_LIST $REPO_APPS
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
    set -e
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc
    echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf && echo "$HOSTNAME" > /etc/hostname

    # Desktop Setup
    case "$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin kate ;;
        "GNOME") pacman -S --noconfirm gnome gnome-tweaks ;;
        "Cinnamon") pacman -S --noconfirm cinnamon lightdm lightdm-gtk-greeter kate ;;
        "LXQt") pacman -S --noconfirm lxqt sddm ;;
    esac

    # Enable DM
    [[ "$DE_CHOICE" == "KDE Plasma" || "$DE_CHOICE" == "LXQt" ]] && systemctl enable sddm
    [[ "$DE_CHOICE" == "GNOME" ]] && systemctl enable gdm
    [[ "$DE_CHOICE" == "Cinnamon" ]] && systemctl enable lightdm

    # Install Yay
    sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

    # Memory Setup
    if [[ "$SWAP_CHOICE" == *"Swap"* ]]; then
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            truncate -s 0 /swap/swapfile && chattr +C /swap/swapfile
            btrfs property set /swap/swapfile compression none
            dd if=/dev/zero of=/swap/swapfile bs=1M count=4096 status=progress
            chmod 600 /swap/swapfile && mkswap /swap/swapfile && swapon /swap/swapfile
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        else
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
            chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            echo "/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
    fi

    if [[ "$SWAP_CHOICE" == *"zRAM"* ]]; then
        pacman -S --noconfirm zram-generator
        echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
    fi

    # AUR App Installation
    for pkg in $AUR_APPS; do
        sudo -u $USERNAME yay -S --noconfirm --needed \$pkg || echo "Failed: \$pkg"
    done

    # Power Profile Performance
    systemctl enable power-profiles-daemon
    echo "performance" > /sys/firmware/acpi/platform_profile || true

    # Initramfs & Boot
    HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && HOOKS=\$(echo \$HOOKS | sed 's/block/block resume/')
    [[ "$FS_TYPE" == "btrfs" ]] && HOOKS="\$HOOKS btrfs"
    sed -i "s/^HOOKS=(.*)/HOOKS=(\$HOOKS)/" /etc/mkinitcpio.conf
    mkinitcpio -P

    useradd -m -G wheel -s /usr/bin/fish $USERNAME
    echo "$USERNAME:$PASS" | chpasswd
    echo "root:$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    bootctl install
    MAIN_KERN=\$(echo $KERNEL_LIST | awk '{print \$1}')
    OPTIONS="root=PARTUUID=\$(blkid -s PARTUUID -o value $P2) rw"
    [[ "$FS_TYPE" == "btrfs" ]] && OPTIONS="\$OPTIONS rootflags=subvol=@"
    echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /boot/loader/loader.conf
    echo -e "title ShadowOS\nlinux /vmlinuz-\$MAIN_KERN\ninitrd /initramfs-\$MAIN_KERN.img\noptions \$OPTIONS" > /boot/loader/entries/arch.conf

    systemctl enable NetworkManager
    sed -i 's/NOPASSWD: //' /etc/sudoers.d/10-shadow
EOF

ui_header "Installation Complete! Rebooting now."
