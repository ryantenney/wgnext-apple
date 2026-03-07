---
title: Quick Start
description: Get up and running with WGnext in minutes.
---

This guide walks you through setting up WGnext with your first tunnel and optional failover group.

## Step 1: Add a tunnel

You can add tunnels in three ways:

### Import a `.conf` file
1. Tap **+** → **Import from file**
2. Select a `.conf` or `.zip` file containing your WireGuard configuration

### Scan a QR code
1. Tap **+** → **Scan QR code** (iOS only)
2. Point your camera at a WireGuard configuration QR code

### Create manually
1. Tap **+** → **Create from scratch**
2. Fill in the interface and peer details

## Step 2: Activate

Tap the toggle switch next to your tunnel name. iOS will prompt you to allow VPN configuration the first time.

That's it — you're connected. If you only have one tunnel, WGnext works exactly like the official WireGuard app.

## Step 3: Set up failover (optional)

If you have two or more WireGuard servers, you can create a failover group for automatic switching:

1. Tap **+** → **Create Failover Group**
2. Give the group a name (e.g., "Home VPN")
3. Add your tunnels in priority order — the first is your primary, the rest are fallbacks
4. Configure failover settings or keep the defaults:
   - **Traffic Timeout**: 30 seconds (how long to wait before declaring a tunnel unhealthy)
   - **Health Check Interval**: 10 seconds (how often to check tunnel health)
   - **Auto Failback**: Enabled (automatically return to the primary when it recovers)
   - **Failback Probe Interval**: 300 seconds (how often to check if the primary is back)
5. Tap **Save**

Now activate the failover group instead of individual tunnels. WGnext monitors your connection and switches automatically.

## What to expect

When failover activates:

- The VPN indicator stays connected — no disconnect visible to other apps
- The active tunnel switches in under a second
- The detail view shows which tunnel is currently active
- If auto-failback is enabled, WGnext periodically checks if the primary has recovered

:::tip
You can view live failover status by tapping on the failover group in the tunnel list. The detail screen shows data transferred, last handshake time, failover count, and current health status.
:::
