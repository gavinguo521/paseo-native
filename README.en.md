# Paseo Native

An unofficial native client for [Paseo](https://paseo.sh) on Mac, iPhone and iPad, from one SwiftUI codebase.

> **Not affiliated with the Paseo project.** Like the official apps, it connects to the Paseo daemon on your own
> computer, and can be installed and used side by side with them. **The interface is in Simplified Chinese only.**

[中文说明](README.md)

<p align="center"><img src="docs/images/mac-session.png" width="820" alt="Mac"></p>

<p align="center">
  <img src="docs/images/iphone-home.png" width="200" alt="iPhone session list">
  <img src="docs/images/iphone-permission.png" width="200" alt="Approving a command on iPhone">
  <img src="docs/images/ipad-session.png" width="380" alt="iPad">
</p>

## Features

- **Native UI**: SwiftUI with the Liquid Glass design of macOS / iOS 26; long sessions scroll smoothly
- **On par with the official client**: multiple machines, sessions, timeline, permissions, terminals, files, diffs,
  Git and pull requests, schedules, command palette
- **Mac**: menu bar status, reply / approve / deny from notifications, Quick Look, drag files out, an optional
  built-in manager that runs the daemon without the official desktop app (switch back any time), update notifications
- **iPhone / iPad**: Live Activities and Dynamic Island, notifications with Approve / Deny / Reply — pushed by a
  plugin on *your own* machine with *your own* APNs key, no third-party server
- **Companion plugins (optional)**: usage limits, turn speed, next-input suggestions, titles

It is only a client: it doesn't include or modify the Paseo daemon, and your agents keep running on your computer
with the Claude Code / Codex accounts logged in there.

## Download

| Platform | How |
|---|---|
| **Mac** | Download `Paseo-Native-x.y.z.dmg` from [Releases](https://github.com/52216108/paseo-native/releases/latest) and drag "Paseo Native" into Applications. Signed and notarized by Apple. It installs as `Paseo Native.app` and does not replace the official `Paseo.app` |
| **iPhone / iPad** | No prebuilt package; build it with Xcode, see [iPhone / iPad](#iphone--ipad) |
| **Android** | Use the official app; both can connect to the same machine |

Requires macOS 26 / iOS 26 / iPadOS 26 and a computer running a Paseo daemon (bundled with the official desktop app;
Paseo Native can also install one). Tested with Paseo v0.15.

## Getting started

- **The official desktop app already runs on this Mac**: Add machine → 直连地址 (direct address) → `localhost:6767`.
- **No Paseo on this Mac yet**: Settings → Machines → This Mac → "在这台 Mac 上安装并运行 Paseo…" (install and run
  Paseo here). It downloads the official CLI (plus Node if needed, about 600 MB), starts it at login and adds the machine.
- **Another computer, or on iPhone / iPad**: run `paseo daemon pair` there, then Add machine → 配对链接 (pairing link)
  and paste it, or scan the QR code. Enter the daemon password if it has one.

Pairing links go through the Paseo relay and are end-to-end encrypted; a link is a key to that machine and is stored
only in the Keychain. Paseo Native and the official desktop, mobile and web apps can all be connected to the same
machine at once and see the same sessions.

## Companion plugins (optional)

<img src="docs/images/mac-plugins.png" width="520" alt="Companion plugins">

Plugins run on the **machine with the daemon** and work for every client of that machine. **All of them are
optional.** The app offers them once when you first connect a machine ("以后再说" skips them); manage them later in
Settings → Machines → Plugins.

| Plugin | What it does | Note |
|---|---|---|
| Usage reset | Claude / Codex usage and when each limit resets | Reads data Paseo already fetches |
| Turn speed | Tokens per second under each reply | Parses the CLI's local logs |
| Next input | Suggests your next message in the empty composer (Tab to accept) | Calls Claude (Haiku by default) or Codex once per turn, **uses a little of that account's quota** |
| Title style | Short Chinese titles for new sessions | One model call per new session |
| Board | Opens an [agent-taskboard](https://github.com/52216108/agent-taskboard) board | Only for agent-taskboard users |
| Live Activity push | Updates the Dynamic Island and sends notifications while the app is in the background | Needs a paid developer account, see below |

Paseo plugins run unsandboxed in the daemon; source: [paseo-plugins](https://github.com/52216108/paseo-plugins),
[title-style](https://github.com/52216108/title-style), or the [Paseo plugin registry](https://paseo.sh/plugins).

## Replacing the official desktop app (optional), and switching back

Settings → Machines → This Mac shows who runs the daemon. When it is the official app, "改由本 App 运行…" (run it
with this app) quits the official app, stops its daemon and starts one managed by Paseo Native on the same
`~/.paseo`, launched at login; the official app can then be uninstalled. Running sessions are interrupted. It still
uses the official `@getpaseo/cli` (in `~/Library/Application Support/Paseo Native`, linked from
`~/.local/bin/paseo`). **Machine ID, pairings, sessions and plugins all live in `~/.paseo` and stay the same**, so
phones and other computers don't need to pair again. Already uninstalled the official app? The page then says no
daemon is running: use "在这台 Mac 上安装并运行 Paseo…", which reuses the same `~/.paseo`.

To switch back, "切回官方 App…" on the same page stops Paseo Native's daemon, removes its login item, points
`~/.local/bin/paseo` back and opens the official app, which takes over (reinstall it from [paseo.sh](https://paseo.sh)
first if you removed it). Don't let both apps run a daemon at the same time.

## iPhone / iPad

Apple doesn't allow installing iOS apps from outside the App Store, so build it yourself:

1. Xcode 26 (signed in with your Apple ID) and `brew install xcodegen`
2. ```sh
   git clone https://github.com/52216108/paseo-native.git && cd paseo-native
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   Set `DEVELOPMENT_TEAM` and `PASEO_BUNDLE_ID` in it. **With a free Apple ID**, also uncomment
   `PASEO_IOS_ENTITLEMENTS = App/Paseo-iOS-Free.entitlements` (free teams can't sign the push capability).
3. `xcodegen generate && open Paseo.xcodeproj`; trust the SwiftTerm build plugin when Xcode asks.
4. Connect the device (enable Settings → Privacy & Security → Developer Mode the first time), pick it in Xcode, set
   the Run configuration to **Release** (Product → Scheme → Edit Scheme; Debug scrolls slowly) and run.
5. With a free Apple ID, trust yourself in Settings → General → VPN & Device Management on the device.

With a free Apple ID the app expires after 7 days, at most 3 self-built apps can be installed, and background
notifications are unavailable (the Live Activity still updates while the app is open). A paid Apple Developer account
(USD 99/year) removes these limits and allows TestFlight.

## Dynamic Island and notifications (optional, paid developer account)

<p>
  <img src="docs/images/activity-expanded.png" width="380" alt="Dynamic Island">
  <img src="docs/images/activity-lock.png" width="380" alt="Lock screen">
</p>

Running and waiting sessions from all machines are combined into one Live Activity (Dynamic Island and lock screen on
iPhone, lock screen on iPad); tap a row to open the session. In the foreground it updates with no setup. For updates
and "finished / failed / needs approval" notifications in the background:

1. Create an APNs key (.p8) in your Apple Developer account (Keys → Apple Push Notifications service; Sandbox for
   Xcode installs, Production for TestFlight; Topic Specific → your bundle ID). It must belong to the team that signs
   the app. The .p8 can be downloaded only once.
2. Install the Live Activity push (灵动岛推送) plugin on **one** machine that stays online.
3. On the iPhone: Settings → 通知 → 灵动岛推送 → 配置 APNs 密钥, enter Team ID and Key ID, pick the .p8 file and environment.

The key is stored only on that machine (`~/.paseo/live-activity/`), which sends pushes to Apple directly.

## Updating

- **Mac**: from 1.0.7 the app checks GitHub once a day and offers new versions (download / skip / later; never
  installs on its own); you can also check from the app menu or Settings → About, and turn automatic checks off
  there. Install by dragging the new version into Applications; settings and machines are kept.
- **Daemon**: updated by the official app, or with "更新到 x.y.z" in Settings → Machines → This Mac when Paseo Native runs it.
- **iPhone / iPad**: `git pull`, `xcodegen generate`, run again from Xcode.

## Privacy and network

No analytics and no servers of our own. The app connects only to your daemons (through the Paseo relay, end-to-end
encrypted, or a direct address), `api.github.com` for the daily update check (Mac, can be turned off), jsDelivr to
render Mermaid diagrams, and nodejs.org / npm only when installing or updating the daemon. Pairing links and passwords
stay in the Keychain. The Mac app is not sandboxed so it can show local files referenced in replies and manage the
local daemon.

## Uninstalling (Mac)

If Paseo Native runs the daemon, switch back to the official app or stop it first; then move the app to the Trash.
To clean up fully, also remove `~/Library/Application Support/Paseo Native` and
`~/Library/LaunchAgents/sh.paseo.native.daemon.plist`. **Don't delete `~/.paseo`** — it is Paseo's own data.

## Feedback

There is also a WeChat group (in Chinese), see the [Chinese README](README.md#反馈与交流). Please open an [issue](https://github.com/52216108/paseo-native/issues); attach the file from Settings → About →
导出诊断信息 (export diagnostics) — it contains no conversation content, and pairing links and passwords are redacted.

## Building the Mac app

Same as steps 1–3 above, then run "My Mac" in Xcode. Unit tests: `cd PaseoKit && swift test`; command-line builds
need `-skipPackagePluginValidation` (SwiftTerm's build plugin). Forks can set `PASEO_RELEASES_REPO` in
`Config/Local.xcconfig` to check their own releases.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attributions. "Paseo" is the name of the Paseo project; this
is an unofficial community client.
