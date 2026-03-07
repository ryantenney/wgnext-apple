---
title: Build & Run
description: Building WGnext from source.
---

## Clone and configure

```bash
git clone https://github.com/rtenney/wgnext
cd wgnext
```

Create and edit the developer configuration:

```bash
cp Sources/WireGuardApp/Config/Developer.xcconfig.template \
   Sources/WireGuardApp/Config/Developer.xcconfig
```

Edit `Developer.xcconfig` and set your values:
- `DEVELOPMENT_TEAM` — your Apple Developer Team ID
- `APP_ID_IOS` — your iOS app bundle identifier
- `APP_ID_MACOS` — your macOS app bundle identifier

## Install dependencies

```bash
brew install swiftlint go xcodegen
```

## Generate Xcode project

```bash
xcodegen generate
open WireGuard.xcodeproj
```

:::caution
`project.yml` is the source of truth for all Xcode targets and build settings. Never edit `WireGuard.xcodeproj` directly — regenerate it with `xcodegen generate` after modifying `project.yml`.
:::

## Build targets

| Target | Platform | Description |
|--------|----------|-------------|
| WireGuard (iOS) | iOS 15+ | Main iOS app |
| WireGuard (macOS) | macOS 12+ | Main macOS app |
| WireGuardNetworkExtension | Both | Network Extension (packet tunnel provider) |
| WireGuardWidget | iOS | Status widget |

Select the appropriate target and device in Xcode, then build and run.

## Simulator vs. device

### Simulator
- The Network Extension does not run in the simulator
- The app uses `MockTunnels` to simulate tunnel behavior
- Good for UI development and testing

### Physical device
- Requires proper provisioning (see [Prerequisites](/development/prerequisites/))
- Network Extension runs as a separate process
- Required for testing actual VPN functionality and failover

## Debug failover testing

To build with failover debug controls:

```bash
fastlane ios device_failover
```

This adds the `FAILOVER_TESTING` compilation flag, which enables:
- **Force Failover** button in the failover group detail view
- **Force Failback** button to immediately switch back to primary

All debug code is `#if FAILOVER_TESTING` gated and excluded from release builds.
