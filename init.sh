#!/bin/sh

# TODO: Add LVM support and Plymouth support
# TODO: Add support for decryption via key file

red="\e[0;31m"
yellow="\e[0;33m"
green="\e[0;32m"
def="\e[0m"

root_uuid=""
root_dev=""
crypt_uuid=""
crypt_name=""
mount_needed="true"

use_zram="false"
zram_size="100%"
zram_compression="lz4"

boot_type="default_boot"
squashfs_version="upperfs.squashfs"

emergency_shell() {
    printf "%s[ERROR]%s: %s\n" "$red" "$def" "$1">&2
    echo "Dropping to emergency shell..."
    # setsid cttyhack sh
    setsid sh -c 'exec sh </dev/console >/dev/console 2>&1'
    exit 1
}

log_info() {
    printf "%s[INFO]%s: %s\n" "$green" "$def" "$1"
}

log_warn() {
    printf "%s[WARNING]%s: %s\n" "$yellow" "$def" "$1"
    return 1
}

safe_mount() {
    src="$1"
    dest="$2"

    if ! mount "$src" "$dest"; then
        emergency_shell "Failed to mount $src to $dest"
    fi
}

parse_cmdline() {
  # Read the root UUID from /proc/cmdline
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            root=UUID=*)
                root_uuid=${arg#"root=UUID="}
                log_info "Found filesystem with UUID $root_uuid" ;;
            zram|zram=*)
                use_zram=true
                if [ ! "$arg" = "zram" ]; then
                    zram_size=${arg#"zram="}
                fi
                log_info "Enabled zram with size: $zram_size" ;;
            zram.comp=*)
                zram_compression=${arg#"zram.comp="}
                log_info "zram compression: $zram_compression" ;;
            boot_type=*)
                boot_type=${arg#"boot_type="}
                log_info "boot_type: $boot_type" ;;
            cryptdevice=UUID=*)
                temp=${arg#"cryptdevice=UUID="}
                crypt_uuid=${temp%%:*}
                crypt_name=${temp#*:}
                log_info "Found LUKS2 encrypted filesystem with UUID $crypt_uuid" ;;
        esac
    done
}

# Mount all available filesystems and check for rootfs.squashfs. First filesystem to have it is returned
# TODO: Try to detect root based on filesystem type.
detect_root_fallback() {
    for dev in /dev/disk/by-uuid/*; do
        # Handle empty case
        [ ! -e "$dev" ] && continue  
        device=$(basename "$dev")

        # Skip trying to mount ram and loop devices
        case "$device" in
            loop*|ram*)
                continue ;;
        esac
 
        if ! mount "/dev/$device" /mnt 2>/dev/null; then
            log_warn "Could not mount $device. Skipping."
            continue
        fi
    
        if [ -f /mnt/rootfs.squashfs ]; then
            umount /mnt
            echo "$device"
            return 0
        fi
    
        umount /mnt
    done
    return 1
}

load_modules() {
    depmod -a
    echo "/sbin/mdev" > /proc/sys/kernel/hotplug
    mdev -s

    # Mystical, Magical, Nonsensical
    find /sys/ -name modalias -print0 | xargs -0 sort -u -z | xargs -0 modprobe -abq

    # Load necessary kernel modules. Don't judge me for how I did this
    modprobe loop
    modprobe simpledrm
    modprobe sd_mod
    modprobe ehci_hcd
    modprobe xhci_hcd
    modprobe xhci_pci
    modprobe usbhid
    modprobe usb-storage
    modprobe vfat
    modprobe nls_cp437
    modprobe overlay
    modprobe squashfs
    modprobe ext4
    modprobe mbcache
    modprobe jbd2

    # Load zram module if needed
    [ "$use_zram" = "true" ] && modprobe zram

    # Load kernel modules for decryption if needed
    [ -n "$crypt_uuid" ] && modprobe dm-crypt
}

# Setup zram block device for overlay upper directory
setup_zram() {
    if [ "$use_zram" = "true" ]; then
        log_info "Setting up zram for overlay upper directory..."
    
        # Check if zram device exists
        if [ ! -b /dev/zram0 ]; then
            log_warn "zram device not available, attempting to load zram module..."
            modprobe zram 2>/dev/null || {
                log_warn "Failed to set up zram device. Falling back to tmpfs"
                return 1
            }
        fi
    
        # Calculate zram size based on configuration
        case "$zram_size" in
            *%)
                # Get total memory in KB
                total_mem=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

                percent=${zram_size%\%}
                zram_size=$((total_mem * percent / 100)) ;;
            *M|*m)
                zram_size=$((${zram_size%[Mm]} * 1024)) ;;
            *G|*g)
                zram_size=$((${zram_size%[Gg]} * 1024 * 1024)) ;;
            *) :;;
        esac
    
        # Set compression algorithm
        if [ -w /sys/block/zram0/comp_algorithm ]; then
            echo "$zram_compression" > /sys/block/zram0/comp_algorithm 2>/dev/null || log_warn "Failed to set zram compression to $zram_compression, using default"
        fi
    
        # Set device size
        echo "${zram_size}K" > /sys/block/zram0/disksize || {
            log_warn "Failed to set zram size, falling back to tmpfs"
            return 1
        }
    
        # Create filesystem on zram device
        if mkfs.ext4 /dev/zram0 2>/dev/null; then
            log_info "Created ext4 filesystem on zram device (${zram_size}K)"
            return 0
        else
            log_warn "Failed to create filesystem on zram, falling back to tmpfs"
            return 1
        fi
    fi
  
    return 1
}

# TODO: Add support for keyfiles
open_encrypted_filesystem() {
    for i in $(seq 1 3); do
        if cryptsetup open --type luks UUID="$1" "$2"; then
            return 0
        fi
        echo "Could not open filesystem. Try again."
    done
    return 1
}

mount_device() {
    # Try to decrypt the filesystem if needed
    if [ -n "$crypt_uuid" ]; then
        open_encrypted_filesystem "$crypt_uuid" "$crypt_name" || emergency_shell "Failed to open encrypted filesystem. Exiting."
    fi

    # Attempt to mount filesystem based off UUID
    if mount "/dev/disk/by-uuid/$root_uuid" /mnt 2>/dev/null; then
        log_info "Mounting filesystem by UUID"
        mount_needed=false
    fi

    # Fallback if mounting via UUID is unavailable for whatever reason
    if [ "$mount_needed" = "true" ]; then
        if root_dev=$(detect_root_fallback); then
            safe_mount "/dev/$root_dev" /mnt
            log_info "Mounting /dev/$root_dev to /mnt by device name"
        else
            emergency_shell "No devices with rootfs.squashfs found"
        fi
    fi
    
    # safe_mount "/dev/sda2" /mnt

    return 0
}

set_squashfs_version() {
    case "$boot_type" in
        default_boot)
            squashfs_version="upperfs.squashfs" ;;
        backup_boot)
            squashfs_version="upperfs-backup.squashfs" ;;
    esac

    log_info "Squashfs type set to: $squashfs_version" 
}

setup_overlay() {
    mkdir -p /sysroot/upper/upper /sysroot/upper/work /sysroot/rootfs /sysroot/overlay_root /sysroot/firmware

    # Use a zram device for upperfs if enabled, otherwise use tmpfs
    if [ "$use_zram" = "true" ] && setup_zram; then
        safe_mount /dev/zram0 /sysroot/upper
        log_info "Using zram for overlayfs upperdir"
    else
        mount -t tmpfs -o size=100% tmpfs /sysroot/upper/
        log_info "Using tmpfs for overlayfs upperdir"
    fi

    mkdir -p /sysroot/upper/upper /sysroot/upper/work

    # Mount squashfs root filesystem. This is NOT in RAM.
    mount -t squashfs /mnt/rootfs.squashfs /sysroot/rootfs -o loop || emergency_shell "Failed to mount rootfs.squashfs"

    # Mount firmware filesystem
    mount -t squashfs /mnt/firmware.squashfs /sysroot/firmware || emergency_shell "Failed to mount firmware.squashfs"

    # Extract upper filesystem if it exists and we aren't doing a clean boot
    if [ ! "$boot_type" = "clean_boot" ]; then
        if [ -f /mnt/$squashfs_version ]; then
            unsquashfs -f -d /sysroot/upper/upper /mnt/$squashfs_version || emergency_shell "Failed to unsquash $squashfs_version"
        elif [ -f /mnt/upperfs-backup.squashfs ]; then  # Try backup boot if we can't default boot
            log_warn "/mnt/$squashfs_version not found. Trying backup."
            boot_type="backup_boot"
            unsquashfs -f -d /sysroot/upper/upper /mnt/upperfs-backup.squashfs || emergency_shell "Failed to unsquash upperfs-backup.squashfs"
        else  # Fallback to clean boot if we can't backup boot
            log_warn "Backup not found. Starting clean boot."
            boot_type="clean_boot"
        fi
    fi

    # Create overlay filesystem
    mount -t overlay overlay -o lowerdir=/sysroot/rootfs,upperdir=/sysroot/upper/upper,workdir=/sysroot/upper/work /sysroot/overlay_root || emergency_shell "Failed to create overlay filesystem"
}

setup_switchroot() {
    mkdir -p /sysroot/overlay_root/persist

    # Move mounts to new root
    mount --move /mnt /sysroot/overlay_root/persist
    mount --move /proc /sysroot/overlay_root/proc
    mount --move /sys /sysroot/overlay_root/sys
    mount --move /dev /sysroot/overlay_root/dev

    # Makes upperdir and lowerdir accessible from new root
    mkdir -p /sysroot/overlay_root/mnt/rootfs
    mount --move /sysroot/rootfs /sysroot/overlay_root/mnt/rootfs

    mkdir -p /sysroot/overlay_root/mnt/firmware
    mount --move /sysroot/firmware /sysroot/overlay_root/lib/firmware

    # If clean boot is active, then make sure the upperdir lives in a place it won't be squashed
    if [ "$boot_type" = "clean_boot" ]; then
        mkdir -p /sysroot/overlay_root/mnt/upperdir-nosave
        mount --bind /sysroot/upper/upper /sysroot/overlay_root/mnt/upperdir-nosave
    else
        mkdir -p /sysroot/overlay_root/mnt/upperdir
        mount --bind /sysroot/upper/upper /sysroot/overlay_root/mnt/upperdir
    fi
}

main() {
    /bin/busybox --install -s 

    mount -t proc none /proc
    mount -t sysfs none /sys
    mount -t devtmpfs none /dev

    parse_cmdline

    load_modules
  
    # Wait until block devices are populated
    for i in $(seq 1 100); do

        for block in /sys/class/block/*; do
            [ ! -e "$block" ] && break
            dev=$(basename "$block")

            case "$dev" in
                sd*|nvme*|mmc*|vd*)
                    found=true
                    log_info "Found block devices"
                    break 2 ;;
            esac
        done

        sleep 0.1
    done

    # If nothing was found after time limit then drop to shell
    if [ ! "$found" = "true" ]; then
        emergency_shell "No filesystems detected."
    fi

    mkdir /mnt

    sleep 1

    mount_device

    set_squashfs_version

    setup_overlay

    setup_switchroot

    log_info "BOOT TYPE IS: $boot_type"

    exec switch_root /sysroot/overlay_root /sbin/init || emergency_shell "Failed to switch root. Exiting."
}

# Dispatch
main "$@"
