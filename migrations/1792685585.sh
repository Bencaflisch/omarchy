echo "Add the games that come with Omarchy to the app launcher"

# New users get them from omarchy-provision-user. A game whose title is already taken
# by another launcher is skipped rather than stopping the update.
for game in "$OMARCHY_PATH"/games/*/index.html; do
  name=$(basename "$(dirname "$game")")
  omarchy-games-install "$name" >/dev/null || echo "Skipping $name"
done
