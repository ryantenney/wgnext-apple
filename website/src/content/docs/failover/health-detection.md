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

## Anti-flap protection

To prevent rapid cycling between tunnels (which can happen when all tunnels are experiencing intermittent issues), WGnext includes several safety mechanisms:

| Protection | Default | Purpose |
|-----------|---------|---------|
| Minimum hold time | 60 seconds | Won't switch configs more frequently than once per minute |
| Max cycles before cooldown | 3 | After cycling through all configs 3 times... |
| Cooldown duration | 5 minutes | ...enter a 5-minute cooldown before trying again |

## Failback probing

When running on a fallback tunnel with `autoFailback` enabled, the monitor periodically probes the primary:

1. Switch to primary config via `adapter.update()`
2. Wait up to 15 seconds for a WireGuard handshake
3. Check `last_handshake_time` — if recent, stay on primary
4. Otherwise, revert to the fallback config

The probe interval is configurable via `failbackProbeInterval` (default: 300 seconds).

:::caution
Failback probes cause a brief (~15 second) traffic disruption while testing the primary. This is an intentional tradeoff — the faster primary connection may have recovered.
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
