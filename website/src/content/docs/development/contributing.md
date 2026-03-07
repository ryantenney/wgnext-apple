---
title: Contributing
description: How to contribute to WGnext.
---

WGnext is open source and welcomes contributions.

## Contributor reward

Contributors who get a substantive PR merged earn a free WGnext license in perpetuity. Already paid? We'll issue a refund.

## Getting started

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

See the [Build & Run](/development/build/) guide for setting up your development environment.

## Code style

WGnext enforces code style via SwiftLint. Key rules:

- No line length restrictions
- Trailing whitespace allowed
- Minimum identifier length: 0 (no restriction)
- Opt-in rules: `empty_count`, `empty_string`, `unused_import`, and others

Run SwiftLint locally before submitting:

```bash
swiftlint
```

## Architecture notes

Before contributing, familiarize yourself with the codebase structure:

- **Platform-conditional compilation**: Use `#if os(iOS)` / `#if os(macOS)` for platform-specific code
- **Concurrency**: The codebase uses `DispatchQueue` and completion handlers — not async/await or Combine
- **Logging**: Use `wg_log()` for logging (wraps `os_log` + ring buffer file logger)
- **Localization**: Use `tr()` for user-facing strings
- **Errors**: Conform to `WireGuardAppError` protocol with `alertText: (title, message)` pattern

## Areas for contribution

- **macOS failover UI**: The health monitor and extension logic work on macOS, but no macOS-specific UI exists yet
- **Automated tests**: No test suite currently exists
- **Battery profiling**: The health monitor impact hasn't been formally measured
- **Documentation**: Improvements to this website are always welcome

## License

By contributing, you agree that your contributions will be licensed under the [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html).
