#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" CARGO_HOME="$scratch/home/.cargo" OMARCHY_PATH="$ROOT"
mkdir -p "$HOME"
user() { "$ROOT/bin/omarchy-region-user" "$@"; }

user cn
grep -qF 'registry = "sparse+https://mirrors.aliyun.com/crates.io-index/"' "$CARGO_HOME/config.toml" ||
  fail "China points cargo at the regional crates.io index" "$(cat "$CARGO_HOME/config.toml")"
user cn
[[ $(grep -c '^\[source.crates-io\]' "$CARGO_HOME/config.toml") == 1 ]] || fail "applying China twice adds one block"
user global
[[ ! -e $CARGO_HOME/config.toml ]] || fail "World removes a cargo config only the region wrote"
printf '[build]\njobs = 4\n' >"$CARGO_HOME/config.toml"
touch -d '2001-01-01' "$CARGO_HOME/config.toml"
user global
[[ $(stat -c %Y "$CARGO_HOME/config.toml") == $(date -d '2001-01-01' +%s) ]] || fail "World leaves a config without the region's block untouched"
rm "$CARGO_HOME/config.toml"
pass "the cargo registry follows the region and World removes it"

for original in '[build]\njobs = 4\n\n[net]\nretry = 5\n' '[build]\njobs = 4' '' '[build]\njobs = 4\n\n'; do
  printf "$original" >"$CARGO_HOME/config.toml"
  cp "$CARGO_HOME/config.toml" "$scratch/before.toml"
  user cn
  grep -q 'mirrors.aliyun.com/crates.io-index' "$CARGO_HOME/config.toml" || fail "China adds its registry to an existing cargo config"
  python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$CARGO_HOME/config.toml" || fail "China leaves valid TOML"
  user cn
  user global
  cmp "$scratch/before.toml" "$CARGO_HOME/config.toml" || fail "World restores the user's cargo config byte for byte" "$(od -c "$CARGO_HOME/config.toml" | head)"
done
rm "$CARGO_HOME/config.toml"
user cn
printf '[net]\nretry = 5\n' >>"$CARGO_HOME/config.toml"
user global
[[ $(<"$CARGO_HOME/config.toml") == $'[net]\nretry = 5' ]] || fail "World keeps what the user added after the region's block" "$(cat "$CARGO_HOME/config.toml")"
rm "$CARGO_HOME/config.toml"
user cn
{ printf '[build]\njobs = 4\n'; cat "$CARGO_HOME/config.toml"; } >"$scratch/prepended" && mv "$scratch/prepended" "$CARGO_HOME/config.toml"
user global
[[ $(<"$CARGO_HOME/config.toml") == $'[build]\njobs = 4' ]] || fail "World keeps what the user added above the region's block" "$(cat "$CARGO_HOME/config.toml")"
rm "$CARGO_HOME/config.toml"
printf '[build]\njobs = 4' >"$CARGO_HOME/config.toml"
user cn
printf '[net]\nretry = 5\n' >>"$CARGO_HOME/config.toml"
user global
[[ $(cat "$CARGO_HOME/config.toml"; echo .) == $'[build]\njobs = 4\n[net]\nretry = 5\n.' ]] || fail "World keeps lines apart around a joined block" "$(cat "$CARGO_HOME/config.toml")"
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$CARGO_HOME/config.toml" || fail "World leaves valid TOML around a joined block"
rm "$CARGO_HOME/config.toml"
pass "the user's own cargo config survives China and World byte for byte, empty or without a final newline"

for own in '[source.crates-io]\n' '[source.omarchy-region]\nregistry = "x"\n' '[source.crates-io]\nreplace-with = "mine"\n' '  [source."crates-io"]\nreplace-with = "mine"\n' '[source]\ncrates-io = { replace-with = "mine" }\n' 'not = valid = toml\n'; do
  printf "$own" >"$CARGO_HOME/config.toml"
  cp "$CARGO_HOME/config.toml" "$scratch/own.toml"
  user cn 2>/dev/null
  cmp "$scratch/own.toml" "$CARGO_HOME/config.toml" || fail "China leaves alone: $own"
done
# An inline source table cannot take the block's tables, and World never
# rewrites a config that no longer reads as TOML.
printf 'source = {}\n' >"$CARGO_HOME/config.toml"
cp "$CARGO_HOME/config.toml" "$scratch/own.toml"
user cn 2>/dev/null
cmp "$scratch/own.toml" "$CARGO_HOME/config.toml" || fail "China leaves an inline source table alone" "$(cat "$CARGO_HOME/config.toml")"
printf '[build]\njobs = 4\n' >"$CARGO_HOME/config.toml"
user cn
printf 'not = valid = toml\n' >>"$CARGO_HOME/config.toml"
cp "$CARGO_HOME/config.toml" "$scratch/own.toml"
user global 2>/dev/null
cmp "$scratch/own.toml" "$CARGO_HOME/config.toml" || fail "World leaves a config that no longer reads as TOML alone"
rm "$CARGO_HOME/config.toml"
pass "a user's own crates.io setting, however spelled, and an unreadable config are left alone"

# A hand-edited block is never guessed at: the file stays as it is, and the
# switch itself still succeeds.
begin="# BEGIN omarchy region: managed by omarchy-region, removed for World"
for edited in "$begin appended\n[a]\nx = 1\n[b]\n$begin appended\n[c]\n# END omarchy region\n" \
  "$begin appended\n[a]\n" "$begin appended\n[a]\n# END omarchy region" "$begin mine\n[a]\n# END omarchy region\n" "[a]\n# END omarchy region\n"; do
  printf "$edited" >"$CARGO_HOME/config.toml"
  cp "$CARGO_HOME/config.toml" "$scratch/edited.toml"
  for region in global cn; do
    user "$region" 2>/dev/null || fail "an edited block fails the $region switch"
    cmp "$scratch/edited.toml" "$CARGO_HOME/config.toml" || fail "$region leaves an edited block alone: $edited"
  done
done
rm "$CARGO_HOME/config.toml"
user cn
sed -i 's#mirrors.aliyun.com#mirrors.example.invalid#' "$CARGO_HOME/config.toml"
grep -q 'mirrors.example.invalid' "$CARGO_HOME/config.toml" || fail "the test edits inside the region's block"
cp "$CARGO_HOME/config.toml" "$scratch/edited.toml"
for region in global cn; do
  user "$region" 2>/dev/null || fail "a block edited inside fails the $region switch"
  cmp "$scratch/edited.toml" "$CARGO_HOME/config.toml" || fail "$region leaves a block edited inside alone"
done
# The blank line ahead of an appended block is the block's: once the user
# removes it, taking the block out would join their lines.
printf '[build]\njobs = 4\n' >"$CARGO_HOME/config.toml"
user cn
python3 - "$CARGO_HOME/config.toml" <<'PY2'
import sys
path = sys.argv[1]
text = open(path).read().replace("\n\n# BEGIN omarchy region", "\n# BEGIN omarchy region")
open(path, "w").write(text + "[net]\nretry = 5\n")
PY2
cp "$CARGO_HOME/config.toml" "$scratch/edited.toml"
user global 2>/dev/null || fail "a block missing its separator fails the World switch"
cmp "$scratch/edited.toml" "$CARGO_HOME/config.toml" || fail "World leaves a block missing its separator alone" "$(cat "$CARGO_HOME/config.toml")"
rm "$CARGO_HOME/config.toml"
user cn
sed -i 's/World created$/WorldXcreated/' "$CARGO_HOME/config.toml"
grep -q 'WorldXcreated$' "$CARGO_HOME/config.toml" || fail "the test edits the block's marker"
cp "$CARGO_HOME/config.toml" "$scratch/edited.toml"
user global 2>/dev/null || fail "an edited marker fails the World switch"
cmp "$scratch/edited.toml" "$CARGO_HOME/config.toml" || fail "World leaves a block with an edited marker alone"
rm "$CARGO_HOME/config.toml"
pass "a hand-edited region block is left exactly as it is"

# Shells read the registries from the marker through env-bootstrap, as an
# ordinary user even when the suite runs as root.
mkdir -p "$scratch/userbin"
printf '#!/bin/sh\necho 1000\n' >"$scratch/userbin/id"
chmod +x "$scratch/userbin/id"
printf 'OMARCHY_PATH=%q\n' "$ROOT" >"$scratch/omarchy.conf"
sed "s#/etc/omarchy.conf#$scratch/omarchy.conf#g" "$ROOT/default/bash/env-bootstrap" >"$scratch/env-bootstrap"
shell_env() {
  env -i HOME="$HOME" PATH="$scratch/userbin:/usr/bin:/bin" OMARCHY_REGION_FILE="$scratch/region" ${1:+"$1"} \
    sh -c '. "$0"; env' "$scratch/env-bootstrap"
}
rm -f "$scratch/region"
shell_env >/dev/null || fail "env-bootstrap runs for World"
! shell_env | grep -qE '^(NPM_CONFIG_REGISTRY|GOPROXY|GOSUMDB|MAVEN_ARGS)=' || fail "World exports no registries"
printf 'cn\n' >"$scratch/region"
env_cn=$(shell_env) || fail "env-bootstrap runs for China"
grep -qx 'GOSUMDB=sum.golang.google.cn' <<<"$env_cn" || fail "China exports a reachable Go checksum database" "$env_cn"
grep -qx 'NPM_CONFIG_REGISTRY=https://registry.npmmirror.com' <<<"$env_cn" || fail "China exports the npm mirror"
grep -qx 'NPM_CONFIG_REGISTRY=https://example.invalid/npm' <<<"$(shell_env NPM_CONFIG_REGISTRY=https://example.invalid/npm)" ||
  fail "a registry the user set first is kept"
printf 'cn' >"$scratch/region"
strict=$(env -i HOME="$HOME" PATH="$scratch/userbin:/usr/bin:/bin" OMARCHY_REGION_FILE="$scratch/region" sh -ec '. "$0"; echo "survived $GOPROXY"' "$scratch/env-bootstrap") ||
  fail "a marker without a final newline ends a set -e shell"
[[ $strict == "survived https://mirrors.aliyun.com/goproxy/,direct" ]] || fail "a marker without a final newline still selects its region" "$strict"
printf '../x\n' >"$scratch/region"
! shell_env | grep -q '^GOPROXY=' || fail "a malformed marker exports nothing"
pass "shells export the region's registries only for China, and keep the user's own"

# Root never sources a region's environment: on a dev link it lives in a
# user-writable checkout.
mkdir -p "$scratch/rootbin"
printf '#!/bin/sh\necho 0\n' >"$scratch/rootbin/id"
chmod +x "$scratch/rootbin/id"
printf 'cn\n' >"$scratch/region"
root_env=$(env -i HOME="$HOME" PATH="$scratch/rootbin:/usr/bin:/bin" OMARCHY_REGION_FILE="$scratch/region" sh -c '. "$0"; env' "$scratch/env-bootstrap") ||
  fail "env-bootstrap runs for root"
! grep -q '^GOPROXY=' <<<"$root_env" || fail "root's shells export no regional registries"
pass "root's shells never source a region's environment"
