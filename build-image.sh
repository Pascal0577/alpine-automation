#!/bin/sh

set -e

url="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.1-x86_64.tar.gz"
dir="alpine"
archive_name="alpine-minirootfs"
command="chroot-script.sh"
checksum_check=1

cleanup_happened=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-checksum)
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
    [ -f "alpine-rootfs-temp.tar.gz.tmp" ] && mv alpine-rootfs-temp.tar.gz alpine-rootfs-temp.tar.gz
    # [ -d "$dir" ] && rm -rf "$dir"
  }
  cleanup_happened=1
}

main() {
  trap cleanup EXIT
  
  [ "$(id -u)" != 0 ] && log_error "Please run as root."

  check_command curl
  check_command tar
  check_command mkdir
  check_command cd
  check_command mksquashfs
  [ "$checksum_check" = "1" ] && check_command sha256sum

  [ "$edge" = "1" ] && command="$command --edge"
  [ "$verbose" = "1" ] && command="$command --verbose"
  [ -f "$archive_name.tar.gz" ] && archive_name="$archive_name-2"
  [ -d "$dir" ] && log_error "$dir exists. For safety, please choose a different temporary directory name"

  mkdir "$dir"                                        || log_error "Failed to create dir: $dir"
  log_debug "Created $dir"

  cd "$dir"                                           || log_error "Failed to cd into $dir"
  log_debug "Changed directory to $dir"

  log_debug "Downloading $archive_name.tar.gz from $url"
  curl -o "$archive_name.tar.gz" "$url"               || log_error "Failed to download minirootfs"
  
  log_debug "Downloading $archive_name.tar.gz.sha256 from $url.sha256"
  curl -o "$archive_name.tar.gz.sha256" "$url.sha256" || log_error "Failed to download minirootfs"
  
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

  log_debug "Cleanign up checksum"
  rm "$archive_name.tar.gz.sha256" || log_error "Failed to remove tar archive checksum"

  log_debug "Changing directory to $dir/.."
  cd .. || log_error "Failed to cd to $dir/.."

  log_debug "Copying scripts to $dir"
  mkdir "$dir/etc/init.d/"                             || log_error "Failed to create /etc/init.d/"
  mkdir -p "$dir/usr/share/mkinitfs/"                  || log_error "Failed to create /usr/share/mkinitfs"
  cp ./chroot-script.sh "$dir/bin/"                    || log_error "Failed to move chroot script"
  cp ./squash-upperdir "$dir/bin/"                     || log_error "Failed to copy squash-upperdir script"
  cp ./squashdir "$dir/etc/init.d/"                    || log_error "Failed to copy squashdir rc script"
  cp ./init.sh "$dir/usr/share/mkinitfs/mkinitfs-init" || log_error "Failed to copy init.sh"
  cp ./init.sh "$dir/usr/share/mkinitfs/init.sh"

  log_debug "Setting up /boot"
  # mkdir -p stuff "$dir/boot"
  # mount --bind stuff "$dir/boot"

  log_debug "chrooting into $dir with command $command"
  ./auto-chroot.sh "$dir" "$command" || log_error "Something went wrong during the chroot script"

  log_debug "Cleaning up chroot script from chroot environment"
  rm "$dir/bin/chroot-script.sh" || log_error "Failed to remove chroot script from minirootfs"

  log_debug "Creating squashfs images"
  mksquashfs "$dir" rootfs.squashfs -e "$(realpath ./alpine/lib/firmware/)"/* || log_error "Failed to create rootfs.squashfs"
  mksquashfs "$(realpath ./alpine/lib/firmware)" firmware.squashfs            || log_error "Failed to create firmware.squashfs"
}

main "$@"
