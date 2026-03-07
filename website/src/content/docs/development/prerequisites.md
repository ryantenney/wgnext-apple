---
title: Prerequisites
description: What you need to build WGnext from source.
---

## Required tools

| Tool | Version | Installation |
|------|---------|-------------|
| Xcode | Latest stable | [Mac App Store](https://apps.apple.com/app/xcode/id497799835) |
| Go | 1.19+ | `brew install go` |
| SwiftLint | Latest | `brew install swiftlint` |
| XcodeGen | Latest | `brew install xcodegen` |

## Apple Developer account

To run on a physical device, you need an Apple Developer account (free or paid) and must configure your development team ID.

## Provisioning

The Network Extension target requires specific entitlements that must be provisioned through your Apple Developer account:
- **Network Extension** capability (packet tunnel provider)
- **App Groups** capability (for shared data between app and extension)

:::note
You can build and run in the iOS Simulator without provisioning, but the Network Extension won't load. The app uses `MockTunnels` in the simulator for development.
:::
