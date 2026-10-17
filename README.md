# Purifier Bar

A macOS menu bar app for controlling supported MIoT air purifiers directly over local Wi-Fi (miIO/MIoT protocol), without the vendor cloud and without the vendor's phone app.

- Panel: power, Auto/Sleep/Manual modes, PM2.5 with a live glow, fan level, filter life, screen brightness, sound, button lock.
- Automations: a time schedule and a PM2.5 threshold (boost when the air gets worse, return to the previous mode when it clears). They run only while the Mac is awake.
- Notifications: low filter life and device faults.
- The only network traffic is UDP port 54321 on your local network. The device token stays in macOS Keychain.

Purifier Bar is an independent project and is not affiliated with or endorsed by Xiaomi.

## Requirements

- macOS 15 or later.
- Xcode 26 or later (Swift 6.2+), to build from source.
- The Mac and the purifier on the same local network.
- The device token (32 hexadecimal characters), see "Adding your device".

## Building

```bash
git clone <this repository>
cd PurifierBar
./Tools/check.sh          # build + tests
./Tools/build-app.sh      # creates build/PurifierBar.app
```

Copy `build/PurifierBar.app` to `/Applications` and open it. `build-app.sh` signs the app with the certificate named in `PURIFIER_SIGN_IDENTITY`; without one it signs ad-hoc, and macOS then asks again for Keychain access after every rebuild.

`./Tools/release.sh <version>` (for example `1.0`) runs the tests, tags the commit, builds and zips the app and publishes it as a GitHub release of the `origin` repository (needs the GitHub CLI).

On first launch macOS asks for permission to access devices on the local network - allow it, otherwise the app cannot reach the purifier.

### Gatekeeper

An app you build yourself opens normally. A prebuilt copy downloaded from the internet is not notarized, so macOS blocks it on first launch. To open it anyway: try to open the app once, then go to System Settings > Privacy & Security and click Open Anyway next to the Purifier Bar message. Only do this for a copy you trust.

## Adding your device

1. Obtain the device's token with [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) (MIT). Follow its README for account login and extraction. This is a separate tool; Purifier Bar itself never contacts the cloud.
2. Open Purifier Bar's settings with the gear button in the panel and paste the token into the Token field, then click Save token. The field clears, the status says Token saved, and the app reconnects.
3. Without an IP the device is found by broadcast on each network interface, and the app remembers its address. If it is not found (for example, broadcast is blocked on your network), enter the device's local IP under Device and click Save IP.

The token is stored only in macOS Keychain (service `PurifierBar`, account `purifier`). It is never displayed after saving, written to logs or stored in settings files. An invalid format is rejected before any write.

The app first requests token-authenticated model information and selects the property map before reading state. For an unverified model, the panel warns that controls may not work correctly and offers Try Anyway; consent is saved for that exact model. If model information is unavailable, the app uses the cpa4 map.

Terminal alternative: use the interactive security tool so the token does not appear in process arguments. Run `/usr/bin/security -i`, then enter this command at its prompt, replacing `<32-character-hex-token>` with your token:

```text
add-generic-password -U -a purifier -s PurifierBar -w <32-character-hex-token>
```

Press Control-D to exit. Avoid putting the actual token in shell commands, files, screenshots, or chat. If the app is already open, save the token in its settings or restart it to reconnect immediately.

## Supported models

Only `xiaomi.airp.cpa4` has been tested on a real device. The other models use the latest released public MIoT specifications (checked 2026-10-16); hardware reports are welcome.

| Layout | Family | Models (specification links) |
|---|---|---|
| cpa4 | 4 Compact / 4 Lite | [xiaomi.airp.cpa4](https://home.miot-spec.com/spec/xiaomi.airp.cpa4), [xiaomi.airp.cpa4m](https://home.miot-spec.com/spec/xiaomi.airp.cpa4m), [zhimi.airp.cpa4](https://home.miot-spec.com/spec/zhimi.airp.cpa4), [zhimi.airp.rmb1](https://home.miot-spec.com/spec/zhimi.airp.rmb1) |
| rma1 | 4 Lite | [zhimi.airpurifier.rma1](https://home.miot-spec.com/spec/zhimi.airpurifier.rma1) |
| rma2 | 4 Lite | [zhimi.airp.rma2](https://home.miot-spec.com/spec/zhimi.airp.rma2) |
| mb5 | 4 / 4 Pro | [zhimi.airp.mb5](https://home.miot-spec.com/spec/zhimi.airp.mb5), [zhimi.airp.mb5a](https://home.miot-spec.com/spec/zhimi.airp.mb5a), [zhimi.airp.mp4](https://home.miot-spec.com/spec/zhimi.airp.mp4), [zhimi.airp.mp4a](https://home.miot-spec.com/spec/zhimi.airp.mp4a), [zhimi.airp.va2](https://home.miot-spec.com/spec/zhimi.airp.va2), [zhimi.airp.va2a](https://home.miot-spec.com/spec/zhimi.airp.va2a), [zhimi.airp.vb4](https://home.miot-spec.com/spec/zhimi.airp.vb4) |
| mb3 | 3 / 3H | [zhimi.airpurifier.ma4](https://home.miot-spec.com/spec/zhimi.airpurifier.ma4), [zhimi.airpurifier.mb3](https://home.miot-spec.com/spec/zhimi.airpurifier.mb3), [zhimi.airp.mb3a](https://home.miot-spec.com/spec/zhimi.airp.mb3a) |
| proH | Pro H | [zhimi.airpurifier.va1](https://home.miot-spec.com/spec/zhimi.airpurifier.va1), [zhimi.airpurifier.vb2](https://home.miot-spec.com/spec/zhimi.airpurifier.vb2) |
| za1 | Smartmi Air Purifier | [zhimi.airpurifier.za1](https://home.miot-spec.com/spec/zhimi.airpurifier.za1) |

Layouts include model-specific screen brightness, fault codes and favorite-level limits. Models without remaining filter days show only filter percentage. Modes outside Auto/Sleep/Favorite remain unselected in the panel. Unlisted models require Try Anyway and use the cpa4 fallback; this does not establish compatibility.

`purifier-cli status` reports the model and selected layout; `watch` also selects by model. The existing `get` property dump and `set <siid.piid>` diagnostics are unchanged.

## cpa4 property map (siid.piid)

This table describes the cpa4 layout.

| What | siid.piid | Type / value |
|---|---|---|
| Enabled | 2.1 | bool, rw |
| Fault | 2.2 | 0 none, 2 motor stuck, 3 sensor lost |
| Mode | 2.4 | 0 Auto, 1 Sleep, 2 Favorite (= Manual in the app) |
| PM2.5 | 3.4 | 0-600 ug/m3, r |
| Filter life | 4.1 | 0-100 %, r |
| Filter: used / remaining | 4.3 / 4.4 | hours / days, r |
| Sound | 6.1 | bool, rw |
| Button lock | 8.1 | bool, rw |
| Screen brightness | 13.2 | 0 off, 1 dim, 2 bright, rw |
| Motor speed | 9.1 | 0-2500 rpm, r |
| Favorite level | 9.11 | 0-14, rw |

Actions: 2.1 toggle, 4.1 reset-filter-life, 9.1 toggle-mode. Do not touch: 9.10 country-code, 9.12 filter-used-time-dbg.

## Diagnostics

`purifier-cli` (built by `swift build`) talks to the device directly: `status`, `get`, `set <siid.piid> <value>`, `watch`. Without `--host IP` it finds the device by broadcast. It reads the token from the same Keychain item.

## License

MIT, see `LICENSE`. The miIO protocol core is adapted from [19s94/lightbar-direct](https://github.com/19s94/lightbar-direct) (MIT, Copyright (c) 2026 19s94); its license is in `THIRD_PARTY_NOTICES`.
