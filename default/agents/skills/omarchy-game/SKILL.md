---
name: omarchy-game
description: >
  Make a game for the Omarchy desktop: one HTML file using three.js, saved in
  ~/Games/<name>/, played in its own window from the app launcher. Use when
  asked to make, build, or write a game, an arcade game, a 3D game, a browser
  game, or a toy to play. Triggers: new game, make me a game, three.js, WebGL
  game, arcade, snake, asteroids, breakout, platformer, runner, maze, puzzle
  game.
---

# Making an Omarchy Game

A game here is one file, `~/Games/<name>/index.html`: three.js from a pinned CDN, everything else written in the file — shapes built from three.js geometry, sound synthesized with WebAudio, text in HTML over the canvas. It opens in its own window from the app launcher, is played from the keyboard, and keeps its best score.

Every game starts from `template.html` beside this file. It is a complete, working game (dodge the falling blocks) with the parts every game needs already done: title screen, pause, game over, restart, help, sound, saved best score, a fixed-step loop, and the hooks `check` uses to play it. You replace the game inside it, not the frame around it.

Below, `SKILL_DIR` is the directory this SKILL.md is in, which also holds `template.html` and `check`. Use the path you read this file from (such as `~/.agents/skills/omarchy-game`), not a guess.

## 1. Settle the game

If the user hasn't said what game they want, ask. Then decide, in one sentence each, before writing code:

- **Goal**: what the player is trying to do.
- **Controls**: which keys, and what each does. Arrow keys and WASD both, Space for the main action.
- **Losing**: what ends the round.
- **Score or winning**: what goes up, and whether the round can be won (a maze, a level) or only survived (a runner, asteroids).
- **Getting harder**: what changes over time so it stays interesting.

Keep it small enough to finish: one mechanic done well beats three done badly. Pick a short lowercase name of letters, digits and dashes (`snake`, `tilt-maze`).

## 2. Start from the template

```bash
mkdir -p ~/Games/<name>
cp "$SKILL_DIR/template.html" ~/Games/<name>/index.html
omarchy-theme-color --all
```

If `~/Games/<name>` already holds a game, ask before replacing it.

Read the whole template once before changing it. Then edit that copy in place, section by section — never write the file from scratch, and never rewrite the frame. Work in `~/Games/<name>/index.html` itself, not a copy elsewhere:

1. **SETTINGS**: set `NAME` to the game's name, and fill `PALETTE` from `omarchy-theme-color --all` (same keys: `mode`, `background`, `foreground`, `accent`, `muted`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `orange`). The game takes the look of the theme it was made in. Themes can be nearly monochrome or light: tell things apart by brightness and size as well as hue, and check the screenshots.
2. **THE GAME**: replace everything in that section with your game, keeping its five pieces: `build()` once for everything reused, `reset()` to start a round, `update(dt)` for every rule, `note(name)` when something worth testing happens, `endRound(won)` when the round ends. Set `score` as the game goes.
3. **The screens** in the HTML: the `<title>`, the title screen's name, one line saying the goal, and the controls; the help table. Keep the element ids.
4. **CHECK**: the key presses that play your game for 5–10 seconds after it starts, and the `note()` names that must happen while they do. It must exercise the main mechanic: for breakout, keys that move the paddle under the ball and `expect: ['brick']`; for a maze, moves that reach a wall and `expect: ['bump']`; for a shooter, firing at something and `expect: ['hit']`.
5. **ACTIONS** if the game needs more keys than move, action, pause, mute and help.

Leave the frame alone: the input, sound, screens, loop and `window.omarchyGame` below `EVERYTHING BELOW IS THE FRAME` are what make pause, restart and `check` work.

## 3. Check it, then look at it

```bash
"$SKILL_DIR/check" ~/Games/<name>/index.html
```

`check` opens the game headless, starts a round, pauses and resumes it, plays your `CHECK.play`, ends the round and restarts it. It fails on any page error, a round that won't start, a simulation that doesn't move, a pause that doesn't stop it, or a `CHECK.expect` event that never happened. Fix what it reports and run it again until it says PASSED. Never weaken `CHECK` to make it pass: if the mechanic doesn't happen, the game is broken.

Then look at `check-title.png`, `check-play.png` and `check-over.png` beside the game, every time, with your harness's tool for viewing an image (`view_image` in Codex, Read in Claude Code). Reading the file names in the output is not looking. A pass only proves the game runs; only the pictures show whether it is any good. Ask of each:

- Is the player obvious, and is everything the player needs on screen and not cut off at the edges?
- Is it readable, with things told apart, in the theme's colours?
- Does it look like the game you set out to make, not grey boxes on black?

Fix what's wrong and check again.

## 4. Put it in the launcher

```bash
omarchy-games-install <name> ["Title"]
```

This adds the game to the app launcher (Super + Space) as a web app, with an icon cut from `check-play.png` (or `icon.png` beside the game, if you made one). Run it again after renaming the title; the game file itself needs no reinstall after edits. Tell the user the game's name in the launcher, where the file is, the controls, and that it is removed under Remove > Web App (which leaves the file in `~/Games`).

## Making it good

- **Feel**: the player responds the moment a key goes down. Movement eases rather than snapping (`THREE.MathUtils.damp`). Every hit, pickup and death has a sound and something visible: a flash, a shake (`shake = 0.4`), a burst of particles, a squash.
- **Fairness**: the first ten seconds are easy and it gets harder steadily. A loss is the player's mistake, never something they couldn't see coming: hazards appear far enough away to react, and no single key press ends the round by surprise (a snake ignores a turn straight back into itself; a ball starts on the paddle and leaves when the player launches it).
- **Clarity**: one player, big enough to find at a glance and the most vivid thing on screen, never a dot. The score is always visible. The camera shows the whole play area at 16:9 and 16:10.
- **Polish**: the title screen says the goal and the controls in two lines. Game over says the score and whether it was a new best.

## three.js traps

The template pins three.js 0.180. Much of what you remember is for older versions:

- Import only `three` and, if needed, `three/addons/...` through the importmap. Never `examples/js/`, `THREE.Geometry`, `THREE.Face3`, `THREE.Math` (it's `THREE.MathUtils`), `*BufferGeometry` names (it's `BoxGeometry`), `renderer.outputEncoding` (it's `outputColorSpace`), or `physicallyCorrectLights`.
- Lights use physical units. The template's hemisphere and sun light a scene; keep them. A `PointLight` or `SpotLight` needs an intensity in the tens to hundreds to be seen at a few units away, or `decay: 0`.
- `MeshStandardMaterial` is dark without light; `MeshBasicMaterial` ignores light (good for glowing things and particles).
- No files besides the one: no `TextureLoader`, `GLTFLoader`, fonts or images from paths, since a page opened from a file can't load its neighbours. Build shapes from geometry, draw textures on a `<canvas>` with `THREE.CanvasTexture`, and put text in the HTML.
- Collisions are your own arithmetic in `update()`: distances, or boxes compared on each axis, all in world coordinates. If you parent meshes inside a group, compare `getWorldPosition()`, not `position`. Fast things move less than their own size per step or they pass through walls; the 1/120 s step helps.
- Make geometries and materials once in `build()` and share them. Removing a mesh from the scene is enough at the end of a round; never create a material every frame.
- Hundreds of the same thing (bullets, stars, particles) go in one `THREE.InstancedMesh` or `THREE.Points`.
- The game camera is placed and aimed by your code. Not `OrbitControls`.
- `requestAnimationFrame` and `setAnimationLoop` are already running in the template. Don't start another loop, and don't add event listeners in `reset()`.
