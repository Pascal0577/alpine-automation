#!/bin/sh
readonly STATE_DIR="/var/kernel-hook"

set -eu

cleanup() {
    [ -d "$STATE_DIR" ] && rm -rf "${STATE_DIR:?}" || true
}

if [ "${1:-}" = "post-commit" ] && [ -d /persist ]; then
    trap cleanup INT TERM EXIT

    for dir in /lib/modules/*; do
        kernel="$(basename "$dir")"
        if [ -d "/lib/modules/$kernel" ] && [ ! -e "/persist/modules-$kernel.squashfs" ]; then
            mkdir -p "$STATE_DIR"
            out="${STATE_DIR:?}/modules-$kernel.squashfs"

            mksquashfs "/lib/modules/$kernel" "$out" -comp zstd -no-strip || {
                echo "ERROR CREATING MODULE SQUASHFS: $kernel" >&2
                exit 1
            }

            mv "$out" "/persist/modules-$kernel-tmp.squashfs"
            mv "/persist/modules-$kernel-tmp.squashfs" "/persist/modules-$kernel.squashfs"

            [ "$(uname -r)" != "$kernel" ] && rm -rf "/mnt/upperdir/lib/modules/${kernel:?}"
        fi
    done
elif [ ! -d /persist ]; then
    echo "WARNING: /persist does not exist."
fi
