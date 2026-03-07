---
title: Failover Groups
description: Automatic tunnel failover and failback in WGnext.
---

Failover groups are WGnext's headline feature. They let you define an ordered list of WireGuard tunnel configurations with automatic failover when the active tunnel becomes unreachable.

## Overview

A failover group contains two or more WireGuard tunnels in priority order:
- The **primary** tunnel is used by default
- **Fallback** tunnels are activated automatically if the primary (or current active) becomes unhealthy
- When the primary recovers, WGnext can **automatically fail back**

The entire failover engine runs inside the Network Extension process, so it works even when the app is killed or suspended.

## Creating a failover group

1. Tap **+** → **Create Failover Group**
2. Name the group
3. Add tunnels — the first tunnel added is the primary, subsequent tunnels are fallbacks
4. Drag to reorder if needed
5. Configure [failover settings](/failover/configuration/) or keep the defaults
6. Optionally configure [on-demand activation](/features/on-demand/) rules
7. Tap **Save**

## Using failover groups

Failover groups appear in the tunnel list alongside regular tunnels. Activate and deactivate them the same way — with the toggle switch.

When active, the detail view shows:
- Which tunnel configuration is currently active
- Data sent and received
- Last handshake time
- Failover count and last failover time (if any switches have occurred)
- Current health status

## Use cases

### Dual ISP redundancy

You have two home internet connections (e.g., fiber + LTE backup), each running its own WireGuard server with different keys and endpoints. Create a failover group with your fiber tunnel as primary and LTE as fallback.

### Multi-server redundancy

You self-host WireGuard on multiple cloud providers. If one provider has an outage, failover moves traffic to another server automatically.

### Travel resilience

You're on airport Wi-Fi with a flaky connection. Your VPN drops frequently. With a failover group pointing to servers in different regions, WGnext finds a working path without your intervention.

### Always-on VPN

You run a VPN 24/7 with on-demand activation. Adding a failover group means your always-on VPN survives server maintenance windows and outages.

## How it differs from endpoint failover

Some WireGuard implementations let you specify multiple endpoints for the same peer. This only works when the same server is reachable at multiple IP addresses — it doesn't apply when servers have different keys.

WGnext's failover groups support **completely different tunnel configurations** — different servers, different keys, different endpoints. The entire config is hot-swapped in-place.

For a deep technical dive, see [How Failover Works](/failover/how-it-works/).
