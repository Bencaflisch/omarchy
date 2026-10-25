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

# Records the drop-in each build reads. limine-mkinitcpio 1.40 reports a kernel
# whose image failed to build and still exits 0, so "skip" fails that way.
cat >"$tmpdir/bin/limine-mkinitcpio" <<'EOF'
#!/bin/bash
cat "$DROP_IN" >>"$REBUILD_LOG"
case ${REBUILD_RESULT:-ok} in
  skip) echo "==> ERROR: mkinitcpio failed for kernel 7.2.8-9-omarchy, skipping." >&2 ;;
  fail) exit 1 ;;
esac
exit 0
EOF

chmod +x "$tmpdir/bin/"*

uuid=0f3c5a1e-7d2b-4c8e-9a61-2b7e4d9c1f08
uuid_line="KERNEL_CMDLINE[default]+=\" resume=UUID=$uuid resume_offset=4242\""
drop_in=$tmpdir/limine-entry-tool.d/resume.conf
hook=$tmpdir/mkinitcpio.conf.d/omarchy_resume.conf

reset_machine() {
  rm -rf "$tmpdir/limine-entry-tool.d" "$tmpdir/mkinitcpio.conf.d" "$tmpdir/rebuilds" "$tmpdir/sleep"/*
  mkdir -p "$tmpdir/sleep"
  : >"$tmpdir/sys/image_size"
  : >"$tmpdir/swapfile"
  : >"$tmpdir/fstab"
  : >"$tmpdir/rebuilds"
}

configured_machine() {
  reset_machine
  mkdir -p "$tmpdir/limine-entry-tool.d" "$tmpdir/mkinitcpio.conf.d"
  printf 'HOOKS+=(resume)\n' >"$hook"
  printf '%s\n' "$1" >"$drop_in"
}

setup() {
  env PATH="$tmpdir/bin:$PATH" SWAP_FILE_PATH="$tmpdir/swapfile" REBUILD_LOG="$tmpdir/rebuilds" \
    DROP_IN="$drop_in" SWAP_SOURCE="$SWAP_SOURCE" SWAP_UUID="$uuid" REBUILD_RESULT="${REBUILD_RESULT:-ok}" \
    bash "$tmpdir/setup" "$@" >"$tmpdir/out" 2>&1
}

rebuilds() {
  wc -l <"$tmpdir/rebuilds"
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

# A machine set up before names the partition. Rerunning setup renames it and
# rebuilds the boot image from the renamed drop-in; another run changes nothing.
configured_machine 'KERNEL_CMDLINE[default]+=" resume=/dev/nvme1n1p2 resume_offset=4242"'
SWAP_SOURCE="/dev/nvme0n1p2[/@swap]" setup ||
  fail "setup repairs a drop-in naming a partition" "$(<"$tmpdir/out")"
[[ $(<"$drop_in") == "$uuid_line" ]] ||
  fail "setup renames a partition in an existing drop-in by its filesystem UUID" "$(<"$drop_in")"
[[ $(<"$tmpdir/rebuilds") == "$uuid_line" ]] ||
  fail "setup rebuilds the boot image once, from the renamed drop-in" "$(<"$tmpdir/rebuilds")"
SWAP_SOURCE="/dev/nvme0n1p2[/@swap]" setup || fail "a second setup succeeds" "$(<"$tmpdir/out")"
(( $(rebuilds) == 1 )) || fail "a second setup leaves a UUID drop-in and the boot image alone"
pass "setup renames a partition in an existing drop-in once"

# Omarchy 3.4 wrote the line without a space after the quote.
configured_machine 'KERNEL_CMDLINE[default]+="resume=/dev/sda2 resume_offset=4242"'
SWAP_SOURCE="/dev/sda2[/@swap]" setup || fail "setup repairs a 3.4 drop-in" "$(<"$tmpdir/out")"
[[ $(<"$drop_in") == "$uuid_line" ]] || fail "setup renames the device in a 3.4 drop-in" "$(<"$drop_in")"
pass "setup renames the device in a 3.4 drop-in"

# The renamed device must reach the boot image. If a kernel's image is not
# rebuilt, the old line goes back so the next run tries again.
for result in skip fail; do
  configured_machine 'KERNEL_CMDLINE[default]+=" resume=/dev/sda2 resume_offset=4242"'
  if SWAP_SOURCE="/dev/sda2[/@swap]" REBUILD_RESULT=$result setup; then
    fail "setup reports a rebuild that did not happen ($result)"
  fi
  [[ $(<"$drop_in") == 'KERNEL_CMDLINE[default]+=" resume=/dev/sda2 resume_offset=4242"' ]] ||
    fail "setup restores the drop-in when the rebuild fails ($result)" "$(<"$drop_in")"
done
pass "setup restores the drop-in when the rebuild fails"

# The factory reset and the installer rebuild the image themselves.
configured_machine 'KERNEL_CMDLINE[default]+=" resume=/dev/vda2 resume_offset=4242"'
SWAP_SOURCE="/dev/vda2[/@swap]" setup --force --no-rebuild || fail "setup --no-rebuild succeeds" "$(<"$tmpdir/out")"
[[ $(<"$drop_in") == "$uuid_line" ]] || fail "setup --no-rebuild renames the resume device" "$(<"$drop_in")"
(( $(rebuilds) == 0 )) || fail "setup --no-rebuild leaves the rebuild to its caller"
pass "setup --no-rebuild renames the resume device and leaves the rebuild to its caller"

# An encrypted install's drop-in is already stable, and a drop-in edited by hand
# belongs to whoever edited it.
for line in 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=4242"' \
  $'KERNEL_CMDLINE[default]+=" resume=/dev/nvme0n1p2\tresume_offset=4242"' \
  $'KERNEL_CMDLINE[default]+=" resume=/dev/nvme0n1p2 resume_offset=4242"\nKERNEL_CMDLINE[default]+=" mem_sleep_default=deep"'; do
  configured_machine "$line"
  SWAP_SOURCE="/dev/nvme0n1p2[/@swap]" setup || fail "setup on a drop-in it does not own succeeds" "$(<"$tmpdir/out")"
  [[ $(<"$drop_in") == "$line" ]] || fail "setup leaves a drop-in it does not own alone" "$(<"$drop_in")"
  (( $(rebuilds) == 0 )) || fail "setup does not rebuild for a drop-in it does not own"
done
pass "setup leaves device-mapper and hand-edited drop-ins alone"
