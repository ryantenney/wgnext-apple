---
title: Installation
description: How to install WGnext on iOS and macOS.
---

## App Store

WGnext is available on the App Store for both iOS and macOS.

<!-- TODO: Add App Store badges/links when published -->

## Building from Source

If you prefer to build from source, see the [Build & Run](/development/build/) guide for complete instructions.

## Migrating from the official WireGuard app

WGnext uses the same tunnel configuration format as the official WireGuard app. Your existing `.conf` files and QR codes work without modification.

To migrate your tunnels:

1. **Export** your tunnel configurations from the official WireGuard app (Settings → Export tunnels to zip file)
2. **Install** WGnext
3. **Import** your exported `.zip` file into WGnext

Your tunnels will appear exactly as they did in the official app. From there, you can optionally create failover groups to take advantage of automatic tunnel switching.

:::note
WGnext and the official WireGuard app can coexist on the same device. You don't need to uninstall one to use the other. However, only one VPN tunnel can be active at a time — this is an iOS/macOS system constraint.
:::
