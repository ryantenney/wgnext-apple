---
title: On-Demand Activation
description: Automatic VPN activation based on network conditions.
---

On-demand activation lets iOS and macOS automatically activate your VPN (or failover group) based on network conditions — without opening the app.

## How it works

On-demand rules are configured per-tunnel or per-failover group. The operating system evaluates these rules whenever the network changes and activates or deactivates the VPN accordingly.

## Configuration

When editing a tunnel or failover group, scroll to the **On-Demand Activation** section.

### Interface types

- **Wi-Fi**: Activate when connected to a Wi-Fi network
- **Cellular**: Activate when on a cellular connection (iOS only)
- **Ethernet**: Activate when connected via Ethernet (macOS only)

### SSID filtering (Wi-Fi)

When Wi-Fi is enabled, you can optionally restrict activation to specific networks:

- **Only these SSIDs**: Activate only when connected to listed networks
- **Except these SSIDs**: Activate on any Wi-Fi except listed networks

## On-demand with failover groups

On-demand rules work natively with failover groups because each group is backed by a standard `NETunnelProviderManager` — the same system type used for regular VPN configurations. The OS sees the group as a regular VPN and applies on-demand rules normally.

This means you can set up a failover group that:
1. Activates automatically when you join your home Wi-Fi
2. Monitors tunnel health and fails over if the primary goes down
3. Fails back when the primary recovers
4. Deactivates when you leave your home network

All without touching the app.

## Limitations

- On-demand rules are evaluated by the OS, not by WGnext. The available rule types are determined by Apple's `NEOnDemandRule` API.
- Only one VPN configuration can use on-demand at a time. Enabling on-demand on a new tunnel/group disables it on the previous one.
- SSID-based rules require location permission on iOS.
