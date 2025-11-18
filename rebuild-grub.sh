#!/bin/sh

set -e

readonly STATE_DIR="/run/rebuild-grub-$$"
readonly IMAGE_LIST="$STATE_DIR/image-list"
readonly IMAGE_LIST_TMP="$STATE_DIR/image-list-tmp"
readonly GRUB_CFG="/boot/grub/grub.cfg"
readonly GRUB_BAK="/boot/grub/grub.cfg.bak"

successful=0

trap cleanup EXIT INT TERM

log_error() {
    echo "[ERROR]: $1" >&2
    exit 1
}

cleanup() {
    if [ "$successful" = 0 ]; then
        if [ -f "$GRUB_BAK" ]; then
            mv "$GRUB_BAK" "$GRUB_CFG"
        fi
    fi
    rm -rf "$STATE_DIR"
}

get_base_cmdline() {
    _cmdline=""
    
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            boot_type=*|squashfs_version=*|BOOT_IMAGE=*)
                continue ;;
            clean_boot=1|full_ramdisk=1)
                # Don't regenerate GRUB config if clean/ramdisk boot
                exit 0 ;;
            *)
                _cmdline="$_cmdline $arg" ;;
        esac
    done
    
    _cmdline="${_cmdline# }"
    echo "$_cmdline"
}

find_images() {
    mkdir -p "$STATE_DIR"
    
    find /persist -maxdepth 1 -name '*.squashfs' \
        ! -name '*-backup.squashfs' \
        ! -name 'rootfs.squashfs' \
        ! -name 'modules-*.squashfs' \
        > "$IMAGE_LIST_TMP" || log_error "Failed to find squashfs images"
    
    sed 's|^/persist/||' "$IMAGE_LIST_TMP" > "$IMAGE_LIST"
    
    if [ ! -s "$IMAGE_LIST" ]; then
        log_error "No bootable squashfs images found in /persist"
    fi
}

# Write GRUB config header
write_grub_header() {
    cat > "$GRUB_CFG" << 'EOF'
set timeout=10
set default=0

EOF
}

write_boot_entry() {
    _title="$1"
    _kernel="$2"
    _initrd="$3"
    _cmdline="$4"
    _extra_params="$5"
    
    cat >> "$GRUB_CFG" << EOF
menuentry "$_title" {
    linux $_kernel $_cmdline${_extra_params:+ }$_extra_params
    initrd $_initrd
}

EOF
}

generate_kernel_entries() {
    _kernel_path="$1"
    _cmdline="$2"
    
    _kernel_name="/$(basename "$_kernel_path")"
    _initrd_name="/initramfs-${_kernel_name#/vmlinuz-}"
    
    if [ ! -f "/boot${_initrd_name}" ]; then
        echo "[WARNING]: Initrd not found: /boot${_initrd_name}" >&2
        return 1
    fi
    
    # Add the default boot option (upperfs.squashfs)
    if grep -q "^upperfs\.squashfs$" "$IMAGE_LIST"; then
        write_boot_entry \
            "Alpine Linux (Default) ($_kernel_name)" \
            "$_kernel_name" \
            "$_initrd_name" \
            "$_cmdline" \
            "squashfs_version=upperfs.squashfs"
    fi
    
    echo "submenu \"More options for $_kernel_name\" {" >> "$GRUB_CFG"
    
    # Add entries for all other squashfs images
    while IFS= read -r _image_name; do
        if [ "$_image_name" != "upperfs.squashfs" ]; then
            write_boot_entry \
                "Alpine Linux ($_image_name)" \
                "$_kernel_name" \
                "$_initrd_name" \
                "$_cmdline" \
                "squashfs_version=$_image_name"
        fi
    done < "$IMAGE_LIST"
    
    # Add clean and ramdisk boot
    write_boot_entry \
        "Alpine Linux (Clean Boot) ($_kernel_name)" \
        "$_kernel_name" \
        "$_initrd_name" \
        "$_cmdline" \
        "clean_boot=1"
    
    write_boot_entry \
        "Alpine Linux (Full RAM disk) ($_kernel_name)" \
        "$_kernel_name" \
        "$_initrd_name" \
        "$_cmdline" \
        "full_ramdisk=1 squashfs_version=upperfs.squashfs"

    write_boot_entry \
        "Alpine Linux (Full RAM disk Clean Boot) ($_kernel_name)" \
        "$_kernel_name" \
        "$_initrd_name" \
        "$_cmdline" \
        "full_ramdisk=1 clean_boot=1"
    
    echo "}" >> "$GRUB_CFG"
    echo >> "$GRUB_CFG"
}

# Generate complete GRUB configuration
generate_config() {
    _cmdline="$(get_base_cmdline)"
    _kernel_count=0
    
    write_grub_header
    
    for kernel in /boot/vmlinuz-*; do
        if [ ! -f "$kernel" ]; then
            log_error "No kernel found in /boot"
        fi
        
        generate_kernel_entries "$kernel" "$_cmdline" || continue
        _kernel_count=$((_kernel_count + 1))
    done
    
    if [ "$_kernel_count" -eq 0 ]; then
        log_error "No valid kernel entries generated"
    fi
}

# Main execution
main() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
    fi
    
    if [ -f "$GRUB_CFG" ]; then
        cp "$GRUB_CFG" "$GRUB_BAK" || log_error "Failed to backup GRUB config"
    fi
    
    find_images
    generate_config
    
    successful=1
    
    echo "GRUB configuration regenerated successfully"
    echo "Backup saved to: $GRUB_BAK"
}

main "$@"
