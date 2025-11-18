#!/bin/sh
readonly STATE_DIR="/var/mkinitfs-hook"
readonly VERSION="$STATE_DIR/version"

mkdir -p "$STATE_DIR"

get_version() {
    apk list -I | grep -E '^mkinitfs-[0-9]' | awk '{print $1}'
}

build_initramfs() {
    for kernel in /lib/modules/*; do
        if [ -d "$kernel" ]; then
            mkinitfs "$(basename "$kernel")"
        fi
    done
}

if [ "$1" = "pre-commit" ]; then
    prev_version="$(get_version)"
    echo "$prev_version" > "$VERSION"
elif [ "$1" = "post-commit" ]; then
    prev_version="$(cat "$VERSION")"
    new_version="$(get_version)"

    if [ "$prev_version" != "$new_version" ] && command -v "mkinitfs" >/dev/null; then
        ln -sf /usr/share/mkinitfs/init.sh /usr/share/mkinitfs/initramfs-init
        build_initramfs
    fi
fi
