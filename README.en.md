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
- **Mac**: menu bar status, reply / approve / deny from notifications, Quick Look, drag files out, and an optional
  built-in manager that runs the daemon without the official desktop app (you can switch back at any time)
- **iPhone / iPad**: Live Activities and Dynamic Island, notifications with Approve / Deny / Reply — pushed by a
  plugin on *your own* machine with *your own* APNs key, no third-party server
- **Companion plugins (optional)**: usage limits, turn speed, next-input suggestions, titles

## Download

| Platform | How |
|---|---|
| **Mac** | Download `Paseo-Native-x.y.z.dmg` from [Releases](https://github.com/52216108/paseo-native/releases/latest) and drag "Paseo Native" into Applications. Signed and notarized by Apple. It installs as `Paseo Native.app` and does not replace the official `Paseo.app` |
| **iPhone / iPad** | No prebuilt package; build it with Xcode, see [iPhone / iPad](#iphone--ipad) below |

Requires macOS 26 / iOS 26 / iPadOS 26 and a Paseo daemon (bundled with the official desktop app; tested with Paseo v0.15).

## Connect a machine

1. On the computer running the daemon, run `paseo daemon pair` to get a QR code and a pairing link.
2. In Paseo Native, Add machine → Pairing link, paste it (or scan the QR code on iPhone / iPad).

The connection goes through the Paseo relay and is end-to-end encrypted. The pairing link is a key to that machine
and is stored only in the Keychain. On a trusted LAN you can also use a direct address.

## Companion plugins (optional)

<img src="docs/images/mac-plugins.png" width="520" alt="Companion plugins">

Plugins run on the **machine with the daemon** and work for every client of that machine. **All of them are
optional**; everything else works without them. The app offers them once when you first connect a machine (choose
"以后再说" / later to skip); manage them later in Settings → Machines → Plugins. They are open source, see the
[Paseo plugin registry](https://paseo.sh/plugins).

## Replacing the official desktop app (optional), and switching back

Settings → Machines → This Mac shows who runs the daemon. When it is the official app, "改由本 App 运行…"
(run it with this app) quits the official app, stops its daemon and starts one managed by Paseo Native on the same
`~/.paseo`, launched at login. It still uses the official `@getpaseo/cli`. **Machine ID, pairings, sessions and
plugins all live in `~/.paseo` and stay the same**, so phones and other computers don't need to pair again.

To switch back, "切回官方 App…" (switch back to the official app) on the same page stops Paseo Native's daemon,
removes its login item, points `~/.local/bin/paseo` back and opens the official app, which takes over. Don't run
both apps' daemons at the same time.

## iPhone / iPad

Apple doesn't allow installing iOS apps from outside the App Store, so build it yourself:

1. Xcode 26 and `brew install xcodegen`
2. ```sh
   git clone https://github.com/52216108/paseo-native.git && cd paseo-native
   cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your Team ID and bundle ID
   xcodegen generate && open Paseo.xcodeproj
   ```
3. Connect the device (enable Developer Mode on it the first time), pick it in Xcode, set the Run configuration to
   **Release** (Product → Scheme → Edit Scheme; Debug scrolls slowly) and run.

With a free Apple ID the app expires after 7 days and remote notifications are unavailable; a paid Apple Developer
account (USD 99/year) removes both limits.

## Dynamic Island and notifications (optional, paid developer account)

<p>
  <img src="docs/images/activity-expanded.png" width="380" alt="Dynamic Island">
  <img src="docs/images/activity-lock.png" width="380" alt="Lock screen">
</p>

While the app is in the foreground, the Live Activity updates with no setup. For updates and "finished / needs
approval" notifications while it is in the background:

1. Create an APNs key (.p8) in your Apple Developer account (Keys → Apple Push Notifications service, Topic Specific
   → your bundle ID; Sandbox for Xcode installs, Production for TestFlight). It must belong to the team that signs the app.
2. Install the 灵动岛推送 (Live Activity push) plugin on one of your machines.
3. On the iPhone: Settings → 通知 (Notifications) → 灵动岛推送 → 配置 APNs 密钥, enter Team ID and Key ID, pick the .p8 file.

The key is stored only on that machine (`~/.paseo/live-activity/`), which sends pushes to Apple directly.

## Building the Mac app

Same as steps 1–2 above, then run "My Mac" in Xcode. Unit tests: `cd PaseoKit && swift test`; command-line builds
need `-skipPackagePluginValidation` (SwiftTerm's build plugin).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attributions.
