#!/bin/sh
readonly TMPFILE="/mkinitfs-version"
NEEDS_REBUILD=0

if [ "$1" = "pre-commit" ]; then
    prev_version="$(apk list -I | grep -E '^mkinitfs-[0-9]' | awk '{print $1}')"
  
    # Just in case
    [ -z "$prev_version" ] && NEEDS_REBUILD=1

    echo "$prev_version" > "$TMPFILE"
elif [ "$1" = "post-commit" ]; then
    prev_version="$(cat "$TMPFILE")"
    new_version="$(apk list -I | grep -E '^mkinitfs-[0-9]' | awk '{print $1}')"

    { [ "$prev_version" != "$new_version" ] && command -v "mkinitfs" >/dev/null; } && NEEDS_REBUILD=1

    [ "$NEEDS_REBUILD" = 1 ] && {
        ln -sf /usr/share/mkinitfs/init.sh /usr/share/mkinitfs/initramfs-init
        mkinitfs || {
            # Fallback
            mkinitfs "$(ls /lib/modules)"
        }
    }
    rm "$TMPFILE"
fi
