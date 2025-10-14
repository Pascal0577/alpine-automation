#!/bin/sh
readonly STATE_DIR="/run/mkinitfs-hook"
readonly VERSION="$STATE_DIR/version"
readonly NEEDS_REBUILD="$STATE_DIR/needs-rebuild"

if [ "$1" = "pre-commit" ]; then
    
    mkdir -p "$STATE_DIR"
    echo 0 > "$NEEDS_REBUILD"
    prev_version="$(apk list -I | grep -E '^mkinitfs-[0-9]' | awk '{print $1}')"
  
    # Just in case
    [ -z "$prev_version" ] && echo 1 > "$NEEDS_REBUILD"
    echo "$prev_version" > "$VERSION"

elif [ "$1" = "post-commit" ]; then

    prev_version="$(cat "$VERSION")"
    new_version="$(apk list -I | grep -E '^mkinitfs-[0-9]' | awk '{print $1}')"

    { [ "$prev_version" != "$new_version" ] && command -v "mkinitfs" >/dev/null; } && echo 1 > "$NEEDS_REBUILD"

    [ "$(cat "$NEEDS_REBUILD")" = 1 ] && {
        ln -sf /usr/share/mkinitfs/init.sh /usr/share/mkinitfs/initramfs-init
        mkinitfs || {
            # Fallback
            mkinitfs "$(ls /lib/modules)"
        }
    }
    rm -rf "$STATE_DIR"

fi
