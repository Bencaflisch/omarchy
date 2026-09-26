# Proposal: an optional China ISO for easier Omarchy bootstrap

## Goal

Offer an optional China ISO with domestic package mirrors and Chinese input ready to use after installation.

The Great Firewall (GFW) can make access to official mirrors unreliable in China. Domestic mirrors would help users bootstrap Omarchy more reliably.

**This is a convenient starting point, not a restricted edition.** Anyone can use it, and users remain free to change or remove all regional settings after installation. It introduces no geographic restrictions, service restrictions, or lock-in.

## What it would include

### 1. USTC package mirrors

Keep the selected channel’s Omarchy mirror first and add USTC as a fallback. For stable:

```ini
# /etc/pacman.d/mirrorlist
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
```

Pacman tries servers in order; see [pacman.conf(5)](https://man.archlinux.org/man/pacman.conf.5.en#REPOSITORY_SECTIONS). USTC is a rolling mirror, not a matching stable/RC snapshot, so fallback compatibility needs validation.

Also append the ArchLinuxCN community repository:

```ini
# /etc/pacman.conf
[archlinuxcn]
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
```

Bundle and initialize its keyring through a verified trust-bootstrap process, keeping package signature verification enabled. The existing `[omarchy]` repository stays unchanged.

### 2. Preconfigured Chinese input

Bundle a Chinese input engine, its dependencies, and default configuration in the ISO so the installed system supports Chinese input on first login, without additional downloads or manual setup.

The engine and switching shortcut are open for discussion. Testing should cover actual typing, physical-key behavior, shortcut conflicts, and candidate windows in terminals and browsers.

## Build approach

- Add `--region cn`, independently of the existing stable, RC, edge, and dev options.
- Use lowercase **ISO 3166-1 alpha-2** country codes; reserve `global` for no country-specific customization.
- Keep regional additions separate from channel defaults: repository fragments, extra packages, and new-user configuration.
- Preserve offline installation and retain the chosen region across channel changes.
- Keep regional build caches separate so ordinary ISO builds remain unaffected.

Region selection would **not force a system language, timezone, or keyboard layout**. Users could change mirrors, remove ArchLinuxCN, replace the input method, or switch channels. Updates should respect user customization rather than repeatedly reapplying regional defaults.

## Related work

- [#7858 — A version customized for China](https://github.com/omacom/omarchy/discussions/7858)
- [#8697 — Simplified Chinese system language and stock Pinyin](https://github.com/omacom/omarchy/discussions/8697)
- [#11456 — Out-of-the-box Chinese input](https://github.com/omacom/omarchy/issues/11456)
- [#9695 — Setup > Region toggle](https://github.com/omacom/omarchy/pull/9695)
- [#10052 — Internationalization overview](https://github.com/omacom/omarchy/discussions/10052)

This proposal focuses on **installation and bootstrap**, not full UI translation. We should reuse applicable input-method work rather than create a competing setup path.

## Feedback welcome

Would this approach fit Omarchy? Feedback on the mirror policy, ArchLinuxCN compatibility with stable/RC, and input-method defaults would help shape the implementation.
