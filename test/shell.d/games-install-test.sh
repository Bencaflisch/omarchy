#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command gio
require_command magick

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/omarchy-launch-webapp" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >>"$OMARCHY_TEST_ARGV"
SH
chmod +x "$mock_bin/omarchy-launch-webapp"

# A home with a space and a percent sign, which the file URL and the Exec quoting both have to survive.
export HOME="$test_tmp/my home 100%"
export OMARCHY_PATH="$ROOT"
export PATH="$mock_bin:$ROOT/bin:$PATH"
export OMARCHY_TEST_ARGV="$test_tmp/argv"
export OMARCHY_REMOVE_NOTIFY=false
applications="$HOME/.local/share/applications"
icons="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$HOME/.local/state/omarchy/current/theme"
printf 'background = "#1a1b26"\nforeground = "#a9b1d6"\naccent = "#7aa2f7"\n' >"$HOME/.local/state/omarchy/current/theme/colors.toml"

make_game() {
  mkdir -p "$HOME/Games/$1"
  printf '<!doctype html><title>%s</title>\n' "$1" >"$HOME/Games/$1/index.html"
}

refuses() {
  ! omarchy-games-install "$@" >/dev/null 2>&1
}

launched_argument() {
  local attempt
  : >"$OMARCHY_TEST_ARGV"
  gio launch "$1" >/dev/null 2>&1 || return 1
  for ((attempt = 0; attempt < 200; attempt++)); do
    [[ -s $OMARCHY_TEST_ARGV ]] && break
    sleep 0.01
  done
  head -1 "$OMARCHY_TEST_ARGV"
}

make_game tilt-maze
printf '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" rx="12" fill="#7aa2f7"/></svg>\n' >"$HOME/Games/tilt-maze/icon.svg"
omarchy-games-install tilt-maze >/dev/null || fail "games install adds a game in ~/Games"
desktop="$applications/Tilt Maze.desktop"
[[ -f $desktop ]] || fail "games install names the launcher after the game"
url=$(launched_argument "$desktop")
[[ $url == file://* ]] || fail "the launcher opens the game as a file URL" "$url"
decoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1].removeprefix("file://").split("#")[0]))' "$url")
[[ $decoded == "$HOME/Games/tilt-maze/index.html" ]] || fail "the file URL names the game's index.html" "$url"
accent=$(python3 -c 'import json, sys, urllib.parse; print(json.loads(urllib.parse.unquote(sys.argv[1].split("#palette=")[1]))["accent"])' "$url")
[[ $accent == "#7aa2f7" ]] || fail "the game is opened with the current theme's palette" "$url"
grep -qx 'Categories=Game;' "$desktop" || fail "the launcher is filed under games"
[[ $(magick identify -format '%wx%h' "$icons/tilt-maze.png") == "256x256" ]] || fail "the game's icon.svg becomes a 256 pixel icon"
pass "games install launches ~/Games/<name>/index.html in the current theme, from a home with a space and a percent sign"

omarchy-games-install tilt-maze >/dev/null || fail "installing a game again replaces its own launcher"
printf '[Desktop Entry]\nName=Snake\nExec=snake-app\n' >"$applications/Snake.desktop"
make_game snake
refuses snake || fail "games install refuses to replace another app's launcher"
grep -qx 'Exec=snake-app' "$applications/Snake.desktop" || fail "the other app's launcher is left as it was"
omarchy-games-install snake "Snake Game" >/dev/null || fail "a game can take another title"
pass "games install replaces only its own launcher"

mkdir -p "$test_tmp/elsewhere"
printf 'x\n' >"$test_tmp/elsewhere/index.html"
ln -s "$test_tmp/elsewhere" "$HOME/Games/outside"
make_game linked
rm "$HOME/Games/linked/index.html"
ln -s "$test_tmp/elsewhere/index.html" "$HOME/Games/linked/index.html"
refuses outside || fail "games install refuses a game folder that leads out of ~/Games"
refuses linked || fail "games install refuses an index.html that is a symlink"
refuses ../outside || fail "games install refuses a name that is a path"
refuses Tilt-Maze || fail "games install refuses a name that is not lowercase"
refuses missing || fail "games install refuses a game that does not exist"
pass "games install only launches games inside ~/Games"

omarchy-webapp-remove "Tilt Maze" >/dev/null
[[ ! -e $desktop && ! -e $icons/tilt-maze.png ]] || fail "removing the web app deletes the game's launcher and icon"
[[ -f $HOME/Games/tilt-maze/index.html ]] || fail "removing the web app leaves the game itself"
pass "Remove > Web App takes a game out of the launcher and leaves its file"

# The games that come with Omarchy: installed from $OMARCHY_PATH/games, played from an
# offline copy with the vendored three.js built in.
omarchy-games-install minesweeper >/dev/null || fail "games install adds a game that comes with Omarchy"
grep -qx 'Comment=Minesweeper, a game that comes with Omarchy' "$applications/Minesweeper.desktop" || fail "the launcher says the game comes with Omarchy"
url=$(launched_argument "$applications/Minesweeper.desktop")
page=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1].removeprefix("file://").split("#")[0]))' "$url")
[[ $page == "$HOME/.cache/omarchy/games/minesweeper/index.html" ]] || fail "a shipped game plays from its offline copy" "$url"
grep -q 'data:text/javascript;base64' "$page" && ! grep -q 'cdn.jsdelivr.net' "$page" ||
  fail "the offline copy carries three.js itself instead of loading it from the CDN"
pass "a game that comes with Omarchy plays offline from the launcher"

make_game chess
OMARCHY_TEST_ARGV="$test_tmp/chess-argv" omarchy-games-launch chess
url=$(head -1 "$test_tmp/chess-argv")
[[ $url == *"/Games/chess/index.html#palette="* ]] || fail "a game in ~/Games wins over the one Omarchy ships by that name" "$url"
pass "a game in ~/Games wins over the one Omarchy ships by that name"

mkdir -p "$HOME/Games/loader"
cat >"$HOME/Games/loader/index.html" <<'HTML'
<script type="importmap">{ "imports": { "three": "https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.min.js" } }</script>
<script type="module">import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';</script>
HTML
OMARCHY_TEST_ARGV="$test_tmp/loader-argv" omarchy-games-launch loader
[[ $(head -1 "$test_tmp/loader-argv") == *"/Games/loader/index.html#palette="* ]] ||
  fail "a game using an addon Omarchy doesn't vendor plays from its own page" "$(head -1 "$test_tmp/loader-argv")"
[[ ! -e $HOME/.cache/omarchy/games/loader/index.html ]] || fail "no half-built offline copy is left behind"
pass "a game using an addon Omarchy doesn't vendor falls back to the CDN"

# An addon path that leaves the vendored addons must not pull a file from disk into the page.
printf 'secret-%s\n' "$RANDOM" >"$test_tmp/secret.js"
mkdir -p "$HOME/Games/escape"
cat >"$HOME/Games/escape/index.html" <<HTML
<script type="importmap">{ "imports": { "three": "https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.min.js" } }</script>
<script type="module">import 'three/addons/$test_tmp/secret.js';</script>
HTML
OMARCHY_TEST_ARGV="$test_tmp/escape-argv" omarchy-games-launch escape
[[ ! -e $HOME/.cache/omarchy/games/escape/index.html ]] || fail "an addon path outside the vendored addons gets no offline copy"
! grep -rqF "$(base64 -w0 "$test_tmp/secret.js")" "$HOME/.cache/omarchy/games" 2>/dev/null || fail "no file outside the vendored addons is built into a game"
pass "an addon path outside the vendored addons can't read a file into the page"
