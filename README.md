# Paseo Native

An unofficial native client for [Paseo](https://paseo.sh) on macOS, iOS and iPadOS, written in SwiftUI.

> **Not affiliated with the Paseo project.** Paseo Native connects to your own Paseo daemon, the same way the
> official apps do, and can be used side by side with them. The interface is in Simplified Chinese only.

[中文说明](README.zh-CN.md)

## Features

- Native SwiftUI on Mac, iPhone and iPad from one codebase, with the Liquid Glass design of macOS / iOS 26
- Multiple machines, sessions, timeline, permissions, terminals, files, diffs, Git and pull requests, command palette
- **Mac**: menu bar status, reply / approve from notifications, Quick Look, drag files out, and an optional
  built-in manager that runs the Paseo daemon without the official desktop app (you can switch back at any time)
- **iPhone / iPad**: Live Activities and Dynamic Island, remote notifications with Approve / Deny / Reply —
  pushed by a daemon plugin with *your own* APNs key, no third-party server
- One-click install of companion daemon plugins (usage limits, turn speed, next-input suggestions, titles)

## Requirements

- macOS 26 / iOS 26 / iPadOS 26
- A Paseo daemon (tested with Paseo v0.15) reachable through the Paseo relay or directly

## Install

**Mac**: download the signed and notarized `.dmg` from [Releases](../../releases). It installs as
`Paseo Native.app` and does not replace the official `Paseo.app`.

**iPhone / iPad**: build it yourself with Xcode (see below). With a free Apple ID the app expires after 7 days
and remote notifications are unavailable; a paid Apple Developer account removes both limits.

## Build

```sh
brew install xcodegen
git clone https://github.com/52216108/paseo-native.git && cd paseo-native
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your Team ID and bundle ID
xcodegen generate
open Paseo.xcodeproj
```

Use the Release configuration for daily use (Product → Scheme → Edit Scheme → Run); Debug builds scroll slowly.
Unit tests: `cd PaseoKit && swift test`.

## Notifications and Live Activities (optional, iOS)

1. In your Apple Developer account, create an APNs key (.p8) — it must belong to the same team that signs the app.
2. Install the `live-activity` plugin on one of your machines (Settings → Machines → Plugins → Companion plugins).
3. In the app: Settings → Notifications → Live Activity push → configure the APNs key.

The key is stored only on that machine (`~/.paseo/live-activity/`).

## Running the daemon on a Mac

Settings → Machines → This Mac. If the official desktop app runs the daemon, you can hand it over to Paseo Native
(it then starts at login, the official app is no longer needed). Everything lives in `~/.paseo`, so the machine ID,
pairings, sessions and plugins stay the same. "Switch back to the official app" reverses it. Don't run both apps'
daemons at the same time.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attributions.
