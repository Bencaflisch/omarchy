#!/bin/bash

# The idle service decides whether activity cancels a pending lock by how many
# screensaver windows are up, so the count has to match the windows that exist:
# one open before the shell started included, and none once they have closed.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_compositor "idle screensaver window count test"
require_command quickshell
require_command foot

stage=$(mktemp -d)
foot_pid=""
cleanup() {
  if [[ -n $foot_pid ]]; then
    kill "$foot_pid" 2>/dev/null || true
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT

ln -s "$ROOT/shell/Commons" "$stage/Commons"
ln -s "$ROOT/shell/plugins/services/idle" "$stage/idle"
cp "$SHELL_TEST_DIR/fixtures/idle-screensaver-windows/shell.qml" "$stage/shell.qml"

foot --app-id=org.omarchy.screensaver -e sleep 30 >/dev/null 2>&1 &
foot_pid=$!
for _ in {1..50}; do
  hyprctl clients -j | jq -e 'any(.[]; .class == "org.omarchy.screensaver")' >/dev/null && break
  sleep 0.1
done

output=$(HOME="$stage" OMARCHY_PATH="$ROOT" SCREENSAVER_PID=$foot_pid timeout 30 quickshell -p "$stage" --no-color 2>&1) || fail "idle screensaver fixture exits cleanly" "$output"
[[ $output == *"RESULT pass"* ]] || fail "idle counts the screensaver windows that exist" "$output"
if rg -q 'RESULT fail|ReferenceError|TypeError|Error:|Unable to assign|Binding loop' <<<"$output"; then
  fail "idle screensaver fixture has no QML errors" "$output"
fi
pass "idle counts screensavers open before it started, opened later, and closed"
