# Finding and preparing games: sourced by omarchy-games-install and omarchy-games-launch.

# Sets GAME_PAGE to the game's index.html and GAME_ORIGIN to "yours" (~/Games/<name>,
# which wins) or "omarchy" (shipped in $OMARCHY_PATH/games), or fails with why.
find_game() {
  local name=$1 games folder

  if [[ ! $name =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    echo "Game name must be lowercase letters, digits and dashes: $name" >&2
    return 1
  fi

  if [[ -e $HOME/Games/$name ]]; then
    # ~/Games may itself be a symlink, but the game's folder must resolve inside it.
    games=$(realpath -e "$HOME/Games")
    folder=$(realpath -e "$HOME/Games/$name")
    if [[ $folder != "$games/$name" ]]; then
      echo "~/Games/$name points outside ~/Games" >&2
      return 1
    fi
    GAME_ORIGIN=yours
  elif [[ -f $OMARCHY_PATH/games/$name/index.html ]]; then
    folder="$OMARCHY_PATH/games/$name"
    GAME_ORIGIN=omarchy
  else
    echo "No game at ~/Games/$name" >&2
    return 1
  fi

  GAME_PAGE="$folder/index.html"
  if [[ ! -f $GAME_PAGE || -L $GAME_PAGE ]]; then
    echo "No ~/Games/$name/index.html" >&2
    return 1
  fi
}

# Where the playable copy of a game is written.
game_cache_page() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/games/$1/index.html"
}

file_url() {
  printf 'file://%s\n' "$(jq -rn --arg path "$1" '$path | split("/") | map(@uri) | join("/")')"
}

# Writes a copy of the page that runs offline: its importmap's three.js and addons swapped
# for the copies Omarchy vendors, as data: URLs, since a page opened from a file can't
# import its neighbours. Fails, leaving nothing, when the page uses a version or an addon
# that isn't vendored; the page itself then still runs from the CDN.
build_offline_game() {
  local page=$1 out=$2 tmp
  mkdir -p "$(dirname "$out")"
  tmp=$(mktemp "$out.XXXXXX")     # two launches of one game must not share or remove each other's copy
  python3 - "$page" "$tmp" "$OMARCHY_PATH/games/vendor" <<'PY' && chmod 644 "$tmp" && mv "$tmp" "$out"
import base64, json, os, re, sys
page, out, vendor = sys.argv[1:]
html = open(page, encoding="utf-8").read()
found = re.search(r'<script type="importmap">(.*?)</script>', html, re.S)
version = re.search(r"three@([0-9.]+)/build/three\.module\.min\.js", found.group(1) if found else "")
if not version:
    sys.exit(1)
root = os.path.join(vendor, "three-" + version.group(1))
if not os.path.isdir(root):
    sys.exit(1)

def data(path, source=None):
    source = source if source is not None else open(path, "rb").read()
    return "data:text/javascript;base64," + base64.b64encode(source).decode()

module = open(os.path.join(root, "three.module.min.js"), "rb").read().replace(b'"./three.core.min.js"', b'"three/core"')
imports = {"three": data(None, module), "three/core": data(os.path.join(root, "three.core.min.js"))}
addons = os.path.realpath(os.path.join(root, "examples", "jsm"))
for addon in sorted(set(re.findall(r"""['"]three/addons/([\w./-]+\.js)['"]""", html))):
    # Only a file inside the vendored addons, never one a crafted path reaches elsewhere on disk;
    # and only a self-contained one, since a data: module can't resolve a relative import.
    path = os.path.realpath(os.path.join(addons, addon))
    if os.path.commonpath([addons, path]) != addons or not os.path.isfile(path) or re.search(rb"""from\s*['"]\.""", open(path, "rb").read()):
        sys.exit(1)
    imports["three/addons/" + addon] = data(path)
importmap = '<script type="importmap">' + json.dumps({"imports": imports}) + "</script>"
open(out, "w", encoding="utf-8").write(html[:found.start()] + importmap + html[found.end():])
PY
  local status=$?
  rm -f "$tmp"
  return $status
}
