#!/bin/sh

set -e

# Default configuration
readonly DEFAULT_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.1-x86_64.tar.gz"
readonly BUILD_DIR="alpine"
readonly ARCHIVE_NAME="alpine-minirootfs"
readonly CHROOT_COMMAND="chroot-script.sh"

# Configuration variables
url="$DEFAULT_URL"
dir="$BUILD_DIR"
archive_name="$ARCHIVE_NAME"
command="$CHROOT_COMMAND"
checksum_check=1
no_device=0
cleanup_happened=0
verbose=0
edge=0
cmdline=""
build_successful=0
user=""

# Colors for log messages
red="$(printf '\033[0;31m')"
blue="$(printf '\033[0;34m')"
green="$(printf '\033[0;32m')"
white="$(printf '\033[0m')"

parse_arguments() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)
        shift
        user="$1"
        shift ;;
      -m|--cmdline)
        shift
        cmdline="$1"
        shift ;;
      --no-device)
        no_device=1
        shift ;;
      --no-cleanup)
        cleanup_happened=1
        shift ;;
      --no-checksum)
        checksum_check=0
        shift ;;
      -u|--url)
        shift
        url="$1"
        shift ;;
      --edge)
        edge=1
        shift ;;
      -v|--verbose)
        verbose=1
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
  -d, --no-device       Don't use a physical device (use local directory)
  -i, --root-uuid       Specifies the UUID of the root filesystem to use
  -c, --no-cleanup      Skip cleanup on exit
  -k, --no-checksum     Skip checksum verification
  -u, --url URL         Specify custom Alpine minirootfs URL
  -e, --edge            Use Alpine edge repository
  -v, --verbose         Enable verbose output
  -h, --help            Show this help message

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
  [ "$verbose" = "1" ] && printf "%s[DEBUG]%s: %s\n" "$blue" "$white" "$1"
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
  [ "$cleanup_happened" = "1" ] && return 0
  
  log_debug "Running cleanup"
  
  log_debug "Trying to unmount $pwd/build/$dir/boot"
  unmount_if_mounted "$pwd/build/$dir/boot" 

  log_debug "Trying to unmount $pwd/build/$dir"
  unmount_if_mounted "$pwd/build/$dir"
  
  [ -n "$efi_uuid" ] && unmount_if_mounted "/dev/disk/by-uuid/$efi_uuid"
  [ -n "$root_uuid" ] && unmount_if_mounted "/dev/disk/by-uuid/$root_uuid"
  
  if [ "$no_device" = "1" ] && [ "$build_successful" = "1" ]; then
    mv ./boot ./firmware.squashfs ./rootfs.squashfs ./upperfs.squashfs ../
    rm -rf ./*
    mv ../boot ../firmware.squashfs ../rootfs.squashfs ../upperfs.squashfs ./
    cd "$pwd" || true
    return 0
  else
    cd "$pwd" 2>/dev/null || true
    rm -rf build
  fi
  
  cleanup_happened=1
}

validate_dependencies() {
  log_debug "Validating dependencies"
  check_command curl
  check_command tar
  check_command mkdir
  check_command cd
  check_command mksquashfs
  check_command awk
  [ "$checksum_check" = "1" ] && check_command sha256sum
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
  if [ "$no_device" = "0" ]; then
    log_debug "Setting up device boot partition"
    ../select-device.sh
    
    efi_uuid=$(awk '{print $1}' ./vfat_uuid)
    root_uuid=$(awk '{print $1}' ./root_uuid)
    
    mkdir -p "$dir/boot"
    mount "/dev/disk/by-uuid/$efi_uuid" "$dir/boot" || \
      log_error "Failed to mount EFI partition"
  else
    log_debug "Setting up local boot directory"
    
    # Get root uuid from cmdline
    for arg in $(cat "$cmdline"); do
      case "$arg" in
      root=UUID=*)
        root_uuid=${arg#"root=UUID="}
      esac
    done

    echo "$root_uuid" > ./root_uuid
    mkdir -p boot "$dir/boot"
    mount --bind boot "$dir/boot" || log_error "In setup_boot_partition: Failed to bind mount boot"
  fi
}

download_minirootfs() {
  log_info "Downloading Alpine minirootfs"
  log_debug "URL: $url"
  
  curl -o "$archive_name.tar.gz" "$url" || \
    log_error "In download_minirootfs: Failed to download minirootfs from $url"
}

download_checksum() {
  log_debug "Downloading checksum file"
  curl -o "$archive_name.tar.gz.sha256" "$url.sha256" || \
    log_error "In download_checksum: Failed to download checksum file"
}

verify_checksum() {
  [ "$checksum_check" = "0" ] && return 0
  
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
  [ "$verbose" = "1" ] && _tar_flags="-xvf"
  
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
  
  cp ./root_uuid "$dir/"                                       || log_error "In copy_scripts: Failed to copy root_uuid"
  cp ../chroot-script.sh "$dir/bin/"                           || log_error "In copy_scripts: Failed to copy chroot-script.sh"
  cp ../squash-upperdir "$dir/bin/"                            || log_error "In copy_scripts: Failed to copy squash-upperdir"
  cp ../squashdir "$dir/etc/init.d/"                           || log_error "In copy_scripts: Failed to copy squashdir"
  cp ../init.sh "$dir/usr/share/mkinitfs/initramfs-init"       || log_error "In copy_scripts: Failed to copy initramfs-init"
  cp ../init.sh "$dir/usr/share/mkinitfs/init.sh"              || log_error "In copy_scripts: Failed to copy init.sh"
  cp ../custom.files "$dir/etc/mkinitfs/features.d/"           || log_error "In copy_scripts: Failed to copy custom.files"
  cp ../custom.modules "$dir/etc/mkinitfs/features.d/"         || log_error "In copy_scripts: Failed to copy custom.modules"
  cp ../mkinitfs_commit_hook.sh "$dir/etc/apk/commit_hooks.d/" || log_error "In copy_scripts: Failed to copy mkinitfs_commit_hook.sh"
}

run_chroot() {
  log_info "Running chroot script"
  
  _chroot_command="$command"
  [ "$edge" = "1" ] && _chroot_command="$_chroot_command --edge"
  [ "$verbose" = "1" ] && _chroot_command="$_chroot_command --verbose"
  [ -n "$cmdline" ] && _chroot_command="$_chroot_command --cmdline $cmdline"
  [ -n "$user" ] && _chroot_command="$_chroot_command --user $user"
  [ "$no_device" = 1 ] && _chroot_command="$_chroot_command --no-device"
  
  log_debug "Chroot command: $_chroot_command"
  ../auto-chroot.sh "$dir" "$_chroot_command" || \
    log_error "In run_chroot: Chroot script failed"
  
  rm "$dir/bin/chroot-script.sh" || \
    log_error "In run_chroot: Failed to remove chroot script"
}

create_squashfs_images() {
  log_info "Creating SquashFS images"
  
  unmount_if_mounted "$dir/boot"
  
  _firmware_path=$(realpath "./alpine/lib/firmware/")
  
  log_debug "Creating rootfs.squashfs"
  mksquashfs "$dir" rootfs.squashfs -comp zstd -e "${_firmware_path}/"* || \
    log_error "In create_squashfs_images: Failed to create rootfs.squashfs"
  
  log_debug "Creating firmware.squashfs"
  mksquashfs "$_firmware_path" firmware.squashfs -no-compression || \
    log_error "In create_squashfs_images: Failed to create firmware.squashfs"
  
  log_debug "Creating upperfs.squashfs"
  touch /root/upperfs_created
  mksquashfs /root/upperfs_created upperfs.squashfs -comp zstd || \
    log_error "In create_squashfs_images: Failed to create upperfs.squashfs"
  mksquashfs /root/upperfs_created upperfs-backup.squashfs -comp zstd || \
    log_error "In create_squashfs_images: Failed to create upperfs-backup.squashfs"
  rm /root/upperfs_created
}

deploy_to_root_device() {
  log_info "Deploying images to root device"
  
  mount "/dev/disk/by-uuid/$root_uuid" "$dir" || \
    log_error "In deploy_to_root_device: Failed to mount root device"
  
  cp ./firmware.squashfs "$dir/" && rm ./firmware.squashfs
  cp ./rootfs.squashfs "$dir/" && rm ./rootfs.squashfs
  cp ./upperfs.squashfs "$dir/" && rm ./upperfs.squashfs
  cp ./upperfs-backup.squashfs "$dir/" && rm ./upperfs-backup.squashfs
  
  umount "/dev/disk/by-uuid/$root_uuid" || \
    log_error "In deploy_to_root_device: Failed to unmount root device"
}

main() {
  trap 'cleanup; exit 1' INT TERM
  trap cleanup EXIT
  
  [ "$(id -u)" != 0 ] && log_error "In main: Please run as root."
  validate_dependencies
  parse_arguments "$@"
  
  pwd="$PWD"
  
  setup_build_directory # Includes cd ./build
  setup_boot_partition
  
  cd "$dir"
  
  download_minirootfs

  [ "$checksum_check" = "1" ] && {
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

  [ "$no_device" != 1 ] && deploy_to_root_device

  build_successful=1
  log_info "Build completed successfully!"
  { [ "$no_device" = "1" ] && [ -z "$root_uuid" ]; } && log_info "Build completed, but system is not bootable!"
}

main "$@"
