<p align="center"><img src="icon/AppIcon.iconset/icon_256x256.png" width="128" alt="DiskLoader"></p>

<h1 align="center">DiskLoader</h1>
<p align="center">Download files and folders directly from cloud drive links.</p>

---

Paste a link — see what's inside — pick what you need — download. No browser, no accounts, no extra windows.

- whole folders or single files, structure preserved
- large files download over multiple connections
- pause and resume from the same spot, even after a restart
- queue several links at once
- download history
- updates itself
- English and Russian interface

## Download

**macOS 14+** · Apple Silicon & Intel → [latest release](../../releases/latest)

1. Open `DiskLoader-<version>.dmg` and drag DiskLoader to Applications.
2. First launch: **System Settings → Privacy & Security → Open Anyway** (the app isn't signed with an Apple certificate).

Windows — coming later.

## Build

```
./build.sh            # build and install to /Applications
./build.sh release    # + dist/*.dmg and *.zip for a release
```

The DMG is built with [dmgbuild](https://github.com/dmgbuild/dmgbuild): `pip install dmgbuild` into `~/.venvs/dmgbuild`.

---

<p align="center"><sub>made by <a href="https://t.me/cetrovix">cetrovix</a></sub></p>
