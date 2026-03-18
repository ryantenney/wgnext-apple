---
title: Health Detection
description: How WGnext detects unhealthy tunnel connections.
---

WGnext uses traffic-based health monitoring to detect when a tunnel connection has failed. This approach is more reliable than handshake-based monitoring and works regardless of `persistent_keepalive` settings.

## Traffic-based monitoring

The `ConnectionHealthMonitor` polls the WireGuard backend every `healthCheckInterval` seconds (default: 10s), reading `tx_bytes` and `rx_bytes` from the UAPI interface.

### Detection logic

Each health check evaluates the traffic deltas since the last check:

| tx_bytes delta | rx_bytes delta | Verdict | Meaning |
|:-:|:-:|---|---|
| 0 | 0 | **Idle** | No traffic at all — tunnel is quiet, not broken |
| 0 | > 0 | **Healthy** | Receiving data (rare without sending, but healthy) |
| > 0 | > 0 | **Healthy** | Traffic flowing in both directions |
| > 0 | 0 | **Suspect** | Sending data but receiving nothing — start timer |

When the "suspect" state (transmitting but not receiving) persists for `trafficTimeout` seconds (default: 30s), the connection is declared **unhealthy** and failover triggers.

### Why traffic-based?

WGnext originally used handshake-based detection, monitoring `last_handshake_time` from the WireGuard UAPI. This was replaced because:

- It required `persistent_keepalive` to be enabled on all tunnels
- Users had to carefully coordinate `handshakeTimeout > 2 * persistentKeepAlive`
- Idle tunnels without keepalive showed stale handshakes even when the connection was fine
- The timeout was confusingly coupled to the keepalive interval

Traffic-based detection doesn't care about keepalive settings and only triggers when there's actual evidence of a broken connection.

:::tip
If your tunnels don't have `persistent_keepalive` configured, idle tunnels won't generate any traffic — so the health monitor can't detect a broken connection until something tries to send data. You can enable **Override Persistent Keepalive** in the failover group settings to ensure keepalive packets are always sent, making health detection reliable even during idle periods. See [Failover Configuration](/failover/configuration/) for details.
:::

## Anti-flap protection

To prevent rapid cycling between tunnels (which can happen when all tunnels are experiencing intermittent issues), WGnext includes several safety mechanisms:

| Protection | Default | Purpose |
|-----------|---------|---------|
| Minimum hold time | 60 seconds | Won't switch configs more frequently than once per minute |
| Max cycles before cooldown | 3 | After cycling through all configs 3 times... |
| Cooldown duration | 5 minutes | ...enter a 5-minute cooldown before trying again |

## Failback probing

When running on a fallback tunnel with `autoFailback` enabled, the monitor periodically probes the primary to check if it has recovered. The probe interval is configurable via `failbackProbeInterval` (default: 300 seconds).

### Background probes (default)

By default, failback probes run a **separate background WireGuard device** that tests the primary without disrupting your active connection. If the primary has recovered, the probe is promoted to become the active tunnel — preserving its existing WireGuard session with zero handshake delay.

See [Background Probes & Hot Spare](/failover/background-probes/) for the full details.

### Legacy probes

If background probes are disabled (or fail to start), the monitor falls back to the legacy approach:

1. Switch to primary config via `adapter.update()`
2. Wait up to 15 seconds for a WireGuard handshake
3. Check `last_handshake_time` — if recent, stay on primary
4. Otherwise, revert to the fallback config

:::caution
Legacy failback probes cause a brief (~15 second) traffic disruption while testing the primary. Background probes (enabled by default) avoid this disruption entirely.
:::

### Network-triggered probing

Network path changes (detected via `NWPathMonitor`) trigger an immediate failback probe when on a fallback tunnel. A network change (e.g., switching Wi-Fi networks) often means the primary may have recovered.

## Platform differences

### iOS
- `NWPathMonitor` detects network offline → triggers temporary shutdown of the WireGuard backend
- When the network recovers, the backend restarts and health monitoring resumes
- `wgDisableSomeRoamingForBrokenMobileSemantics` is called for iOS-specific roaming behavior
- Default MTU: 1280

### macOS
- Network changes trigger socket bumping (`wgBumpSockets`) instead of full backend restart
- Default MTU calculation uses `tunnelOverheadBytes = 80`
