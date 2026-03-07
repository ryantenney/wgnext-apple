---
title: Import & Export
description: Importing and exporting WireGuard tunnel configurations.
---

WGnext supports the same import and export formats as the official WireGuard app.

## Import

### Supported formats

- **`.conf` files**: Standard WireGuard configuration files (wg-quick format)
- **`.zip` archives**: ZIP files containing one or more `.conf` files
- **QR codes**: WireGuard configuration encoded as QR codes (iOS only)

### How to import

#### From the app
1. Tap **+** in the tunnel list
2. Choose **Import from file** or **Scan QR code**
3. Select your configuration

#### From Files / Share Sheet
On iOS, you can also open `.conf` or `.zip` files directly from the Files app or any share sheet — WGnext registers as a handler for these file types.

## Export

### Export all tunnels
1. Open the app
2. Select the export option from the menu
3. Choose a destination for the `.zip` file

The exported archive contains all tunnel configurations as individual `.conf` files in standard wg-quick format.

### What's exported

Exported configurations include all tunnel settings:
- Interface: private key, addresses, DNS, MTU, listen port
- Peers: public key, pre-shared key, endpoint, allowed IPs, persistent keepalive

### What's NOT exported

- Failover group configuration (group membership, failover settings)
- On-demand activation rules
- App preferences

These are specific to WGnext and would need to be reconfigured after import.

## Configuration format

WGnext uses the standard [wg-quick configuration format](https://man7.org/linux/man-pages/man8/wg-quick.8.html):

```ini
[Interface]
PrivateKey = <base64-encoded private key>
Address = 10.0.0.2/32, fd00::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1420

[Peer]
PublicKey = <base64-encoded public key>
PresharedKey = <base64-encoded pre-shared key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```
