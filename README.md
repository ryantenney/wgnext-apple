# WGnext

An actively maintained [WireGuard](https://www.wireguard.com/) VPN client for iOS and macOS with automatic tunnel failover.

[Download on the App Store](#) <!-- TODO: App Store link -->

## What is this?

WGnext is a fork of the official [wireguard-apple](https://git.zx2c4.com/wireguard-apple/) client. It does everything the upstream app does — import tunnels from files or QR codes, create configs from scratch, on-demand activation rules — plus one headline feature: **failover groups**.

The official WireGuard iOS app hasn't been updated since early 2023. WGnext is under active development with regular updates, bug fixes, and new features.

## Failover Groups

Assign two or more WireGuard tunnels to a failover group in priority order. WGnext monitors your active tunnel for unanswered traffic and seamlessly switches to the next available tunnel when connectivity drops. When your primary tunnel recovers, it switches back. No manual intervention required.

This is useful if you:

- Run dual internet connections with WireGuard exposed on each
- Self-host WireGuard endpoints across multiple servers or providers
- Travel and need your VPN to survive flaky connections without babysitting
- Want redundancy for an always-on VPN configuration

## Building

- Clone this repo:

```
$ git clone https://github.com/rtenney/wgnext
$ cd wgnext
```

- Rename and populate developer team ID file:

```
$ cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig
$ vim Sources/WireGuardApp/Config/Developer.xcconfig
```

- Install prerequisites:

```
$ brew install swiftlint go xcodegen
```

- Generate the Xcode project and open it:

```
$ xcodegen generate
$ open WireGuard.xcodeproj
```

- Flip switches, press buttons, and make whirling noises until Xcode builds it.

## Contributing

Contributors who get a substantive PR merged earn a free license in perpetuity. Already paid? We'll issue a refund. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

This project is a fork of [wireguard-apple](https://git.zx2c4.com/wireguard-apple/), originally developed by Jason A. Donenfeld / WireGuard LLC under the MIT license.

This derivative work is licensed under the [GNU General Public License v3.0 or later](LICENSE). The original MIT license is preserved in [LICENSE.MIT](LICENSE.MIT).

WGnext is not affiliated with or endorsed by the WireGuard project. "WireGuard" is a registered trademark of Jason A. Donenfeld.
