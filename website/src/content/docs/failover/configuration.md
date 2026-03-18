---
title: Failover Configuration
description: Configuring failover settings in WGnext.
---

Failover groups have several configurable parameters that control health detection, failover timing, and failback behavior.

## Settings

### Traffic Timeout

- **Default**: 30 seconds
- **What it does**: How long a tunnel must be in the "sending but not receiving" state before it's declared unhealthy and failover triggers.
- **Tradeoff**: Lower values detect failures faster but increase the risk of false positives during brief network glitches. Higher values are more conservative but mean longer outages before failover.
- **Recommendation**: The default of 30 seconds works well for most scenarios. Combined with the 10-second health check interval, unhealthy connections are typically detected within ~40 seconds.

### Health Check Interval

- **Default**: 10 seconds
- **What it does**: How often the health monitor polls the WireGuard backend for traffic statistics.
- **Tradeoff**: More frequent checks detect issues faster but use slightly more CPU. Less frequent checks save resources but increase detection time.
- **Recommendation**: 10 seconds is a good balance. Going below 5 seconds provides diminishing returns.

### Auto Failback

- **Default**: Enabled
- **What it does**: When enabled, WGnext periodically probes the primary tunnel and switches back to it when it recovers.
- **When to disable**: If your fallback tunnel is equivalent in quality to the primary and you don't want the brief disruption of failback probes.

### Failback Probe Interval

- **Default**: 300 seconds (5 minutes)
- **What it does**: How often to probe the primary tunnel when currently running on a fallback.
- **Tradeoff**: More frequent probes mean faster recovery to the primary. With [background probes](/failover/background-probes/) enabled (the default), probes are non-disruptive, so shorter intervals have minimal downside. With legacy probes, each probe causes a ~15-second disruption.
- **Recommendation**: 5 minutes is reasonable for most use cases. With background probes enabled, you can safely reduce this to 60-120 seconds without impacting active traffic.

### Background Probes

- **Default**: Enabled
- **What it does**: Uses a separate lightweight WireGuard device for failback probing instead of swapping the active tunnel config. The probe runs entirely in the background with no impact on active traffic.
- **When to disable**: Only if you experience issues with the background probe approach (e.g., unusual network configurations that prevent binding a second UDP socket). Disabling falls back to the legacy swap-wait-check-revert approach.
- **Recommendation**: Leave enabled.

### Hot Spare

- **Default**: Disabled
- **What it does**: Maintains a continuously running background WireGuard device for the next failover target. When the active tunnel fails, the hot spare is promoted with its existing session intact — zero handshake delay.
- **When to enable**: When you need the fastest possible failover and can tolerate the minor resource overhead of a persistent background WireGuard session (~64 bytes of keepalive traffic every 25 seconds).
- **Tradeoff**: Slightly higher resource usage (one extra UDP socket, ~2-3 goroutines, minimal battery impact) in exchange for near-instantaneous failover.
- **Recommendation**: Enable for always-on VPN deployments where failover speed is critical. Leave disabled for casual use.

See [Background Probes & Hot Spare](/failover/background-probes/) for the full technical details.

### Override Persistent Keepalive

- **Default**: Disabled (no override)
- **What it does**: When enabled, overrides the `persistent_keepalive` setting on all peers in all tunnels within the failover group. The individual tunnel configurations are not modified — the override is applied at activation time when the tunnel runs in the context of the failover group.
- **Why use it**: Persistent keepalive generates periodic traffic that makes [health detection](/failover/health-detection/) more reliable. Without it, an idle tunnel shows no tx/rx activity, so the health monitor treats it as "idle" rather than "unhealthy" — even if the peer is actually unreachable. With keepalive enabled, the monitor sees outgoing keepalive packets with no response, triggering failover.
- **Tradeoff**: Keepalive packets prevent NAT/firewall timeouts and improve health detection, but they consume a small amount of bandwidth (~64 bytes per interval) and prevent the WireGuard session from going fully idle.
- **Recommendation**: Enable with the default 25-second interval if your tunnels don't already have persistent keepalive configured and you want reliable failover detection during idle periods.

## Editing settings

### When creating a group

Settings are configured in the **Failover Settings** section of the failover group editor. The editor shows numeric pickers for timeouts and intervals, and a toggle for auto failback.

### After creation

To change settings on an existing group:
1. Tap the failover group in the tunnel list
2. Tap **Edit**
3. Scroll to the **Failover Settings** section
4. Modify values and tap **Save**

Changes take effect immediately if the group is active — the extension receives the updated settings via IPC.

## Default values summary

| Setting | Default | Range |
|---------|---------|-------|
| Traffic Timeout | 30s | 10-120s |
| Health Check Interval | 10s | 5-60s |
| Auto Failback | Enabled | On/Off |
| Failback Probe Interval | 300s | 60-900s |
| Background Probes | Enabled | On/Off |
| Hot Spare | Disabled | On/Off |
| Override Persistent Keepalive | Disabled | On/Off + 1-65535s |

## Built-in protections

These values are not user-configurable and are designed to prevent pathological behavior:

| Protection | Value |
|-----------|-------|
| Minimum hold time | 60 seconds between any two switches |
| Max cycles before cooldown | 3 full cycles through all configs |
| Cooldown duration | 5 minutes of inactivity after max cycles |
