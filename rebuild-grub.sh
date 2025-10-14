#!/bin/sh

readonly STATE_DIR="/run/rebuild-grub-$$"
readonly IMAGE_LIST="$STATE_DIR/image-list"
successful=0

set -e
trap cleanup EXIT INT TERM

log_error() {
    echo "[ERROR]: $1"
    exit 1
}

cleanup() {
    if [ "$successful" = 0 ]; then
        [ -f /boot/grub/grub.cfg.bak ] && mv /boot/grub/grub.cfg.bak /boot/grub/grub.cfg
        rm -rf "$STATE_DIR"
        exit 1
    elif [ "$successful" = 1 ]; then
        rm -rf "$STATE_DIR"
        exit 0
    fi
}

# Remove stinky boot_type and squashfs_version parameters from kernel command line
get_base_cmdline() {
    cmdline=""
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            boot_type=*|squashfs_version=*|BOOT_IMAGE=*)
                continue ;;
            clean_boot=1)
                exit 0 ;;
            *)
                cmdline="$cmdline $arg" ;;
        esac
    done
}

find_images() {
    # Finds anything with .squashfs on the USB, excluding system images
    find /persist -maxdepth 1 -name '*.squashfs' \
        ! -name '*-backup.squashfs' \
        ! -name 'rootfs.squashfs' \
        ! -name 'modules-*.squashfs' \
        > "$IMAGE_LIST" || log_error "In find_images: Getting list of squashfs failed"
}

generate_config() {
    IFS= read -r first_line < "$IMAGE_LIST"

    cat >> /boot/grub/grub.cfg << -EOF
        set timeout=10
        set default=0

-EOF

    while IFS= read -r line; do
    cat >> /boot/grub/grub.cfg << -EOF
        menuentry "Alpine Linux ($line)" {
            linux /vmlinuz-lts $cmdline squashfs_version=$line
            initrd /initramfs-lts
        }
-EOF
    done < "$IMAGE_LIST"

    cat >> /boot/grub/grub.cfg << -EOF

        menuentry "Alpine Linux (Clean Boot)" {
            linux /vmlinuz-lts $cmdline clean_boot=1
            initrd /initramfs-lts
        }

        menuentry "Alpine Linux (Full RAM disk $first_line)" {
            linux /vmlinuz-lts $cmdline full_ramdisk=1 squashfs_version=$first_line
            initrd /initramfs-lts
        }
-EOF
}

main() {
    mv /boot/grub/grub.cfg /boot/grub/grub.cfg.bak || exit 1
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    
    get_base_cmdline || log_error "Getting base cmdline failed"
    find_images || log_error "Finding images failed"
    generate_config || log_error "Generating config failed"

    successful=1
    cleanup
}

main
