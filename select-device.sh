#!/bin/sh

# Create temporary files to hold the device lists
vfat_tmp=$(mktemp)
root_tmp=$(mktemp)

# Populate VFAT and EXT4 device lists
lsblk -flp | awk '$2 == "vfat" { print $1, $4 }' > "$vfat_tmp"
lsblk -flp | awk '$2 ~ /^(ext4|btrfs|xfs)$/ { print $1, $4 }' > "$root_tmp"

# Exit if no vfat devices found
if [ ! -s "$vfat_tmp" ]; then
    echo "No vfat devices found."
    rm -f "$vfat_tmp" "$root_tmp"
    exit 1
fi

# Exit if no ext4 root devices found
if [ ! -s "$root_tmp" ]; then
    echo "No root (ext4) devices found."
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

selected_vfat_uuid=$(awk -v n="$choice_vfat" '$1 == n { print $3 }' /tmp/vfat_menu)

if [ -z "$selected_vfat_uuid" ]; then
    echo "Invalid selection."
    rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu
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

selected_root_uuid=$(awk -v n="$choice_root" '$1 == n { print $3 }' /tmp/root_menu)

if [ -z "$selected_root_uuid" ]; then
    echo "Invalid selection."
    rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu /tmp/root_menu
    exit 1
fi

# Cleanup
rm -f "$vfat_tmp" "$root_tmp" /tmp/vfat_menu /tmp/root_menu

echo "$selected_vfat_uuid" > ./vfat_uuid
echo "$selected_root_uuid" > ./root_uuid

# Output selections
# echo "$selected_vfat_uuid $selected_root_uuid"
