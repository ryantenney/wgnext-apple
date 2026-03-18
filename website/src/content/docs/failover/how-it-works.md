---
title: How Failover Works
description: Technical deep dive into WGnext's failover architecture.
---

This page explains the technical architecture behind WGnext's failover system.

## Architecture overview

```
┌─────────────────────────────────────────────────┐
│                    App Process                   │
│                                                  │
│  TunnelsManager                                  │
│    ├─ tunnels: [TunnelContainer]       (regular) │
│    └─ failoverGroupTunnels: [TunnelContainer]    │
│                                                  │
│  UI polls failover state via IPC every 2-5s      │
└──────────────────────┬───────────────────────────┘
                       │ IPC (sendProviderMessage)
                       ▼
┌─────────────────────────────────────────────────┐
│             Network Extension Process            │
│                                                  │
│  PacketTunnelProvider                            │
│    ├─ failoverConfigs: [TunnelConfiguration]     │
│    ├─ activeConfigIndex: Int                     │
│    └─ ConnectionHealthMonitor                    │
│         ├─ Polls tx_bytes/rx_bytes every 10s     │
│         ├─ Detects unhealthy connections         │
│         ├─ Calls adapter.update() to switch      │
│         ├─ Probes primary for failback           │
│         └─ Manages hot spare probes              │
└─────────────────────────────────────────────────┘
```

## Key discovery: in-place configuration swap

The foundation of WGnext's failover is `WireGuardAdapter.update()`, which hot-swaps the entire tunnel configuration on a running tunnel — including interface private key, all peers, endpoints, and network settings.

The swap process:

1. Set `packetTunnelProvider.reasserting = true`
2. Call `setTunnelNetworkSettings()` with new settings
3. Call `wgSetConfig()` with new UAPI config (`replace_peers=true`)
4. Set `packetTunnelProvider.reasserting = false`

From the OS perspective, the VPN stays "connected" — it briefly enters "reasserting" state. No tunnel teardown, no connectivity gap visible to apps.

With [hot spare mode](/failover/background-probes/) enabled, failover can also use `promoteProbe()` instead of `update()`. This promotes a pre-established background WireGuard session, preserving the existing Noise handshake and eliminating the re-handshake RTT entirely.

## Why this runs in the Network Extension

The failover engine runs entirely inside the Network Extension process, not the app:

- The extension runs as a separate process that stays alive as long as the VPN is active
- The app can be killed, suspended, or not running at all
- On-demand activation works natively — the OS starts the extension without the app
- There's no dependency on app-layer timers or background execution

The app communicates with the extension via IPC (`NETunnelProviderSession.sendProviderMessage()`) to query state and display status.

## Failover groups as NETunnelProviderManagers

A failover group is stored as a standard `NETunnelProviderManager` with extra data in its `providerConfiguration` dictionary:

| Key | Type | Purpose |
|-----|------|---------|
| `FailoverGroupId` | `String` (UUID) | Identifies this as a failover group |
| `FailoverConfigs` | `[String]` | Array of wg-quick config strings |
| `FailoverConfigNames` | `[String]` | Display names for each config |
| `FailoverSettings` | `Data` | JSON-encoded failover settings |

This approach means:
- Failover groups appear in system VPN preferences alongside regular tunnels
- The `NETunnelProviderManager` lifecycle works identically
- On-demand activation works natively
- The single-active-tunnel constraint is enforced by the OS

## Alternatives considered

### App-level tunnel switching

Deactivate one `NETunnelProviderManager`, activate another. **Rejected**: 1-5 second downtime per switch. Requires the app to be running.

### Per-peer endpoint failover

Add fallback endpoints to each peer, switch endpoints only. **Rejected**: Only works when servers share keys. Doesn't help when servers have completely different configurations.

### DNS-based failover

Health-checked DNS where servers share a hostname. **Rejected**: Slow (DNS TTL), no client-side priority control, requires server infrastructure.
