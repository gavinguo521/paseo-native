# Apple Watch companion

PaseoWatch is a watchOS 11+ companion target in the existing XcodeGen project. It requires the paired iPhone's Paseo app (iOS 18+) and uses WatchConnectivity to reach the phone's existing daemon connections. It does not connect directly to a daemon over Wi-Fi or cellular.

## First version

- Recent sessions, their current status and recent messages; host filtering. Schedule-created run sessions are excluded from this list, while their results remain available under schedules; existing chats targeted by heartbeats remain visible. Within a session, Reply sits directly below the status and messages appear newest-first.
- Read-only schedule lists, details and recent execution results.
- System dictation/text input, a transcript preview, saved drafts, and explicit Send.
- Compact message previews with original message times; generated question replies show the user's answers.
- Question forms with readable prompts, single/multiple choice, system input for custom answers, and explicit submission. Multiple questions are shown one at a time.
- Permission review with the daemon's actions. Unsupported forms or content exceeding the complete watch preview remain on the phone.
- Existing iPhone notifications forwarded to the watch, with navigation to the corresponding session. Notification delivery follows the user's system settings and the existing iPhone push setup.
- Cached content and the time of the last successful refresh. The visible page refreshes every 20 seconds while active; background context delivery is opportunistic.

watchOS 26+ uses native Liquid Glass button styles. Older systems use solid controls and cards; both share the same functionality. Reply previews match the dictation button's rounded shape, material and minimum height, and expand to fit multiline text. Conversation messages remain on solid backgrounds for readability.

## Build and test

1. Configure `Config/Local.xcconfig` as described in the main README, then run `xcodegen generate`.
2. Build/install the `Paseo` scheme on an iPhone. Its iOS app embeds the associated `PaseoWatch` app; macOS does not embed it.
3. Pair an Apple Watch with that iPhone and enable Developer Mode on both devices. If the switch is missing on the watch, select it as an Xcode run destination or open Xcode's device manager first, then reopen the watch's Settings → Privacy & Security.
4. Select the `PaseoWatch` scheme and the paired watch as the run destination. Use the same signing team as the iPhone app. Xcode installs and launches the watch app.
5. Open Paseo on the phone and connect a host. Test sessions, schedules, dictation, reply receipts, permission resolution, notification navigation, and phone lock/unlock. Also verify loss/recovery of phone connectivity and that selecting one host isolates other hosts' requests and errors.

Enable Dictation in the watch's system settings before testing voice input. The system input screen can initially show handwriting or a keyboard; select its microphone to dictate. Paseo uses this system input, then previews the transcript before an explicit Send.

Paired simulators can help check layout and navigation; use physical devices to verify dictation, notification forwarding and background phone wake-up. Testing the watchOS 26 appearance requires a matching OS environment; an older watch cannot validate its rendering. No particular device or simulator choice is imposed on contributors.

Protocol and retry tests run on the Mac:

```sh
swift test --package-path PaseoKit --filter PaseoWatchBridgeTests
```

During v1 development, physical testing with watchOS 11.5 and iOS 18.7.7 confirmed session refresh/opening while the phone is locked, dictation and reply delivery, newest-first messages, and yes/no question selection and submission. Multi-question forms, multi-select, custom answers, generic permission actions, schedule details, notification routing, and watchOS 26 appearance still need broader physical coverage. Automated tests cover question parsing, protocol compatibility and action retry behavior. These results describe tested configurations, not a restriction on contributors' test devices.

Integration validation on 2026-11-06: all 60 PaseoKit tests passed, including regressions for retaining a complete session page when an equal-timestamp preview arrives and for retaining a rejected receipt across retries while allowing a new edited message. Release builds passed for iPhone with its embedded watch app and for macOS. Chinese and English session-list, session-detail, and question screens were launched and visually checked on the watchOS 27.2 simulator. The README screenshots use sample data in an isolated screenshot build; that fixture is not included in the production app. These simulator checks do not validate real WatchConnectivity delivery, dictation, or notification routing, and no fresh physical-device test was performed for this integration.

## Implementation

- `PaseoWatchBridge`: Foundation-only Codable messages and an action receipt ledger. The watch links this product, not the daemon/terminal client.
- `WatchCompanion`: iOS WCSession delegate, host-scoped reads and explicit actions. It starts before the first scene so background launches can receive messages.
- `WatchClient`: watch cache, per-host incremental refresh, drafts and request/receipt handling.

WatchConnectivity completion closures are explicitly `@Sendable`, then hop to `MainActor` before updating UI state. These callbacks run on framework queues; inheriting main-actor isolation causes Swift 6 runtime traps on physical watches. The reply screen is a navigation destination, and its dictation entry uses SwiftUI's `TextFieldLink`; watchOS chooses the last-used input method, including dictation. A transcript is saved before returning from system input, and the draft is loaded only once per reply-screen lifetime so reappearing cannot overwrite new text.

Foreground requests have bounded timeouts and fit within WatchConnectivity's message limit. Reads preserve the phone's current navigation, focus and subscriptions. Selecting a host only requests that host's data; results from different hosts become visible independently.

The watch attempts live delivery after session activation even when reachability has not yet caught up with the phone waking. Transient delivery failures get one read retry. The phone probes its daemon socket before serving a request, coalesces concurrent connection recovery, and retries reads after a transport loss. Replies and approvals are not automatically replayed. A single local `watch.transportStatus` diagnostic records only the latest transport event, time, error code or app lifecycle state; it contains no conversation content.

Mutations use a stable operation ID. The phone writes the operation to its ledger before dispatch, coalesces duplicate requests and persists the result. Unconfirmed actions are checked rather than silently repeated after a restart. Replies also have a stable daemon message ID. Permission handling fetches the current request and checks its ID, displayed-content revision and selected action; a stale screen cannot approve a replacement request. Queued actions expire after three minutes. The watch never silently queues an approval for later delivery.

Question answers use the same `updatedInput.answers` format as the phone: keys are question headers, and values are option labels or custom text. Choosing “No” submits that answer; it does not deny the permission request. The phone validates answers against the current complete form, and pending receipts retain the original answers across retries. Question previews are bounded to 6 KB, six questions and twelve options per question; unsupported forms show a readable phone handoff instead of raw JSON.

The phone must remain reachable for new data and actions. watchOS/iOS background execution is finite; cached data remains available when the phone cannot respond, and uncertain action outcomes stay visible until checked. Pairing credentials remain exclusively in the iPhone Keychain.
