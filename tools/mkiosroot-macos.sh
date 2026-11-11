#!/bin/bash
# Build the full iOS 16.7.16 (20H392, iPhone10,3 / D22AP) Case-Sensitive Journaled HFS+ root image
# natively on macOS (macos-15-intel) with Cryptexes merged, sweet-root-tweaks, Mesa (freedreno),
# and Topaz GL installed.
#
#   bash tools/mkiosroot-macos.sh IPSW_URL OUT_DIR MESA_DIR TOPAZ_DIR [SIZE_GB]
set -euo pipefail

[[ $# -ge 4 ]] || { echo "Usage: $0 IPSW_URL OUT_DIR MESA_DIR TOPAZ_DIR [SIZE_GB]" >&2; exit 2; }
IPSW_URL=$1
mkdir -p "$2"
OUT_DIR=$(cd "$2" && pwd)
MESA_DIR=$(cd "$3" && pwd)
TOPAZ_DIR=$(cd "$4" && pwd)
SIZE_GB=${5:-15}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/iosroot.XXXXXX)
mkdir -p "$WORK/ipsw" "$WORK/root"

HFS_DEV=""
cleanup() {
    set +e
    if [[ -n "$HFS_DEV" ]]; then
        hdiutil detach "$HFS_DEV" -force 2>/dev/null || true
    fi
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Initial disk space ==="
df -h /
FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
if [[ "${FREE_GB:-0}" -lt 42 ]]; then
    echo "Free space (${FREE_GB} GiB) < 42 GiB; removing unused Xcode / simulator caches..."
    sudo rm -rf /Applications/Xcode_15*.app /Library/Developer/CoreSimulator/Volumes /Library/Developer/CoreSimulator/Caches 2>/dev/null || true
    df -h /
fi

if [[ ! -x /usr/local/bin/rsync ]] || ! command -v zstd >/dev/null 2>&1; then
    brew install rsync zstd
fi
RSYNC=/usr/local/bin/rsync
[[ -x "$RSYNC" ]] || RSYNC=$(command -v rsync)
echo "Using rsync: $RSYNC ($("$RSYNC" --version | head -n1))"

echo "=== Extracting and unwrapping DeviceTree.d22ap.im4p ==="
python3 "$REPO_ROOT/tools/remotezip.py" "$IPSW_URL" "DeviceTree.d22ap.im4p" "$WORK/ipsw"
mkdir -p "$REPO_ROOT/research/ipsw-x"
python3 "$REPO_ROOT/tools/adt.py" unwrap "$WORK/ipsw/Firmware/all_flash/DeviceTree.d22ap.im4p" "$OUT_DIR/d22ap.adt"
cp "$OUT_DIR/d22ap.adt" "$REPO_ROOT/research/ipsw-x/d22ap.adt"
ls -lh "$OUT_DIR/d22ap.adt"

echo "=== Creating ${SIZE_GB} GiB Case-Sensitive Journaled HFS+ image ==="
python3 -c "f = open('$WORK/ios16-root.hfs', 'wb'); f.truncate(${SIZE_GB} * 1024**3); f.close()"
HFS_DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/ios16-root.hfs" | head -n1 | awk '{print $1}')
HFS_RDEV=${HFS_DEV/disk/rdisk}
newfs_hfs -s -J -v iOSRoot "$HFS_RDEV"
hdiutil detach "$HFS_DEV"
HFS_DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -owners on -mountpoint "$WORK/root" "$WORK/ios16-root.hfs" | head -n1 | awk '{print $1}')
sudo diskutil enableOwnership "$HFS_DEV" 2>/dev/null || true
sudo mdutil -i off "$WORK/root" 2>/dev/null || true

extract_and_copy_dmg() {
    local dmg_name=$1
    local dst_dir=$2
    echo "=== Extracting $dmg_name from IPSW ==="
    python3 "$REPO_ROOT/tools/remotezip.py" "$IPSW_URL" "$dmg_name" "$WORK/ipsw"
    local dmg_path="$WORK/ipsw/$dmg_name"
    ls -lh "$dmg_path"

    echo "=== Attaching $dmg_name ==="
    local attach_out
    if ! attach_out=$(hdiutil attach -nobrowse -readonly "$dmg_path" 2>&1); then
        echo "Standard hdiutil attach returned non-zero, retrying with CRawDiskImage..."
        attach_out=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -readonly "$dmg_path")
    fi
    echo "$attach_out"

    local mnt
    mnt=$(echo "$attach_out" | awk -F'\t' 'NF>=3 && $3 != "" {print $3; exit}' | sed 's/[[:space:]]*$//')
    if [[ -z "$mnt" || ! -d "$mnt" ]]; then
        echo "No auto-mount in hdiutil output; mounting APFS slice explicitly..."
        local slice
        slice=$(echo "$attach_out" | awk '/41504653|^\/dev\/disk[0-9]+s[0-9]+/ {s=$1} END {print s}')
        mkdir -p "$WORK/dmg_mnt"
        if ! sudo mount_apfs -o rdonly "$slice" "$WORK/dmg_mnt" 2>/dev/null; then
            diskutil mount readOnly -mountPoint "$WORK/dmg_mnt" "$slice"
        fi
        mnt="$WORK/dmg_mnt"
    fi
    local devs
    devs=$(echo "$attach_out" | awk '/^\/dev\/disk[0-9]+/ {print $1}' | sed -E 's/s[0-9]+.*//' | sort -ur)

    local src="$mnt"
    if [[ -d "$mnt/root/System" ]]; then
        src="$mnt/root"
    fi
    echo "=== Copying $src -> $dst_dir ==="
    sudo mkdir -p "$dst_dir"
    sudo "$RSYNC" -aH --numeric-ids \
        --exclude='.Spotlight-V100' \
        --exclude='.fseventsd' \
        --exclude='.Trashes' \
        "$src/" "$dst_dir/"

    echo "=== Detaching $dmg_name ($devs) and removing DMG ==="
    sudo umount -f "$WORK/dmg_mnt" 2>/dev/null || true
    for d in $devs; do
        hdiutil detach "$d" -force 2>/dev/null || true
    done
    rm -f "$dmg_path"
    df -h / "$WORK/root"
}

# 1. OS rootfs (087-86698-044.dmg)
extract_and_copy_dmg "087-86698-044.dmg" "$WORK/root"

echo "=== Verifying /sbin/launchd on HFS+ is uncompressed arm64 Mach-O ==="
ls -lO "$WORK/root/sbin/launchd"
xxd -l 16 "$WORK/root/sbin/launchd"
MAGIC=$(xxd -p -l 4 "$WORK/root/sbin/launchd")
LSIZE=$(stat -f %z "$WORK/root/sbin/launchd")
echo "/sbin/launchd magic=$MAGIC size=$LSIZE"
[[ "$MAGIC" == "cffaedfe" && "$LSIZE" -gt 100000 ]] || { echo "ERROR: /sbin/launchd not decompressed properly!" >&2; exit 1; }

# 2. Cryptex1,SystemOS (087-86593-047.dmg)
extract_and_copy_dmg "087-86593-047.dmg" "$WORK/root/private/preboot/Cryptexes/OS"

# 3. Cryptex1,AppOS (087-86715-047.dmg)
extract_and_copy_dmg "087-86715-047.dmg" "$WORK/root/private/preboot/Cryptexes/App"

echo "=== Hard-linking dyld shared cache and Cryptex files ==="
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$WORK/root/System/Library/Caches/com.apple.dyld"
for f in "$WORK/root/$dsc"/*; do
    sudo ln -f "$f" "$WORK/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

for c in OS App; do
    (cd "$WORK/root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*' ! -path './.Spotlight-V100*' ! -path './.fseventsd*' ! -path './.Trashes*') |
    while IFS= read -r f; do
        f=${f#./}
        if ! sudo test -e "$WORK/root/$f" && ! sudo test -L "$WORK/root/$f"; then
            sudo mkdir -p "$WORK/root/$(dirname "$f")"
            src="$WORK/root/private/preboot/Cryptexes/$c/$f"
            if sudo test -L "$src"; then
                sudo cp -P "$src" "$WORK/root/$f"
            else
                sudo ln "$src" "$WORK/root/$f"
            fi
            echo "linked $c:/$f"
        fi
    done
done

echo "=== Creating logd directories and systembag.kb ==="
sudo mkdir -p "$WORK/root/private/var/db/diagnostics/timesync" "$WORK/root/private/var/db/uuidtext" "$WORK/root/private/var/keybags"
sudo chown -R 272:272 "$WORK/root/private/var/db/diagnostics" "$WORK/root/private/var/db/uuidtext"
sudo chmod 0751 "$WORK/root/private/var/db/diagnostics"
sudo chmod 0755 "$WORK/root/private/var/db/uuidtext" "$WORK/root/private/var/db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
    sudo touch "$WORK/root/private/var/db/$d/.migrated"
    sudo chown 272:272 "$WORK/root/private/var/db/$d/.migrated"
    sudo chmod 0644 "$WORK/root/private/var/db/$d/.migrated"
done

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' | \
    sudo tee "$WORK/root/private/var/keybags/systembag.kb" >/dev/null
sudo chown 0:0 "$WORK/root/private/var/keybags" "$WORK/root/private/var/keybags/systembag.kb"
sudo chmod 0700 "$WORK/root/private/var/keybags"
sudo chmod 0600 "$WORK/root/private/var/keybags/systembag.kb"

echo "=== Applying sweet-root-tweaks.py, vince-gputest-install.py, and vince-topaz-install.py ==="
sudo python3 "$REPO_ROOT/tools/sweet-root-tweaks.py" "$WORK/root"
sudo python3 "$REPO_ROOT/vince/tools/vince-gputest-install.py" "$WORK/root" "$MESA_DIR"
sudo python3 "$REPO_ROOT/vince/tools/vince-topaz-install.py" "$WORK/root" "$TOPAZ_DIR"

echo "=== Final HFS+ root usage ==="
df -h "$WORK/root"
ls -la "$WORK/root/topaz/lib" "$WORK/root/usr/libexec/backboardd" "$WORK/root/usr/libexec/real/backboardd"

sync
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$HFS_DEV"; then
        HFS_DEV=""
        break
    fi
    sleep 2
done
if [[ -n "$HFS_DEV" ]]; then
    hdiutil detach "$HFS_DEV" -force
    HFS_DEV=""
fi

echo "=== Running fsck_hfs on ios16-root.hfs ==="
HFS_DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/ios16-root.hfs" | head -n1 | awk '{print $1}')
HFS_RDEV=${HFS_DEV/disk/rdisk}
sudo fsck_hfs -fy "$HFS_RDEV" || true
sudo fsck_hfs -fn "$HFS_RDEV"
hdiutil detach "$HFS_DEV"
HFS_DEV=""

echo "=== Converting ios16-root.hfs to Android sparse image ios16-root.simg ==="
python3 "$REPO_ROOT/tools/sparsediff.py" - "$WORK/ios16-root.hfs" "$WORK/ios16-root.simg"
rm -f "$WORK/ios16-root.hfs"
ls -lh "$WORK/ios16-root.simg"
shasum -a 256 "$WORK/ios16-root.simg" | tee "$OUT_DIR/ios16-root.simg.sha256"

echo "=== Compressing and splitting ios16-root.simg into <950 MiB tar.zst chunks ==="
tar -cf - -C "$WORK" ios16-root.simg | zstd -3 -T0 | split -b 950m - "$OUT_DIR/ios16-root.simg.tar.zst.part-"
rm -f "$WORK/ios16-root.simg"
ls -lh "$OUT_DIR"
