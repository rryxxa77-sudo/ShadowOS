#!/bin/bash
set -e

# --- Initial Setup ---
[[ ! -f /usr/bin/gum ]] && pacman -Syu --noconfirm gum reflector
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- UI Branding ---
ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux" "System Deployment Utility"
}

# --- 1. User Configuration ---
ui_banner
USERNAME=$(gum input --placeholder "Username")
PASS=$(gum input --password --placeholder "User Password")
ROOT_PASS=$(gum input --password --placeholder "Root Password (leave blank to sync)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"
HOSTNAME="shitsmell"

# --- 2. Input Configuration ---
while true; do
    ui_banner
    echo "Keyboard Layout Selection"
    KEYMAP=$(localectl list-keymaps | gum filter --placeholder "Select system keymap...")
    loadkeys "$KEYMAP"
    
    echo "Type below to verify layout (Wait 15s):"
    echo "--------------------------------------"
    read -t 15 -p "Test keys: " TEST_INPUT || true
    echo -e "\n"
    
    if gum confirm "Does the keyboard layout work correctly?"; then
        break
    fi
done

# --- 3. Localization ---
ui_banner
echo "Locale & Timezone Selection"
LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter --placeholder "Select Locale")
TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")

ui_banner
echo "Current Time Preview:"
export TZ=$TIMEZONE
date '+%H:%M:%S - %d %B %Y'
sleep 10
gum confirm "Does the displayed time match your local clock?"

# --- 4. System Core & Desktop ---
ui_banner
echo "Kernel Selection"
KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")

echo "Desktop Environment Selection"
DE_CHOICE=$(gum choose "KDE Plasma (Recommended)" "GNOME" "XFCE")

echo "Swap Configuration"
SWAP_CHOICE=$(gum choose "Hybrid (zRAM + 4GB Swap)" "zRAM Only" "None")

# --- 5. Storage Configuration ---
ui_banner
echo "Storage Target Selection"
DEVICE=$(lsblk -dno NAME,SIZE,MODEL | gum filter --placeholder "Select target drive")
DEVICE="/dev/$(echo $DEVICE | awk '{print $1}')"

MODE=$(gum choose "Erase Disk" "Replace Partition" "Manual (cfdisk)")
FS_TYPE=$(gum choose "btrfs" "ext4" "f2fs")

# --- 6. Deployment Review ---
ui_banner
gum style --foreground 39 "Reviewing Configuration:"
echo "User:      $USERNAME"
echo "Kernel:    $KERN_PKG"
echo "Desktop:   $DE_CHOICE"
echo "Target:    $DEVICE ($MODE)"
echo "FS:        $FS_TYPE"
echo "Hardware:  chwd Auto-Driver, Bluetooth, WiFi, Power-Profiles"
echo ""
gum confirm "Begin installation? Data on $DEVICE will be overwritten."

# --- Execution ---
ui_banner
echo "Optimizing mirrors..."
reflector --latest 15 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- SMART PARTITIONING ENGINE ---
if [[ "$MODE" == "Erase Disk" ]]; then
    echo "Wiping $DEVICE..."
    sgdisk -Z "$DEVICE"
    echo "Creating EFI partition..."
    sgdisk -n 1:0:+1G -t 1:ef00 "$DEVICE"
    echo "Creating Root partition..."
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    
    # Force kernel to re-read partition table
    partprobe "$DEVICE"
    sleep 5 # Wait for dev nodes to settle
    
    # Intelligent Partition Naming Logic
    if [[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]]; then
        P1="${DEVICE}p1"
        P2="${DEVICE}p2"
    else
        P1="${DEVICE}1"
        P2="${DEVICE}2"
    fi
    
elif [[ "$MODE" == "Replace Partition" ]]; then
    P2=$(lsblk -lnp -o NAME,SIZE "$DEVICE" | gum filter --placeholder "Select partition to overwrite" | awk '{print $1}')
    P1=$(lsblk -lnp -o NAME,TYPE "$DEVICE" | grep "part" | grep -i "efi" | head -n1 | awk '{print $1}')
    [[ -z "$P1" ]] && P1=$(gum input --placeholder "Path to EFI partition (e.g. /dev/nvme0n1p1)")
else
    cfdisk "$DEVICE"
    P1=$(gum input --placeholder "EFI Partition Path (e.g. /dev/nvme0n1p1)")
    P2=$(gum input --placeholder "Root Partition Path (e.g. /dev/nvme0n1p2)")
fi

# Verify paths exist before formatting
if [[ ! -b "$P1" || ! -b "$P2" ]]; then
    echo "ERROR: Partition nodes not found. P1: $P1, P2: $P2"
    exit 1
fi

# Formatting
mkfs.fat -F32 "$P1"
if [[ "$FS_TYPE" == "btrfs" ]]; then
    mkfs.btrfs -f "$P2"
    mount "$P2" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    [[ "$SWAP_CHOICE" == "Hybrid"* ]] && btrfs subvolume create /mnt/@swap
    umount /mnt
    mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
    mkdir -p /mnt/{home,boot}
    [[ "$SWAP_CHOICE" == "Hybrid"* ]] && mkdir -p /mnt/swap && mount -o subvol=@swap,noatime "$P2" /mnt/swap
    mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
else
    mkfs.$FS_TYPE -F "$P2"
    mount "$P2" /mnt
    mkdir -p /mnt/boot
fi
mount "$P1" /mnt/boot

# --- Pacstrap ---
CORE_PKGS="base base-devel linux-firmware git fish sudo networkmanager btrfs-progs $KERN_PKG ${KERN_PKG}-headers bluez bluez-utils"
ALL_APPS="steam power-profiles-daemon atlauncher-bin faugus-launcher hytale-launcher-bin mangohud protontricks obsidian-bin discord flatpak bazaar micro fastfetch zen-browser-bin vacuumtube krita goverlay heroic-games-launcher-bin protonplus kitty onlyoffice-bin gpu-screen-recorder shelly-bin lact-bin kate gparted plasma-nm bluedevil pipewire-pulse"

pacstrap -K /mnt $CORE_PKGS
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
    set -e
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    
    pacman -Syu --noconfirm

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && hwclock --systohc
    echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf && echo "$HOSTNAME" > /etc/hostname

    useradd -m -G wheel -s /usr/bin/fish $USERNAME
    echo "$USERNAME:$PASS" | chpasswd
    echo "root:$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    case "$DE_CHOICE" in
        "KDE Plasma (Recommended)") pacman -Syu --noconfirm plasma-desktop sddm konsole dolphin plasma-nm ;;
        "GNOME") pacman -Syu --noconfirm gnome gnome-tweaks sddm network-manager-applet ;;
        "XFCE") pacman -Syu --noconfirm xfce4 xfce4-goodies sddm network-manager-applet ;;
    esac
    
    systemctl enable sddm NetworkManager bluetooth power-profiles-daemon

    sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

    sudo -u $USERNAME yay -Syu --noconfirm chwd
    chwd -a
    sudo -u $USERNAME yay -Syu --noconfirm --needed $ALL_APPS

    if [[ "$SWAP_CHOICE" == "Hybrid"* ]]; then
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            truncate -s 0 /swap/swapfile && chattr +C /swap/swapfile
            btrfs property set /swap/swapfile compression none
            dd if=/dev/zero of=/swap/swapfile bs=1M count=4096
            chmod 600 /swap/swapfile && mkswap /swap/swapfile && swapon /swap/swapfile
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        else
            dd if=/dev/zero of=/swapfile bs=1M count=4096
            chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            echo "/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
    fi
    [[ "$SWAP_CHOICE" != "None" ]] && pacman -Syu --noconfirm zram-generator && \
    echo -e "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

    mkinitcpio -P
    bootctl install
    OPTIONS="root=PARTUUID=\$(blkid -s PARTUUID -o value $P2) rw quiet splash"
    [[ "$FS_TYPE" == "btrfs" ]] && OPTIONS="\$OPTIONS rootflags=subvol=@"
    echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /boot/loader/loader.conf
    echo -e "title Shitsmell Linux\nlinux /vmlinuz-$KERN_PKG\ninitrd /initramfs-$KERN_PKG.img\noptions \$OPTIONS" > /boot/loader/entries/arch.conf
    bootctl update

    sed -i 's/NOPASSWD: //' /etc/sudoers.d/10-shadow
EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux Install Successful."
gum confirm "Reboot now?" && reboot

