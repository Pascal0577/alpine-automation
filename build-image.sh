#!/bin/sh

set -e

# Default configuration
readonly BUILD_DIR="alpine"
readonly ARCHIVE_NAME="alpine-minirootfs"
readonly CHROOT_COMMAND="chroot-script.sh"
readonly pwd="$PWD"

# Configuration variables
dir="$BUILD_DIR"
archive_name="$ARCHIVE_NAME"
command="$CHROOT_COMMAND"
CHECKSUM_CHECK=1
NO_DEVICE=0
NO_CLEANUP=0
VERBOSE=0
EDGE=0
CMDLINE=""
build_successful=0
USER=""
ALPINE_HOSTNAME=""

# Colors for log messages
red="$(printf '\033[0;31m')"
blue="$(printf '\033[0;34m')"
green="$(printf '\033[0;32m')"
white="$(printf '\033[0m')"


parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --root-uuid)
                shift
                ROOT_UUID="$1"
                shift;;
            --efi-uuid)
                shift
                EFI_UUID="$1"
                shift;;
            --hostname)
                shift
                ALPINE_HOSTNAME="$1"
                shift ;;
            --user)
                shift
                USER="$1"
                shift ;;
            --cmdline)
                shift
                CMDLINE="$1"
                shift ;;
            --no-device)
                NO_DEVICE=1
                shift ;;
            --no-cleanup)
                NO_CLEANUP=1
                shift ;;
            --no-checksum)
                CHECKSUM_CHECK=0
                shift ;;
            -u|--url)
                shift
                URL="$1"
                shift ;;
            --edge)
                EDGE=1
                shift ;;
            -v|--verbose)
                VERBOSE=1
                shift ;;
            -h|--help)
                print_usage
                exit 0 ;;
            --)
                shift
                break ;;
            -*)
                echo "Unknown option: $1" >&2
                print_usage
                exit 1 ;;
            *)
                break ;;
        esac
    done
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --efi-uuid UUID        The UUID of the EFI System Partition of the installation
    --root-uuid UUID       The UUID of the root filesystem of the installation
    --hostname HOSTNAME    The hostname of the installation
    --user USER            Adds a non-root USER to the installtion
    --cmdline CMDLINE      The default kernel command line. System will still be bootable if empty
    --no-device            Don't use a physical device (installs images to build directory)
    --no-cleanup           Skip cleanup on exit
    --no-checksum          Skip checksum verification
    -u, --url URL          Specify custom Alpine minirootfs URL
    -e, --edge             Use Alpine edge repository
    -v, --verbise          Enable verbose output
    -h, --help             Show this help message

EOF
}

log_error() {
    printf "%s[ERROR]%s: %s\n" "$red" "$white" "$1" >&2
    exit 1
}

log_info() {
    printf "%s[INFO]%s: %s\n" "$green" "$white" "$1"
}

log_debug() {
    [ "$VERBOSE" = "1" ] && printf "%s[DEBUG]%s: %s\n" "$blue" "$white" "$1"
    return 0
}

check_command() {
    command -v "$1" >/dev/null || log_error "Command '$1' not found. Please install it."
}

unmount_if_mounted() {
    _mount_point="$1"
    if mountpoint -q "$_mount_point" 2>/dev/null; then
        log_debug "Unmounting $_mount_point"
        umount "$_mount_point" || log_debug "In unmount_if_mounted: Failed to unmount $_mount_point"
    fi
}

cleanup() {
    [ "$NO_CLEANUP" = "1" ] && return 0
  
    log_debug "Running cleanup"
  
    log_debug "Trying to unmount $pwd/build/$dir/boot"
    umount "$pwd/build/$dir/boot" 2>/dev/null || true

    log_debug "Trying to unmount $pwd/build/$dir"
    umount "$pwd/build/$dir" 2>/dev/null || true
  
    [ -n "$EFI_UUID" ] && unmount_if_mounted "/dev/disk/by-uuid/$EFI_UUID"
    [ -n "$ROOT_UUID" ] && unmount_if_mounted "/dev/disk/by-uuid/$ROOT_UUID"
  
    if [ "$NO_DEVICE" = "1" ] && [ "$build_successful" = "1" ]; then
        mv ./boot ./rootfs.squashfs ./upperfs.squashfs ./modules-*.squashfs ../
        rm -rf ./*
        mv ../boot ../rootfs.squashfs ../upperfs.squashfs ./modules-*.squashfs ./
        cd "$pwd" || true
        return 0
    else
        cd "$pwd" 2>/dev/null || true
        rm -rf build
    fi
  
    NO_CLEANUP=1
}

validate_dependencies() {
    log_debug "Validating dependencies"
    check_command curl
    check_command tar
    check_command mkdir
    check_command cd
    check_command mksquashfs
    check_command awk
    [ "$CHECKSUM_CHECK" = "1" ] && check_command sha256sum
}

setup_build_directory() {
    log_debug "Setting up build directory"
  
    mkdir -p "build" || log_error "In setup_build_directory: Failed to create build directory"
    cd build || log_error "In setup_build_directory: Failed to enter build directory"
  
    [ -f "$archive_name.tar.gz" ] && archive_name="${archive_name}-2"
    [ -d "$dir" ] && log_error "In setup_build_directory: Directory '$dir' already exists. Please remove it first."
  
    mkdir "$dir" || log_error "In setup_build_directory: Failed to create $dir"
}

setup_boot_partition() {
    if [ "$NO_DEVICE" = "0" ]; then
        log_debug "Setting up device boot partition"
        ../select-device.sh --efi-uuid "$EFI_UUID" --root-uuid "$ROOT_UUID"
        
        EFI_UUID=$(awk '{print $1}' ./EFI_UUID)
        ROOT_UUID=$(awk '{print $1}' ./ROOT_UUID)
        
        mkdir -p "$dir/boot"
        mount "/dev/disk/by-uuid/$EFI_UUID" "$dir/boot" || \
            log_error "Failed to mount EFI partition"
    else
        log_debug "Setting up local boot directory"
        mkdir -p boot "$dir/boot"
        mount --bind boot "$dir/boot" || log_error "In setup_boot_partition: Failed to bind mount boot"
    fi
}

download_minirootfs() {
    log_info "Downloading Alpine minirootfs"
    log_debug "URL: $URL"
  
    curl -o "$archive_name.tar.gz" "$URL" || \
        log_error "In download_minirootfs: Failed to download minirootfs from $URL"
}

download_checksum() {
    log_debug "Downloading checksum file"
    curl -o "$archive_name.tar.gz.sha256" "$URL.sha256" || \
        log_error "In download_checksum: Failed to download checksum file"
}

verify_checksum() {
    [ "$CHECKSUM_CHECK" = "0" ] && return 0
  
    log_debug "Verifying checksum"
    local_checksum=$(sha256sum "$archive_name.tar.gz" | awk '{print $1}')
    known_checksum=$(awk '{print $1}' "$archive_name.tar.gz.sha256")
  
    if [ "$local_checksum" != "$known_checksum" ]; then
        log_error "In verify_checksum: Checksum verification failed. File may be corrupted."
    fi
  
    log_debug "Checksum verified successfully"
}

extract_minirootfs() {
    log_info "Extracting Alpine minirootfs"
  
    _tar_flags="-xf"
    [ "$VERBOSE" = "1" ] && _tar_flags="-xvf"
  
    tar $_tar_flags "$archive_name.tar.gz" || \
        log_error "In extract_minirootfs: Failed to extract minirootfs"
}

cleanup_downloads() {
    log_debug "Cleaning up downloaded files"
    rm -f "$archive_name.tar.gz" "$archive_name.tar.gz.sha256"
}

copy_scripts() {
    log_debug "Copying scripts to chroot environment"
  
    mkdir -p "$dir/etc/init.d/"
    mkdir -p "$dir/usr/share/mkinitfs/"
    mkdir -p "$dir/boot/EFI/BOOT/"
    mkdir -p "$dir/etc/mkinitfs/features.d/"
    mkdir -p "$dir/etc/apk/commit_hooks.d/"
    
    cp ./ROOT_UUID "$dir/"                                 || log_error "In copy_scripts: Failed to copy ROOT_UUID"
    cp ../chroot-script.sh "$dir/bin/"                     || log_error "In copy_scripts: Failed to copy chroot-script.sh"
    cp ../squash-upperdir "$dir/bin/"                      || log_error "In copy_scripts: Failed to copy squash-upperdir"
    cp ../squashdir "$dir/etc/init.d/"                     || log_error "In copy_scripts: Failed to copy squashdir"
    cp ../init.sh "$dir/usr/share/mkinitfs/initramfs-init" || log_error "In copy_scripts: Failed to copy initramfs-init"
    cp ../init.sh "$dir/usr/share/mkinitfs/init.sh"        || log_error "In copy_scripts: Failed to copy init.sh"
    cp ../base.files "$dir/etc/mkinitfs/features.d/"       || log_error "In copy_scripts: Failed to copy custom.files"
    cp ../base.modules "$dir/etc/mkinitfs/features.d/"     || log_error "In copy_scripts: Failed to copy custom.modules"
    cp ../mkinitfs-hook.sh "$dir/etc/apk/commit_hooks.d/"  || log_error "In copy_scripts: Failed to copy mkinitfs_commit_hook.sh"
    cp ../kernel-hook.sh "$dir/etc/apk/commit_hooks.d/"    || log_error "In copy_scripts: Failed to copy mkinitfs_commit_hook.sh"
    cp ../firmware-hook.sh "$dir/etc/apk/commit_hooks.d/"  || log_error "In copy_scripts: Failed to copy mkinitfs_commit_hook.sh"
    touch "$dir/first_install"
}

run_chroot() {
    log_info "Running chroot script"
  
    _chroot_command="$command"
    [ "$EDGE" = "1" ] && _chroot_command="$_chroot_command --edge"
    [ "$VERBOSE" = "1" ] && _chroot_command="$_chroot_command --verbose"
    [ "$NO_DEVICE" = 1 ] && _chroot_command="$_chroot_command --no-device"
    [ -n "$CMDLINE" ] && _chroot_command="$_chroot_command --cmdline '$CMDLINE'"
    [ -n "$USER" ] && _chroot_command="$_chroot_command --user $USER"
    [ -n "$ALPINE_HOSTNAME" ] && _chroot_command="$_chroot_command --hostname $ALPINE_HOSTNAME"

    log_debug "Chroot command: $_chroot_command"
    ../auto-chroot.sh "$dir" "$_chroot_command" || \
        log_error "In run_chroot: Chroot script failed"

    rm "$dir/bin/chroot-script.sh" || \
        log_error "In run_chroot: Failed to remove chroot script"
}

create_squashfs_images() {
    log_info "Creating SquashFS images"

    unmount_if_mounted "$dir/boot"

    _modules_version=$(ls "./alpine/lib/modules")
    _modules_path=$(realpath "./alpine/lib/modules/$_modules_version")

    log_debug "Creating rootfs.squashfs"
    mksquashfs "$dir" rootfs.squashfs -comp zstd -e "${_modules_path}/" || \
        log_error "In create_squashfs_images: Failed to create rootfs.squashfs"

    log_debug "Creating modules-$_modules_version.squashfs"
    mksquashfs "lib/modules/$_modules_version" "../modules-$_modules_version.squashfs" -no-compression -no-strip || \
        log_error "In create_squashfs_images: Failed to create modules-$_modules_version.squashfs"
    cd ..


    log_debug "Creating upperfs.squashfs"
    touch upperfs-created
    mksquashfs upperfs-created upperfs.squashfs -comp zstd || \
        log_error "In create_squashfs_images: Failed to create upperfs.squashfs"
    mksquashfs upperfs-created upperfs-backup.squashfs -comp zstd || \
        log_error "In create_squashfs_images: Failed to create upperfs-backup.squashfs"
    rm upperfs-created
}

deploy_to_root_device() {
    log_info "Deploying images to root device"

    mount "/dev/disk/by-uuid/$ROOT_UUID" "$dir" || \
        log_error "In deploy_to_root_device: Failed to mount root device"

    cp ./rootfs.squashfs "$dir/" && rm ./rootfs.squashfs
    cp ./upperfs.squashfs "$dir/" && rm ./upperfs.squashfs
    cp ./upperfs-backup.squashfs "$dir/" && rm ./upperfs-backup.squashfs
    cp "./modules-$_modules_version.squashfs" "$dir/" && rm "./modules-$_modules_version.squashfs"

    umount "/dev/disk/by-uuid/$ROOT_UUID" || \
        log_error "In deploy_to_root_device: Failed to unmount root device"
}

main() {
    trap 'cleanup; exit 1' INT TERM
    trap cleanup EXIT INT TERM

    . ./alpine.conf
    parse_arguments "$@"

    [ "$(id -u)" != 0 ] && log_error "In main: Please run as root."

    validate_dependencies

    setup_build_directory # Includes cd ./build
    setup_boot_partition

    cd "$dir"

    download_minirootfs

    [ "$CHECKSUM_CHECK" = "1" ] && {
        log_debug "Verifying checksum"
        download_checksum
        verify_checksum
    }

    extract_minirootfs
    cleanup_downloads

    cd ..

    copy_scripts
    run_chroot
    create_squashfs_images

    [ "$NO_DEVICE" != 1 ] && deploy_to_root_device

    build_successful=1
    log_info "Build completed successfully!"
    { [ "$NO_DEVICE" = "1" ] && [ -z "$ROOT_UUID" ]; } && log_info "Build completed, but system may not be bootable!"
}

main "$@"
