<p align="center"><img src="icon/AppIcon.iconset/icon_256x256.png" width="128" alt="MegaLoader"></p>

<h1 align="center">MegaLoader</h1>
<p align="center">Download anything from one link — cloud drives, YouTube, TikTok, Instagram, Spotify, SoundCloud and more.</p>

---

Paste a link — see what's inside — pick what you need — download. No browser, no accounts, no extra windows.

**Cloud drives:** Google Drive · Yandex Disk · Dropbox · WeTransfer · Mail.ru Cloud · OneDrive · pCloud
**Video:** YouTube · TikTok · Instagram · VK · Vimeo · X (Twitter) · Twitch · Rutube
**Music:** Spotify · SoundCloud · YouTube Music · Bandcamp · Mixcloud
**Streams:** Twitch stream recordings (VODs) — in full or as a time-range clip, in source quality
<sub>…and 1000+ other sites. Public links only. Dropbox folders download as a single archive. Spotify is copy-protected, so tracks are matched by name on YouTube Music.</sub>

- whole folders, playlists and albums — or pick single files
- video quality: only what the video really has, up to 4K, or audio only (MP3); no re-encoding: up to 1080p in H.264, 2K/4K in AV1 (MP4 + AAC) — opens in DaVinci Resolve and Premiere Pro
- large files download over multiple connections
- pause and resume from the same spot, even after a restart
- queue several links at once
- history split into drives, video, music and streams
- checks free disk space before long downloads
- updates itself, video engine too
- English and Russian interface

## Download

**macOS 14+** · Apple Silicon & Intel → [latest release](../../releases/latest)

1. Open `MegaLoader-<version>.dmg` and drag MegaLoader to Applications.
2. First launch: **System Settings → Privacy & Security → Open Anyway** (the app isn't signed with an Apple certificate).

The video engine ([yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg, ~100 MB) is downloaded on first use.

Windows — coming later.

## Build

```
./build.sh            # build and install to /Applications
./build.sh release    # + dist/*.dmg and *.zip for a release
```

The DMG is built with [dmgbuild](https://github.com/dmgbuild/dmgbuild): `pip install dmgbuild` into `~/.venvs/dmgbuild`.

---

<p align="center"><sub>made by <a href="https://t.me/cetrovix">cetrovix</a></sub></p>
