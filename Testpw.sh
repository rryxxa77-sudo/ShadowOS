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

# --- 4. Performance ---
ui_header "Mirror Optimization"
reflector --latest 15 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

ui_header "Kernel Selection"
KERNELS=$(gum choose --no-limit --header "Select Kernels" "linux-fsync-nobara-bin" "linux-cachyos" "linux-zen")
KERNEL_LIST=$(echo "$KERNELS" | tr '\n' ' ')

# --- 5. App Suite ---
APPS="steam power-profiles-daemon mangohud protontricks obsidian-bin discord flatpak bazaar spotify lact-git micro fresh fastfetch zen-browser-bin vacuumtube krita-git goverlay heroic-games-launcher-bin protonplus kitty popsicle onlyoffice-bin gpu-screen-recorder-ui-git shelly-bin kate gparted networkmanager"

# --- Execution ---
clear
gum style --foreground 196 "STARTING INSTALL ON $DEVICE"
gum confirm "Proceed?" || exit 1

# --- Partitioning Logic ---
if [[ "$MODE" == "Wipe (2GB EFI)" ]]; then
    sgdisk -Z "$DEVICE"
    sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        P1="${DEVICE}p1"; P2="${DEVICE}p2"
    else
        P1="${DEVICE}1"; P2="${DEVICE}2"
    fi
else
    cfdisk "$DEVICE"
    P1=$(gum input --placeholder "Enter EFI Partition (e.g. /dev/nvme0n1p1)")
    P2=$(gum input --placeholder "Enter Root Partition (e.g. /dev/nvme0n1p2)")
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
pacstrap /mnt base base-devel linux-firmware git fish sudo networkmanager btrfs-progs
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
    set -e
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc
    echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf && echo "$HOSTNAME" > /etc/hostname

    # --- RELIABLE CACHYOS REPO SETUP ---
    # Fetching the keys and lists directly to avoid 404 script errors
    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47
    pacman -U --noconfirm https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst
    pacman -U --noconfirm https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst
    
    echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist" >> /etc/pacman.conf
    pacman -Syy --noconfirm --needed yay chwd zram-generator $KERNEL_LIST

    # --- SWAP / zRAM / HIBERNATION ---
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
        echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
    fi

    # Initramfs
    HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && HOOKS=\$(echo \$HOOKS | sed 's/block/block resume/')
    [[ "$FS_TYPE" == "btrfs" ]] && HOOKS="\$HOOKS btrfs"
    sed -i "s/^HOOKS=(.*)/HOOKS=(\$HOOKS)/" /etc/mkinitcpio.conf
    mkinitcpio -P

    # User Setup
    useradd -m -G wheel -s /usr/bin/fish $USERNAME
    echo "$USERNAME:$PASS" | chpasswd
    echo "root:$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    # App Installation
    chwd -a
    for pkg in $APPS; do
        sudo -u $USERNAME bash -c "export HOME=/home/$USERNAME && yay -S --noconfirm --needed \$pkg" || echo "Failed: \$pkg"
    done

    # Bootloader
    MAIN_KERN=\$(echo $KERNEL_LIST | awk '{print \$1}')
    bootctl install
    OPTIONS="root=PARTUUID=\$(blkid -s PARTUUID -o value $P2) rw"
    
    if [[ "$SWAP_CHOICE" == *"Swap"* ]]; then
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            OFFSET=\$(btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print \$4}')
            OPTIONS="\$OPTIONS resume=$P2 resume_offset=\$OFFSET"
        else
            OPTIONS="\$OPTIONS resume=$P2"
        fi
    fi

    [[ "$FS_TYPE" == "btrfs" ]] && OPTIONS="\$OPTIONS rootflags=subvol=@"
    echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /boot/loader/loader.conf
    echo -e "title ShadowOS\nlinux /vmlinuz-\$MAIN_KERN\ninitrd /initramfs-\$MAIN_KERN.img\noptions \$OPTIONS" > /boot/loader/entries/arch.conf

    systemctl enable NetworkManager power-profiles-daemon
    sed -i 's/NOPASSWD: //' /etc/sudoers.d/10-shadow
EOF

ui_header "ShadowOS Installed!"
