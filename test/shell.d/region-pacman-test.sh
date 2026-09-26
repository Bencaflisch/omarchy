#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OMARCHY_PATH="$ROOT"
export TARGET_ROOT="$scratch/target root"
mkdir -p "$TARGET_ROOT/etc/omarchy"

apply() { "$ROOT/bin/omarchy-apply-pacman" "$1" "$TARGET_ROOT"; }

for channel in stable rc edge; do
  apply "$channel"
  cmp "$ROOT/default/pacman/pacman-$channel.conf" "$TARGET_ROOT/etc/pacman.conf"
  cmp "$ROOT/default/pacman/mirrorlist-$channel" "$TARGET_ROOT/etc/pacman.d/mirrorlist"
done
pass "missing region preserves all global channel templates byte for byte"

printf 'cn\n' > "$TARGET_ROOT/etc/omarchy/region"
for channel in stable rc edge; do
  case "$channel" in
    stable) host=stable-mirror.omarchy.org ;;
    rc) host=rc-mirror.omarchy.org ;;
    edge) host=mirror.omarchy.org ;;
  esac
  apply "$channel"
  expected=$(printf 'Server = https://%s/$repo/os/$arch\nServer = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch' "$host")
  [[ $(<"$TARGET_ROOT/etc/pacman.d/mirrorlist") == "$expected" ]] || fail "$channel mirror order and variables"
  {
    cat "$ROOT/default/pacman/pacman-$channel.conf"
    printf '\n[archlinuxcn]\nServer = https://mirrors.ustc.edu.cn/archlinuxcn/$arch\n'
  } > "$scratch/expected.conf"
  cmp "$scratch/expected.conf" "$TARGET_ROOT/etc/pacman.conf"
  apply "$channel"
  cmp "$TARGET_ROOT/etc/pacman.conf.bak" "$TARGET_ROOT/etc/pacman.conf"
  cmp "$TARGET_ROOT/etc/pacman.d/mirrorlist.bak" "$TARGET_ROOT/etc/pacman.d/mirrorlist"
done
pass "China keeps each channel first, appends only CN defaults, and is idempotent"

cp "$TARGET_ROOT/etc/pacman.conf" "$scratch/before.conf"
cp "$TARGET_ROOT/etc/pacman.d/mirrorlist" "$scratch/before.mirrors"
for region in '' CN chn zz '../cn' '$(touch NEVER_EXECUTE)'; do
  printf '%s\n' "$region" > "$TARGET_ROOT/etc/omarchy/region"
  if apply stable > "$scratch/error" 2>&1; then
    fail "invalid region accepted: $region"
  fi
  cmp "$scratch/before.conf" "$TARGET_ROOT/etc/pacman.conf"
  cmp "$scratch/before.mirrors" "$TARGET_ROOT/etc/pacman.d/mirrorlist"
done
pass "unsupported and malformed regions fail before replacing either config"

printf 'cn\n' > "$TARGET_ROOT/etc/omarchy/region"
mkdir -p "$scratch/incomplete/default/regions/cn/pacman"
cp -a "$ROOT/default/pacman" "$scratch/incomplete/default/"
cp "$ROOT/default/regions/cn/pacman/pacman.conf.append" "$scratch/incomplete/default/regions/cn/pacman/"
if OMARCHY_PATH="$scratch/incomplete" apply stable > "$scratch/error" 2>&1; then
  fail "incomplete region profile accepted"
fi
cmp "$scratch/before.conf" "$TARGET_ROOT/etc/pacman.conf"
cmp "$scratch/before.mirrors" "$TARGET_ROOT/etc/pacman.d/mirrorlist"
pass "missing fragment cannot leave a half-generated config"

# Execute the real refresh and apply commands against the same disposable root.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/sudo" <<'SH'
#!/bin/bash
exec "$@" "$TARGET_ROOT"
SH
cat > "$scratch/bin/omarchy-hook" <<'SH'
#!/bin/bash
[[ $1 == "pre-refresh-pacman" ]] || exit 1
printf '# user customization\n' >> "$TARGET_ROOT/etc/pacman.conf"
SH
cat > "$scratch/bin/omarchy-update-pacman" <<'SH'
#!/bin/bash
[[ $* == "-Syyuu --noconfirm" ]] || exit 1
tail -n 1 "$TARGET_ROOT/etc/pacman.conf" > "$TARGET_ROOT/update-observed"
SH
chmod +x "$scratch/bin/"*
PATH="$scratch/bin:$PATH" "$ROOT/bin/omarchy-refresh-pacman" rc
[[ $(<"$TARGET_ROOT/update-observed") == '# user customization' ]] || fail "hook runs before update"
rg -qxF 'Server = https://pkgs.omarchy.org/rc/$arch' "$TARGET_ROOT/etc/pacman.conf"
rg -qxF '[archlinuxcn]' "$TARGET_ROOT/etc/pacman.conf"
pass "channel refresh retains region and applies user customization before updating"

printf 'not-updated\n' > "$TARGET_ROOT/update-observed"
if PATH="$scratch/bin:$PATH" "$ROOT/bin/omarchy-refresh-pacman" dev > "$scratch/error" 2>&1; then
  fail "refresh accepts a nonexistent dev pacman template"
fi
[[ $(<"$TARGET_ROOT/update-observed") == 'not-updated' ]] || fail "failed generation still updates packages"
pass "failed refresh does not proceed to a package update"

printf 'global\n' > "$TARGET_ROOT/etc/omarchy/region"
apply stable
cmp "$ROOT/default/pacman/pacman-stable.conf" "$TARGET_ROOT/etc/pacman.conf"
cmp "$ROOT/default/pacman/mirrorlist-stable" "$TARGET_ROOT/etc/pacman.d/mirrorlist"
pass "users can opt out of regional repository defaults"

# Check the shipped input defaults, not a synthetic profile. ISO tests cover
# staging these files before user creation; refresh must never touch them.
python3 - <<'PY'
import configparser
import os
from pathlib import Path

root = Path(os.environ["ROOT"])
region = root / "default/regions/cn"
packages = {line.strip() for line in (region / "packages").read_text().splitlines() if line.strip() and not line.startswith("#")}
assert packages == {"archlinuxcn-keyring", "fcitx5-chinese-addons"}
base = (root / "install/omarchy-base.packages").read_text().splitlines()
assert {"fcitx5", "fcitx5-gtk", "fcitx5-qt"} <= set(base)

def read_config(name):
    config = configparser.ConfigParser()
    config.read(region / "skel/.config/fcitx5" / name)
    return config

profile = read_config("profile")
assert profile["Groups/0"]["DefaultIM"] == "pinyin"
assert profile["Groups/0"]["Default Layout"]  # Fcitx rejects empty layouts.
assert profile["Groups/0/Items/0"]["Name"] == "keyboard-us"
assert profile["Groups/0/Items/1"]["Name"] == "pinyin"
assert all("Layout" not in profile[section] for section in ("Groups/0/Items/0", "Groups/0/Items/1"))
assert (root / "config/fcitx5/conf/xcb.conf").read_text().strip() == "Allow Overriding System XKB Settings=False"
config = read_config("config")
assert dict(config["Hotkey/TriggerKeys"]) == {"0": "Alt+space"}
assert not config["Hotkey"].getboolean("EnumerateWithTriggerKeys")
for key in ("AltTriggerKeys", "EnumerateForwardKeys", "EnumerateBackwardKeys"):
    assert config["Hotkey"][key] == ""
assert not config["Behavior"].getboolean("ActiveByDefault")
# No second startup path or regional locale/keyboard defaults.
assert {str(path.relative_to(region / "skel")) for path in (region / "skel").rglob("*") if path.is_file()} == {
    ".config/fcitx5/config", ".config/fcitx5/profile",
}
PY
pass "China ships offline Pinyin using the base Fcitx service without stealing compose or terminal shortcuts"
