---
title: Troubleshooting Failover
description: Common failover issues and how to resolve them.
---

## Failover isn't triggering

### Tunnel is idle
Failover only triggers when the device is actively sending data but not receiving any responses. If the tunnel is idle (no apps using the VPN), health monitoring correctly treats this as "idle" — not unhealthy.

**Fix**: Ensure there's active traffic through the tunnel. Browsing the web or running a speed test while the primary is down should trigger failover within ~40 seconds.

### Traffic timeout too high
If you've increased the traffic timeout significantly, it takes longer to detect failures.

**Fix**: Check your failover settings. The default 30-second timeout combined with 10-second check intervals means detection in ~40 seconds.

### Anti-flap cooldown active
If the monitor has cycled through all configurations 3 times, it enters a 5-minute cooldown period to prevent rapid cycling.

**Fix**: Wait for the cooldown to expire. If all your tunnels are genuinely down, there's nothing to fail over to — the cooldown prevents wasting resources on constant switching.

## Failback isn't happening

### Auto failback disabled
Check that auto failback is enabled in the failover group settings.

### Primary still unhealthy
Failback probes test the primary by briefly switching to it and checking for a handshake. If the primary still can't complete a handshake within 15 seconds, it's considered still down and the monitor stays on the fallback.

### Probe interval
The default probe interval is 5 minutes. After a failover event, it may take up to 5 minutes for the first failback probe.

## False positives

### Brief network glitches cause failover
The 30-second traffic timeout provides tolerance for brief glitches. If you're seeing false positives:

**Fix**: Increase the traffic timeout to 60 seconds in the failover settings.

### Failover on Wi-Fi → Cellular transition
On iOS, switching from Wi-Fi to cellular causes a brief network interruption. The 30-second timeout should absorb this, but if it doesn't:

**Fix**: The minimum hold time (60 seconds) prevents rapid cycling. If failover triggers but the original tunnel recovers, failback will switch back within the probe interval.

## Status monitoring

### Viewing live status
Tap on a failover group in the tunnel list to see the detail view with live stats:
- **Active tunnel**: Which configuration is currently in use
- **Data Sent/Received**: Total bytes transferred on the active config
- **Last Handshake**: Time since the last successful WireGuard handshake
- **Failover Count**: Number of times the active config has changed
- **Health Status**: Only shown when unhealthy — displays as "Unhealthy (tx without rx for Xs)"

The detail view polls the extension every 2 seconds for updated stats.

## Common scenarios

| Scenario | Expected Behavior |
|----------|-------------------|
| Primary server reboots (2 min downtime) | Failover within ~40s, failback within 5 min of recovery |
| All servers down | Cycles through all configs, enters 5-min cooldown after 3 cycles |
| Flaky Wi-Fi (intermittent drops <30s) | No failover — within timeout tolerance |
| ISP outage (extended downtime) | Failover to fallback, stays there until primary probed successfully |
| Device sleeps/wakes | Health monitoring pauses during sleep, resumes on wake |
| App killed while on fallback | Extension keeps running. State queried via IPC when app reopens |

## Debug testing

For development and testing, build with the `FAILOVER_TESTING` flag to enable debug controls:

- **Force Failover**: Immediately switches to the next configuration
- **Force Failback**: Immediately switches back to the primary

Build with: `fastlane ios device_failover`
