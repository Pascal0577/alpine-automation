#!/bin/sh

# TODO: Add Plymouth support

root_uuid=""
crypt_uuid=""
crypt_name=""

use_zram="false"
zram_size="100%"
zram_compression="zstd"

boot_type="default_boot"
squashfs_version="upperfs"

full_ramdisk=0

emergency_shell() {
    printf "[ERROR]: %s\n" "$1">&2
    echo "Dropping to emergency shell..."
    setsid sh -c 'sh -i </dev/console >/dev/console 2>&1'
    exit 0
}

log_info() {
    printf "[INFO]: %s\n" "$1"
}

log_warn() {
    printf "[WARNING]: %s\n" "$1">&2
    return 1
}

safe_mount() {
    src="$1"
    dest="$2"

    mount "$src" "$dest" || emergency_shell "Failed to mount $src to $dest"
}

parse_cmdline() {
    # Read the root UUID from /proc/cmdline
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            full_ramdisk=*)
                full_ramdisk="${arg#full_ramdisk=}"
                log_info "Using a full ramdisk" ;;
            squashfs_version=*)
                squashfs_version=${arg#"squashfs_version="}
                log_info "Using image: $squashfs_version.squashfs" ;;
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

load_modules() {
    depmod -a
    echo "/sbin/mdev" > /proc/sys/kernel/hotplug
    mdev -s

    # Load necessary kernel modules
    modprobe loop &
    modprobe sd_mod &
    modprobe ehci_hcd &
    modprobe xhci_hcd &
    modprobe xhci_pci &
    modprobe usbhid &
    modprobe usb-storage &
    modprobe vfat &
    modprobe nls_cp437 &
    modprobe overlay &
    modprobe squashfs &
    modprobe ext4 & 
    modprobe mbcache &
    modprobe jbd2 &

    # Load zram module if needed
    [ "$use_zram" = "true" ] && modprobe zram &

    # Load kernel modules for decryption if needed
    [ -n "$crypt_uuid" ] && {
        modprobe dm-crypt &
        modprobe dm-mod &
    }
}

wait_for_devices() {
  # Wait until block devices are populated
  mkdir -p /dev/disk/by-uuid/ 2>/dev/null || true
  for i in $(seq 1 200); do
      for uuid in /dev/disk/by-uuid/*; do
        [ -e "$uuid" ] && {
          return 0
        }
      done
      sleep 0.05
  done

  emergency_shell "No filesystems found. /dev/disk/by-uuid/ is empty."
}

# Setup zram block device for overlay upper directory
setup_zram() {
    if [ "$use_zram" = "true" ]; then
        log_info "Setting up zram for overlay upper directory..."

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
            echo "$zram_compression" > /sys/block/zram0/comp_algorithm 2>/dev/null \
              || log_warn "Failed to set zram compression to $zram_compression, using default"
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

open_encrypted_filesystem() {
    for i in 1 2 3; do
        if cryptsetup open --type luks UUID="$1" "$2"; then
            return 0
        else
            echo "Could not open filesystem. Try again."
        fi
    done
    return 1
}

mount_device() {
    # Try to decrypt the filesystem if needed
    if [ -n "$crypt_uuid" ]; then
        open_encrypted_filesystem "$crypt_uuid" "$crypt_name" \
            || emergency_shell "Failed to open encrypted filesystem. Exiting."
        mount "/dev/mapper/$crypt_name" /mnt \
            || emergency_shell "Failed to mount /dev/mapper/$crypt_name"
        return 0
    fi

    # Attempt to mount filesystem based off UUID
    mount "/dev/disk/by-uuid/$root_uuid" /mnt
}

setup_overlay() {
    mkdir -p /sysroot/upper \
        /sysroot/rootfs \
        /sysroot/overlay_root \
        /sysroot/modules

    # Use a zram device for upperfs if enabled, otherwise use tmpfs
    if [ "$use_zram" = "true" ] && setup_zram; then
        safe_mount /dev/zram0 /sysroot/upper
        log_info "Using zram for overlayfs upperdir"
    else
        mount -t tmpfs -o size=100% tmpfs /sysroot/upper/
        log_info "Using tmpfs for overlayfs upperdir"
    fi

    mkdir -p /sysroot/upper/upper /sysroot/upper/work

    if [ "$full_ramdisk" = 0 ]; then
        mount -t squashfs /mnt/rootfs.squashfs /sysroot/rootfs -o loop \
            || emergency_shell "Failed to mount rootfs.squashfs"
        mount -t squashfs "/mnt/modules-$(uname -r).squashfs" /sysroot/modules \
            || emergency_shell "Failed to mount modules-$(uname -r).squashfs"
    elif [ "$full_ramdisk" = 1 ]; then
        mount -t tmpfs tmpfs /sysroot/rootfs \
            || emergency_shell "Failed to make tmpfs on /sysroot/rootfs"
        mount -t tmpfs tmpfs /sysroot/modules \
            || emergency_shell "Failed to make tmpfs on /sysroot/modules"
        unsquashfs -f -d /sysroot/rootfs/ /mnt/rootfs.squashfs
        unsquashfs -f -d /sysroot/modules/ "/mnt/modules-$(uname -r).squashfs"
    fi


    # Extract upper filesystem if it exists and we aren't doing a clean boot
    if [ "$boot_type" != "clean_boot" ]; then
        if [ -f "/mnt/$squashfs_version.squashfs" ]; then
            unsquashfs -f -d /sysroot/upper/upper "/mnt/$squashfs_version.squashfs" \
              || emergency_shell "Failed to unsquash $squashfs_version.squashfs"
        elif [ -f "/mnt/$squashfs_version-backup.squashfs" ]; then  
            # Try backup boot if we can't default boot
            log_warn "/mnt/$squashfs_version.squashfs not found. Trying backup."
            boot_type="backup_boot"
            unsquashfs -f -d /sysroot/upper/upper /mnt/upperfs-backup.squashfs \
              || emergency_shell "Failed to unsquash upperfs-backup.squashfs"
        else
            # Fallback to clean boot if we can't backup boot
            log_warn "Backup not found. Starting clean boot."
            boot_type="clean_boot"
        fi
    fi

    mount -t overlay overlay -o lowerdir=/sysroot/modules:/sysroot/rootfs,upperdir=/sysroot/upper/upper,workdir=/sysroot/upper/work /sysroot/overlay_root \
        || emergency_shell "Failed to create overlay filesystem"

    umount /mnt
}

setup_switchroot() {
    mkdir -p /sysroot/overlay_root/persist
    mount --move /proc /sysroot/overlay_root/proc
    mount --move /sys /sysroot/overlay_root/sys
    mount --move /dev /sysroot/overlay_root/dev

    [ "$full_ramdisk" = 0 ] && {
        mount --move /mnt /sysroot/overlay_root/persist

        # Makes upperdir and lowerdir accessible from new root
        mkdir -p /sysroot/overlay_root/mnt/rootfs
        mount --move /sysroot/rootfs /sysroot/overlay_root/mnt/rootfs

        mkdir -p /sysroot/overlay_root/mnt/modules
        mount --move /sysroot/modules /sysroot/overlay_root/mnt/modules

        # If clean boot is active, then make sure the upperdir lives in a place it won't be squashed
        if [ "$boot_type" = "clean_boot" ]; then
            mkdir -p /sysroot/overlay_root/mnt/upperdir-nosave
            mount --bind /sysroot/upper/upper /sysroot/overlay_root/mnt/upperdir-nosave
        else
            mkdir -p /sysroot/overlay_root/mnt/upperdir
            mount --bind /sysroot/upper/upper /sysroot/overlay_root/mnt/upperdir
        fi
    }
}

main() {
    /bin/busybox --install -s 

    mount -t proc none /proc
    mount -t sysfs none /sys
    mount -t devtmpfs none /dev

    parse_cmdline
    
    load_modules

    wait_for_devices

    mkdir /mnt 2>/dev/null || true

    mount_device

    setup_overlay

    setup_switchroot

    log_info "BOOT TYPE IS: $boot_type"

    exec switch_root /sysroot/overlay_root /sbin/init
}

# Dispatch
main "$@"
