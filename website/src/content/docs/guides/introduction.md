---
title: What is WGnext?
description: An overview of WGnext, an actively maintained WireGuard VPN client for iOS and macOS.
---

WGnext is a fork of the [official WireGuard client for Apple platforms](https://git.zx2c4.com/wireguard-apple/). It does everything the upstream app does — import tunnels from files or QR codes, create configs from scratch, on-demand activation rules — plus one headline feature: **failover groups**.

## Why a fork?

The official WireGuard iOS app hasn't been updated since early 2023. WGnext is under active development with regular updates, bug fixes, and new features.

## What you get

- **Everything from the official app**: Import `.conf` files, scan QR codes, create tunnels manually, on-demand activation, iOS and macOS support
- **Failover groups**: Assign tunnels to an ordered group with automatic switchover when the primary goes down
- **Zero-downtime switching**: The VPN stays "connected" while swapping tunnel configurations — apps don't see a disconnect
- **Traffic-based health detection**: Monitors actual traffic patterns to detect unhealthy connections — no false positives on idle tunnels
- **Automatic failback**: Probes the primary tunnel periodically and switches back when it recovers
- **Anti-flap protection**: Prevents rapid cycling between tunnels with configurable hold times and cooldown periods

## Who is this for?

WGnext is useful if you:

- **Run dual internet connections** with WireGuard servers on each — automatic failover between them
- **Self-host WireGuard endpoints** across multiple servers or cloud providers for redundancy
- **Travel frequently** and need your VPN to survive flaky connections without babysitting
- **Want always-on VPN** with resilience — if one server goes down, traffic routes through another automatically
- **Prefer an actively maintained client** — the official app works but is no longer receiving updates

## Compatibility

WGnext works with any standard WireGuard server. If your existing tunnel configs work with the official WireGuard app, they'll work with WGnext.

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 15.0           |
| macOS    | 12.0           |

## Open source

WGnext is licensed under [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html). The original upstream code remains available under the MIT license. Contributors who get a substantive PR merged earn a free license in perpetuity.
