# SmartSwitch

English | [简体中文](README.zh-CN.md)

Reimagined window switcher for macOS using frontier artificial intelligence. It just knows which window you wanna use.

Predicted by TypeSafe's [Jev](https://docs.typesafe.ai) model from your recent switching history, in realtime.

Tab switching on **⌃`** is planned, not implemented yet.

## How it works

- Every app activation is recorded (last 200), tagged as a ⌘Tab switch, a SmartSwitch switch, or other.
- On ⌘`, the 10 most recently used running apps become options in one Jev `choice` question. The request includes your recent switches, how long you stayed in each app, the time of day, and your last 10 manual ⌘Tab switches.
- The most probable app is activated. Any failure or a 1 s timeout falls back to the last-used app.

## Build, sign, install

```bash
./build.sh
```

Builds the Rust core (`core/`), builds the Swift app with SwiftPM (`Package.swift`, pulls [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow)), renders the icon, signs with your first "Apple Development" identity (`SIGN_IDENTITY=… ./build.sh` to choose), installs to `/Applications/SmartSwitch.app`, and launches it. `./build.sh build` stops after signing.

## First run

1. Settings opens on first launch. Click **Grant** next to Accessibility: System Settings opens on the right pane with a floating panel you can drag the app from (needed to intercept ⌘`).
2. Open **Settings…** from the menu bar icon and paste your TypeSafe API key (stored in the login keychain).
3. Switch between a few apps, then press ⌘`.

The menu shows the last decision, with **Last Request** / **Last Response** submenus. Hover a row for the exact text sent to or received from Jev; click a row to copy it. **Developer mode** (Settings → General) notifies you whenever the fallback is taken.

## Layout

- `core/src/lib.rs` — history, Jev request/response, fallback, keep-alive. `cargo test`; `TYPESAFE_API_KEY=… cargo run --example predict` hits the live API.
- `core/ffi/include/ss_core.h` — the 4-function C ABI used by Swift (SwiftPM target `SSCore`).
- `app/` — SwiftUI menu bar + Settings, `CGEventTap` hotkey, keychain, notifications, PermissionFlow-guided Accessibility setup.
- `tools/make-icon.swift` — renders `AppIcon.icns` from `icon.png`.

## Author

Rongxin · [rongxin@u.nus.edu](mailto:rongxin@u.nus.edu) · [github.com/reycn/smart-switch](https://github.com/reycn/smart-switch)

## License

[GNU Affero General Public License v3.0](LICENSE)
