#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/sys" "$tmpdir/sleep"

# Run the real command with every system path it writes moved into $tmpdir.
sed -e "s|/sys/power/|$tmpdir/sys/|g" \
  -e "s|/etc/mkinitcpio.conf.d|$tmpdir/mkinitcpio.conf.d|g" \
  -e "s|/etc/limine-entry-tool.d|$tmpdir/limine-entry-tool.d|g" \
  -e "s|/etc/fstab|$tmpdir/fstab|g" \
  -e "s|/swap/swapfile|$tmpdir/swapfile|g" \
  -e "s|/usr/lib/systemd/system-sleep|$tmpdir/sleep|g" \
  "$ROOT/bin/omarchy-hibernation-setup" >"$tmpdir/setup"

for command in omarchy-hw-aarch64-apple omarchy-sleep-disabled omarchy-cmd-missing gum; do
  printf '#!/bin/bash\nexit 1\n' >"$tmpdir/bin/$command"
done
printf '#!/bin/bash\nexit 0\n' >"$tmpdir/bin/swaplabel"

cat >"$tmpdir/bin/sudo" <<'EOF'
#!/bin/bash
# Root ownership is not ours to give in a test.
if [[ $1 == */install ]]; then
  args=()
  while (($#)); do
    case $1 in
      -o | -g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
fi
exec "$@"
EOF

cat >"$tmpdir/bin/swapon" <<'EOF'
#!/bin/bash
[[ $1 == --show ]] && printf '%s file 4G 0B 0\n' "$SWAP_FILE_PATH"
exit 0
EOF

cat >"$tmpdir/bin/btrfs" <<'EOF'
#!/bin/bash
[[ $1 == inspect-internal ]] && echo 4242
exit 0
EOF

# The swapfile's filesystem, as findmnt reports it for the source and UUID columns.
cat >"$tmpdir/bin/findmnt" <<'EOF'
#!/bin/bash
case $2 in
  SOURCE) echo "$SWAP_SOURCE" ;;
  UUID) echo "$SWAP_UUID" ;;
esac
EOF

chmod +x "$tmpdir/bin/"*

uuid=0f3c5a1e-7d2b-4c8e-9a61-2b7e4d9c1f08
uuid_line="KERNEL_CMDLINE[default]+=\" resume=UUID=$uuid resume_offset=4242\""
drop_in=$tmpdir/limine-entry-tool.d/resume.conf

reset_machine() {
  rm -rf "$tmpdir/limine-entry-tool.d" "$tmpdir/mkinitcpio.conf.d" "$tmpdir/sleep"/*
  mkdir -p "$tmpdir/sleep"
  : >"$tmpdir/sys/image_size"
  : >"$tmpdir/swapfile"
  : >"$tmpdir/fstab"
}

setup() {
  env PATH="$tmpdir/bin:$PATH" SWAP_FILE_PATH="$tmpdir/swapfile" SWAP_SOURCE="$SWAP_SOURCE" SWAP_UUID="$uuid" \
    bash "$tmpdir/setup" "$@" >"$tmpdir/out" 2>&1
}

# A first setup on an unencrypted root names the filesystem, not the partition:
# with two NVMe disks the partition's kernel name can belong to the other disk at
# the next boot.
reset_machine
SWAP_SOURCE="/dev/nvme0n1p2[/@swap]" setup --force --no-rebuild ||
  fail "first setup on an unencrypted root succeeds" "$(<"$tmpdir/out")"
[[ $(<"$drop_in") == "$uuid_line" ]] ||
  fail "first setup names an unencrypted root by its filesystem UUID" "$(<"$drop_in")"
pass "first setup names an unencrypted root by its filesystem UUID"

# The device-mapper name of an encrypted root is stable, so it stays.
reset_machine
SWAP_SOURCE="/dev/mapper/root[/@swap]" setup --force --no-rebuild ||
  fail "first setup on an encrypted root succeeds" "$(<"$tmpdir/out")"
[[ $(<"$drop_in") == 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=4242"' ]] ||
  fail "first setup keeps the device-mapper name of an encrypted root" "$(<"$drop_in")"
pass "first setup keeps the device-mapper name of an encrypted root"
