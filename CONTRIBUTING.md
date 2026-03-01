# Contributing

## Build Setup

1. Install prerequisites: Xcode, Go 1.19+ (`brew install go`), SwiftLint (`brew install swiftlint`)
2. Copy the developer config template:
   ```
   cp Sources/WireGuardApp/Config/Developer.xcconfig.template \
      Sources/WireGuardApp/Config/Developer.xcconfig
   ```
3. Edit `Developer.xcconfig` and set `DEVELOPMENT_TEAM`, `APP_ID_IOS`, `APP_ID_MACOS`
4. Build via Xcode or fastlane:
   ```
   fastlane ios build    # iOS
   fastlane mac build    # macOS
   ```

## Submitting Changes

- Fork the repo and create a feature branch
- Keep commits focused and well-described
- Open a pull request against `master`

## Code Style

- SwiftLint is enforced (see `.swiftlint.yml`)
- Follow existing patterns: `DispatchQueue` for concurrency, completion handlers, `wg_log()` for logging, `tr()` for localization

## Licensing

This project is a GPL-3.0-or-later fork of [wireguard-apple](https://git.zx2c4.com/wireguard-apple/) (MIT). See [SUBLICENSING](SUBLICENSING) for header rules.

- **Modified files**: `GPL-3.0-or-later` SPDX header with both WireGuard LLC and contributor copyright
- **New files**: `GPL-3.0-or-later` SPDX header with contributor copyright only
- **Unmodified upstream files**: leave headers as-is
