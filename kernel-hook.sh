#!/bin/sh
readonly STATE_DIR="/var/kernel-hook"
readonly TMP_DIR="$STATE_DIR/KERNEL-MODULES-$$"

set -eu

cleanup() {
    [ -d "$STATE_DIR" ] && rm -rf "${STATE_DIR:?}"
}

if [ "${1:-}" = "post-commit" ] && [ -d /persist ]; then
    trap cleanup INT TERM EXIT
    
    # This is so the installation doesn't fail
    mkdir -p /lib/modules
    command -v "mksquashfs" >/dev/null || echo "Command check failed!"

    for dir in /lib/modules/*; do
        kernel="$(basename "$dir")"
        if [ -d "/lib/modules/$kernel" ] && [ ! -e "/persist/modules-$kernel" ]; then
            kernel_dir="${TMP_DIR:?}/$kernel"
            out="${STATE_DIR:?}/modules-$kernel.squashfs"

            mkdir -p "$kernel_dir"
            cp -r "/lib/modules/$kernel" "$kernel_dir" || exit 1

            mksquashfs "$kernel_dir" "$out" -comp zstd || {
                echo "ERROR CREATING MODULE SQUASHFS: $kernel" >&2
                exit 1
            }
            mv "${STATE_DIR:?}/modules-$kernel.squashfs" /persist
        fi
    done
elif [ ! -d /persist ]; then
    echo "WARNING: /persist does not exist."
fi
