---
title: Tunnel Management
description: Managing WireGuard tunnels in WGnext.
---

WGnext supports all the tunnel management features of the official WireGuard app, plus failover groups.

## Creating tunnels

### Import from file

WGnext reads standard WireGuard `.conf` files and `.zip` archives containing multiple configs. Tap **+** → **Import from file** and select your file.

Example `.conf` file:

```ini
[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### Scan QR code (iOS)

On iOS, tap **+** → **Scan QR code** to scan a WireGuard configuration QR code.

### Create from scratch

Tap **+** → **Create from scratch** to manually enter all tunnel parameters:

- **Interface**: Private key (auto-generated or pasted), addresses, listen port, MTU, DNS servers
- **Peer**: Public key, pre-shared key (optional), endpoint, allowed IPs, persistent keepalive

## Editing tunnels

Tap a tunnel in the list, then tap **Edit** to modify its configuration. Changes take effect immediately if the tunnel is active — the tunnel is briefly stopped and restarted.

:::note
If a tunnel is part of a failover group, editing it automatically updates the group's configuration as well. The failover group's stored copy of the tunnel config is rebuilt with the latest data.
:::

## Deleting tunnels

Swipe left on a tunnel in the list and tap **Delete**. If the tunnel is referenced by a failover group, the group is updated to remove it. If the group has fewer than 2 tunnels after removal, it becomes invalid and is cleaned up.

## Single tunnel constraint

iOS and macOS allow only one VPN tunnel to be active at a time. This is a system-level constraint, not a limitation of WGnext. Activating a new tunnel (or failover group) automatically deactivates the currently active one.
