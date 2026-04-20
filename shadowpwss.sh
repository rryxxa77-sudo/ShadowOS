#!/bin/bash
set -e

# --- Core Setup ---
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
ui_header() { clear; gum style --foreground 39 --border double --margin "1 1" --padding "1 2" "SHADOWOS: $1"; }
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. Identity ---
ui_header "Identity"
HOSTNAME=$(gum input --placeholder "Hostname")
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

# --- 3. Storage & Memory Selection ---
ui_header "Storage"
DEVICE=$(lsblk -dno NAME,SIZE,MODEL | gum filter | awk '{print "/dev/"$1}')
FS_TYPE=$(gum choose "btrfs" "f2fs" "ext4")
MODE=$(gum choose "Wipe (2GB EFI)" "Manual (cfdisk)" "Replace Partition")

# Swap is required for Hibernation.
SWAP_CHOICE=$(gum choose "Both (zRAM + 4GB Swap + Hibernation)" "zRAM Only" "Swap Only (Hibernation Ready)" "None")

ENCRYPT=false
if gum confirm "Enable LUKS2 Disk Encryption?"; then
    ENCRYPT=true
    ENC_PASS=$(gum input --password --placeholder "Encryption Passphrase")
fi

# --- 4. Performance & Kernels ---
ui_header "Performance"
KERNELS=$(gum choose --no-limit --header "Select Kernels" "linux-fsync-nobara-bin" "linux-cachyos" "linux-zen" "linux")
KERNEL_LIST=$(echo "$KERNELS" | tr '\n' ' ')
[[ $(gum confirm "Rate mirrors?") ]] && reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- 5. App Suite ---
APPS="steam power-profiles-daemon atlauncher-bin faugus-launcher hytale-launcher-bin mangohud protontricks obsidian-bin discord flatpak bazaar spotify lact-git micro fresh fastfetch zen-browser-bin vacuumtube krita-git goverlay heroic-games-launcher-bin protonplus kitty popsicle onlyoffice-bin gpu-screen-recorder-ui-git shelly-bin kate gparted networkmanager"

# --- Execution ---
clear
gum style --foreground 196 "INITIALIZING INSTALL ON $DEVICE"
gum confirm "Proceed?" || exit 1

# --- Partition Naming ---
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
    P2=$(gum input --placeholder "Root Partition Path")
    P1=$(gum input --placeholder "EFI Partition Path")
fi

# LUKS Setup
if [ "$ENCRYPT" = true ]; then
    echo -n "$ENC_PASS" | cryptsetup luksFormat "$P2" -
    echo -n "$ENC_PASS" | cryptsetup open "$P2" cryptroot -
    REAL_ROOT="/dev/mapper/cryptroot"
else
    REAL_ROOT="$P2"
fi

# Formatting & Mounts
mkfs.fat -F32 "$P1"
if [[ "$FS_TYPE" == "btrfs" ]]; then
    mkfs.btrfs -f "$REAL_ROOT"
    mount "$REAL_ROOT" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && btrfs subvolume create /mnt/@swap
    umount /mnt
    mount -o subvol=@ "$REAL_ROOT" /mnt
    mkdir -p /mnt/{home,boot}
    [[ "$SWAP_CHOICE" == *"Swap"* ]] && mkdir -p /mnt/swap && mount -o subvol=@swap "$REAL_ROOT" /mnt/swap
    mount -o subvol=@home "$REAL_ROOT" /mnt/home
else
    mkfs.$FS_TYPE -F "$REAL_ROOT"
    mount "$REAL_ROOT" /mnt
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

    # --- CACHYOS REPO ---
    curl -O https://mirror.cachyos.org/cachyos-repo.sh
    chmod +x cachyos-repo.sh
    ./cachyos-repo.sh
    
    pacman -Syy --noconfirm --needed yay chwd zram-generator $KERNEL_LIST

    # --- SWAP & zRAM (Hibernation Logic) ---
    if [[ "$SWAP_CHOICE" == *"Swap"* ]]; then
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            truncate -s 0 /swap/swapfile
            chattr +C /swap/swapfile
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

    # --- INITRAMFS WITH RESUME HOOK ---
    if [ "$ENCRYPT" = true ]; then
        NEW_HOOKS="base systemd autodetect modconf sd-vconsole sd-keyboard block sd-encrypt filesystems"
    else
        NEW_HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
    fi
    
    # Hibernation needs the 'resume' hook
    if [[ "$SWAP_CHOICE" == *"Swap"* ]]; then
        NEW_HOOKS=\$(echo \$NEW_HOOKS | sed 's/block/block resume/')
    fi
    
    [[ "$FS_TYPE" == "btrfs" ]] && NEW_HOOKS="\${NEW_HOOKS} btrfs"
    sed -i "s/^HOOKS=(.*)/HOOKS=(\$NEW_HOOKS)/" /etc/mkinitcpio.conf
    mkinitcpio -P

    useradd -m -G wheel -s /usr/bin/fish $USERNAME
    echo "$USERNAME:$PASS" | chpasswd
    echo "root:$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    chwd -a
    for pkg in $APPS; do
        sudo -u $USERNAME bash -c "export HOME=/home/$USERNAME && yay -S --noconfirm --needed \$pkg" || echo "Failed: \$pkg"
    done

    # --- BOOTLOADER & KERNEL PARAMETERS ---
    MAIN_KERN=\$(echo $KERNEL_LIST | awk '{print \$1}')
    bootctl install
    
    if [ "$ENCRYPT" = true ]; then
        OPTIONS="rd.luks.name=\$(blkid -s UUID -o value $P2)=cryptroot root=/dev/mapper/cryptroot"
        RESUME_DEV="/dev/mapper/cryptroot"
    else
        OPTIONS="root=PARTUUID=\$(blkid -s PARTUUID -o value $P2)"
        RESUME_DEV="\$REAL_ROOT"
    fi

    # Calculate Resume Offset for Btrfs Hibernation
    if [[ "$SWAP_CHOICE" == *"Swap"* ]]; then
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            OFFSET=\$(btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print \$4}')
            OPTIONS="\$OPTIONS resume=\$RESUME_DEV resume_offset=\$OFFSET"
        else
            OPTIONS="\$OPTIONS resume=\$RESUME_DEV"
        fi
    fi

    [[ "$FS_TYPE" == "btrfs" ]] && OPTIONS="\$OPTIONS rootflags=subvol=@"
    echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /boot/loader/loader.conf
    echo -e "title ShadowOS\nlinux /vmlinuz-\$MAIN_KERN\ninitrd /initramfs-\$MAIN_KERN.img\noptions \$OPTIONS rw" > /boot/loader/entries/arch.conf

    systemctl enable NetworkManager power-profiles-daemon
    # TRIM is NOT enabled here by request.
    sed -i 's/NOPASSWD: //' /etc/sudoers.d/10-shadow
EOF

ui_header "ShadowOS Deployed!"
