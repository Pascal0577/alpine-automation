#!/bin/sh

EFI_UUID=""
ROOT_UUID=""

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --root-uuid)
                shift
                ROOT_UUID="$1"
                shift ;;
            --efi-uuid)
                shift
                EFI_UUID="$1"
                shift ;;
        esac
    done
}

select_efi() {
    vfat_tmp=$(mktemp)

    lsblk -flp -o NAME,FSTYPE,UUID | awk '$2 == "vfat" { print $1, $3 }' > "$vfat_tmp"

    if [ ! -s "$vfat_tmp" ]; then
        echo "No vfat devices found."
        rm -f "$vfat_tmp" "$root_tmp"
        exit 1
    fi

    echo "Select a VFAT-formatted device:"
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        dev=$(echo "$line" | awk '{print $1}')
        uuid=$(echo "$line" | awk '{print $2}')
        echo "$i) $dev (UUID: $uuid)"
        echo "$i $dev $uuid" >> /tmp/vfat_menu
    done < "$vfat_tmp"

    printf "Enter the number of the VFAT device you want to use: "
    read -r choice_vfat

    EFI_UUID=$(awk -v n="$choice_vfat" '$1 == n { print $3 }' /tmp/vfat_menu)

    if [ -z "$EFI_UUID" ]; then
        echo "Invalid selection."
        rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu
        exit 1
    fi
}

select_root() {
    root_tmp=$(mktemp)

    lsblk -flp | awk '$2 ~ /^(ext4|btrfs|xfs)$/ { print $1, $4 }' > "$root_tmp"

    if [ ! -s "$root_tmp" ]; then
        echo "No root (ext4) devices found."
        rm -f "$vfat_tmp" "$root_tmp"
        exit 1
    fi

    printf "\nSelect a device for the root filesystem:\n"
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        dev=$(echo "$line" | awk '{print $1}')
        uuid=$(echo "$line" | awk '{print $2}')
        echo "$i) $dev (UUID: $uuid)"
        echo "$i $dev $uuid" >> /tmp/root_menu
    done < "$root_tmp"

    printf "Enter the number of the root device you want to use: "
    read -r choice_root

    ROOT_UUID=$(awk -v n="$choice_root" '$1 == n { print $3 }' /tmp/root_menu)

    if [ -z "$ROOT_UUID" ]; then
        echo "Invalid selection."
        rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu /tmp/root_menu
        exit 1
    fi
}

validate_filesystem_uuid() {
    _filesystem_uuid="$1"
    if [ -e "/dev/disk/by-uuid/$_filesystem_uuid" ]; then
        return 0
    else
        return 1
    fi
}

main() {
    parse_arguments "$@"

    # If no UUIDs are provided or they are invalid, prompt the user for selection
    { [ -z "$EFI_UUID" ]  || ! validate_filesystem_uuid "$EFI_UUID"; }  && select_efi
    { [ -z "$ROOT_UUID" ] || ! validate_filesystem_uuid "$ROOT_UUID"; } && select_root

    echo "$EFI_UUID" > ./vfat_uuid
    echo "$ROOT_UUID" > ./root_uuid

    rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu /tmp/root_menu
}

main "$@"
