echo "Clear SoundWire routes the retired N1x UCM profiles left in the saved mixer state"

# Omarchy's own MT8901 UCM profiles, replaced by NVIDIA's in 3a209895e4, routed
# PDI2 to DP3 (ASUS ProArt P14) and PDI7/PDI8 to codec ports (ProArt P14 and
# Dell XPS 16). alsactl saved those routes and restores them every boot, and
# NVIDIA's profiles only set the routes they use, so a host port ends up fed by
# two PDIs. The MT8901 SoundWire driver then rejects the 2-channel speaker and
# microphone streams with EINVAL, PipeWire drops the HiFi profile, and the
# internal speakers and microphones vanish. No current profile routes PDI7 or
# PDI8, or PDI2 to DP3, so those values can only be leftovers.
if ! omarchy-hw-aarch64-n1x; then
  exit 0
fi

card=mt8901soundwire

if ! amixer -c "$card" info >/dev/null 2>&1; then
  exit 0
fi

route() {
  amixer -c "$card" sget "$1" | sed -n "s/^  Item0: '\(.*\)'$/\1/p"
}

stale=()

if [[ $(route "PDI2 Demux") == "DP3" ]]; then
  stale+=("PDI2 Demux")
fi

for control in "PDI7 Mux" "PDI8 Mux"; do
  if [[ $(route "$control") != "None" ]]; then
    stale+=("$control")
  fi
done

if (( ${#stale[@]} == 0 )); then
  exit 0
fi

for control in "${stale[@]}"; do
  amixer -q -c "$card" cset name="$control" None
done

# Save the cleared routes so the next boot does not restore the stale ones.
sudo alsactl store "$card"

# PipeWire only probes the card's UCM profiles when WirePlumber opens it.
systemctl --user try-restart wireplumber.service 2>/dev/null || true
