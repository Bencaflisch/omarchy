# A regional install points this user's developer tools at the region's
# registries; the installer wrote the marker before finalization.
region=
# read fails on a marker without a final newline, after reading it.
if [[ -r /etc/omarchy/region ]]; then
  read -r region </etc/omarchy/region || true
fi
if [[ $region == "cn" ]]; then
  "$OMARCHY_PATH/bin/omarchy-region-user" cn
fi
