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
- **Tradeoff**: More frequent probes mean faster recovery to the primary but cause more brief disruptions (~15 seconds each). Less frequent probes reduce disruptions but delay recovery.
- **Recommendation**: 5 minutes is reasonable for most use cases. If your primary connection is critical and outages are typically short, consider reducing to 120 seconds.

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

## Built-in protections

These values are not user-configurable and are designed to prevent pathological behavior:

| Protection | Value |
|-----------|-------|
| Minimum hold time | 60 seconds between any two switches |
| Max cycles before cooldown | 3 full cycles through all configs |
| Cooldown duration | 5 minutes of inactivity after max cycles |
