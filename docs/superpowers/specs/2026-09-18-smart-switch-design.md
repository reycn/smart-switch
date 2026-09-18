# SmartSwitch — design

Predictive app switcher for macOS. Press ⌘` and it jumps to the app you most likely want next, chosen by TypeSafe's Jev model from your recent switching history. No preview UI; it behaves like a one-shot ⌘Tab.

Built autonomously from the brief; decisions below are stated assumptions, not user-confirmed.

## Scope

- **In:** application switching on ⌘` (keycode 50 + ⌘), menu bar app, settings window, Jev prediction with 1 s timeout and last-used fallback, dev-mode notification on fallback, signed build installed to /Applications.
- **Out (later):** tab switching on ⌃`. The Jev request currently contains only app candidates; tabs will be added as more `choice` options when tab tracking exists.

## Architecture

```
┌──────────────── Swift (app/) ────────────────┐   ┌──── Rust (core/) ────┐
│ MenuBarExtra + Settings (SwiftUI)            │   │ History (ring of 200 │
│ NSWorkspace.didActivateApplication → record ─┼──▶│   activation events, │
│ CGEventTap ⌘` ──▶ Switcher.trigger ──────────┼──▶│   JSON on disk)      │
│   ◀── outcome JSON ── activate(bundle id) ◀──┼───│ predict(): Jev POST, │
│ UNUserNotification (dev mode, fallback only) │   │   1 s timeout,       │
└──────────────────────────────────────────────┘   │   fallback last-used │
                                                   └──────────────────────┘
```

Rust is a `staticlib` with a 4-function C ABI (`core/ffi/include/ss_core.h`, SwiftPM target `SSCore`): `ss_init(path)`, `ss_record(id, name, source)`, `ss_predict(api_key, timeout_ms, running_json) → json`, `ss_free`. Swift owns UI, permissions, and activation; Rust owns history and the decision. The Swift side is a SwiftPM executable (`Package.swift`) so it can depend on [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow), which provides the guided Accessibility flow (opens the right pane, floats a drag-to-authorize panel, shows Granted/Grant live). On first launch without Accessibility the app opens Settings instead of showing the bare system alert.

## Data flow on ⌘`

1. Event tap consumes the key (so macOS's own "next window" doesn't fire) and calls `trigger()` on main.
2. Swift snapshots currently running regular apps and calls `ss_predict` on a background queue.
3. Rust builds candidates = last 10 distinct apps in history, excluding the frontmost, intersected with running apps.
   - 0 candidates → `{"error":"no candidates"}`; 1 candidate → returned directly, no API call.
4. Rust POSTs to `https://api.typesafe.ai/v1/systemone`:
   - `state`: `{now, foreground_app, recent_switches:[{app, switched_at, stayed_seconds}] (last 30)}`
   - `questions.next_app`: `choice`, criteria keyed by app name → "last used Xm ago; N activations in the last hour; typical stay Ys".
5. Answer `choice` is mapped back to a bundle id. Any failure (missing key, HTTP error, timeout ≥ 1 s, unknown choice) → most recently used candidate, with `via:"last_used"` and `error`.
6. Swift activates the app. If `via == last_used` and Developer mode is on, it posts a notification naming the reason. Everything is logged to `os_log` subsystem `dev.rongxin.smartswitch`.

Re-entrancy: presses while a prediction is in flight are dropped.

### Activation sources

Every recorded activation carries a `source`: `cmd_tab` (the event tap saw ⌘Tab within the previous 3 s), `smart` (SmartSwitch activated it), or `other` (click, Dock, launch). The request's `state.recent_manual_cmd_tab_switches` lists the last 10 `cmd_tab` events as `{at, from, to}` so Jev can weight deliberate user switches over everything else. SmartSwitch's own switches are never counted as manual.

### Latency budget

Cold connect+TLS to the API costs ~0.4 s and Jev itself ~0.3 s, so a cold request often misses the 1 s budget. Rust keeps one pooled connection warm with an unauthenticated `GET /v1/models` every 30 s while the user has been active in the last 10 min (server keep-alive measured ≥ 45 s). Warm predictions land in ~0.3 s. The 1 s deadline is enforced with a helper thread + `recv_timeout`, independent of ureq's own timeout.

### Menu

The menu bar menu shows the most recent decision ("→ ChatGPT · Jev 99% · 371 ms"), with **Last Request** (state lines, manual ⌘Tab switches, candidate criteria) and **Last Response** (model, confidence, probability per option, or the error and fallback) as submenus, plus **Copy Request & Response** which puts the full outcome JSON on the pasteboard.

## Settings (single window, grouped form)

- TypeSafe API key (secure field, stored in the login Keychain, never in defaults).
- Shortcuts, read-only: ⌘` switch app, ⌃` switch tab (coming soon).
- Accessibility status with a button to the System Settings pane; live-updates once granted.
- Launch at login (SMAppService), Developer mode (fallback notifications + `smartswitch.trigger` distributed notification for testing without the hotkey).

## Build / sign / install

`./build.sh` → `cargo build --release`, `swiftc` the app, assemble `build/SmartSwitch.app`, `codesign` with the first "Apple Development" identity (override with `SIGN_IDENTITY`), copy to `/Applications`, relaunch. Signing with a stable identity keeps the Accessibility grant across rebuilds.

## Testing

- `cargo test` covers history dedupe/cap, candidate ordering and filtering, last-used, request shaping.
- `cargo run --example predict` hits the live API with `TYPESAFE_API_KEY`.
- App: launch, switch apps from the shell with `open -a`, confirm `history.json` grows; fire the dev trigger to exercise predict→activate without Accessibility. Hotkey path needs the user to grant Accessibility once.
