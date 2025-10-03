#!/bin/sh

set -e

url="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.1-x86_64.tar.gz"
dir="alpine"
archive_name="alpine-minirootfs"
command="chroot-script.sh"
checksum_check=1
no_device=0

cleanup_happened=0

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--no-device)
      no_device=1
      shift
      ;;
    -c|--no-cleanup)
      cleanup_happened=1
      shift
      ;;
    -k|--no-checksum)
      checksum_check=0
      shift
      ;;
    -u|--url)
      shift
      url="$1"
      shift
      ;;
    -e|--edge)
      edge=1
      shift ;;
    -v|--verbose)
      verbose=1
      shift ;;
    -h|--help)
      echo "Usage: $0 (insert usage here at later date)"
      exit 0 ;;
    --)
      shift
      break ;;
    -*)
      echo "Unknown option: $1"
      exit 1 ;;
    *)
      break ;;
  esac
done

log_error() {
  printf "[ERROR]: %s\n" "$1"
  exit 1
}

log_debug() {
  [ "$verbose" = "1" ] && printf "[DEBUG]: %s\n" "$1"
  return 0
}

check_command() {
  command -v "$1" >/dev/null || log_error "Command $1 not found."
  return 0
}

cleanup() {
  [ "$cleanup_happened" = "0" ] && {
    cd "$pwd"
    mountpoint -q ".build/$dir/boot" && umount ".build/$dir/boot"
    mountpoint -q "./build/$dir" && umount "./build/$dir"
    [ -n "$efi_uuid" ] && umount "/dev/disk/by-uuid/$efi_uuid"
    [ -n "$root_uuid" ] && umount "/dev/disk/by-uuid/$root_uuid"
  }
  cleanup_happened=1
}

main() {
  trap cleanup EXIT INT TERM
  
  [ "$(id -u)" != 0 ] && log_error "Please run as root."

  check_command curl
  check_command tar
  check_command mkdir
  check_command cd
  check_command mksquashfs
  check_command awk
  [ "$checksum_check" = "1" ] && check_command sha256sum

  pwd="$PWD"

  mkdir "build" || log_error "Failed to make directory: build"
  cd build

  [ "$edge" = "1" ] && command="$command --edge"
  [ "$verbose" = "1" ] && command="$command --verbose"
  [ -f "$archive_name.tar.gz" ] && archive_name="$archive_name-2"
  [ -d "$dir" ] && log_error "$dir exists. For safety, please choose a different temporary directory name"

  mkdir "$dir" || log_error "Failed to create dir: $dir"
  log_debug "Created $dir"

  if [ "$no_device" = "0" ]; then
    ../select-device.sh

    efi_uuid=$(awk '{print $1}' ./vfat_uuid)
    root_uuid=$(awk '{print $1}' ./root_uuid)

    mkdir -p "$dir/boot"
    mount "/dev/disk/by-uuid/$efi_uuid" "$dir/boot"
  else
    log_debug "Setting up /boot"
    mkdir -p boot "$dir/boot"
    mount --bind boot "$dir/boot"
  fi

  cd "$dir" || log_error "Failed to cd into $dir"

  log_debug "Downloading $archive_name.tar.gz from $url"
  curl -o "$archive_name.tar.gz" "$url" || log_error "Failed to download minirootfs"
  
  log_debug "Downloading $archive_name.tar.gz.sha256 from $url.sha256"
  [ "$checksum_check" = "1" ] && { curl -o "$archive_name.tar.gz.sha256" "$url.sha256" || log_error "Failed to download minirootfs"; }
  
  log_debug "Verifying checksum"
  [ "$checksum_check" = "1" ] && {
    local_checksum="$(sha256sum "$archive_name.tar.gz" | awk '{print $1}')"
    known_checksum="$(awk '{print $1}' "$archive_name.tar.gz.sha256")"
    [ "$local_checksum" != "$known_checksum" ] && log_error "Unable to validate checksum. Exiting."
  }

  log_debug "Extracting $archive_name.tar.gz"
  [ "$verbose" = "1" ] && tar_flags="-xvf" || tar_flags="-xf"
  tar "$tar_flags" "$archive_name.tar.gz" || log_error "Failed to extract minirootfs"

  log_debug "Cleaning up archive"
  rm "$archive_name.tar.gz" || log_error "Failed to remove tar archive"

  log_debug "Cleaning up checksum"
  rm "$archive_name.tar.gz.sha256" || log_error "Failed to remove tar archive checksum"

  log_debug "Changing directory to $dir/.."
  cd ..

  log_debug "Copying scripts to $dir"
  mkdir "$dir/etc/init.d/"
  mkdir -p "$dir/usr/share/mkinitfs/"
  mkdir -p "$dir/boot/EFI/BOOT/"
  mkdir -p "$dir/etc/mkinitfs/features.d/"
  cp ./root_uuid "$dir"
  cp ../chroot-script.sh "$dir/bin/"
  cp ../squash-upperdir "$dir/bin/"
  cp ../squashdir "$dir/etc/init.d/"
  cp ../init.sh "$dir/usr/share/mkinitfs/initrmafs-init"
  cp ../init.sh "$dir/usr/share/mkinitfs/init.sh"
  cp ../custom.files "$dir/etc/mkinitfs/features.d/"
  cp ../custom.modules "$dir/etc/mkinitfs/features.d/"

  log_debug "chrooting into $dir with command $command"
  ../auto-chroot.sh "$dir" "$command" || log_error "Something went wrong during the chroot script"

  log_debug "Cleaning up chroot script from chroot environment"
  rm "$dir/bin/chroot-script.sh" || log_error "Failed to remove chroot script from minirootfs"
  mountpoint -q "$dir/boot" && umount "$dir/boot"

  log_debug "Creating squashfs images"
  mksquashfs "$dir" rootfs.squashfs -comp lz4 -e "$(realpath ./alpine/lib/firmware/)"/* || log_error "Failed to create rootfs.squashfs"
  mksquashfs "$(realpath ./alpine/lib/firmware)" firmware.squashfs -comp lz4            || log_error "Failed to create firmware.squashfs"
  touch squashfs_created && { mksquashfs squashfs_created upperfs.squashfs -comp lz4    || log_error "Failed to create upperfs.squashfs"; }

  log_debug "Mounting root device"
  mount "/dev/disk/by-uuid/$root_uuid" "$dir"
  cp ./firmware.squashfs "$dir" && rm ./firmware.squashfs 
  cp ./rootfs.squashfs "$dir" && rm ./rootfs.squashfs
  cp ./upperfs.squashfs "$dir" && rm ./upperfs.squashfs
  umount "/dev/disk/by-uuid/$root_uuid"

  cd ..
}

main "$@"
