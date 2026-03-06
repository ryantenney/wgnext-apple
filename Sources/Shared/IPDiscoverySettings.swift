// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// User preference for IP address discovery. Persisted in the shared app group
/// UserDefaults so both the main app and the Network Extension can read it.
///
/// When enabled, the Network Extension periodically queries icanhazip.com to
/// discover the public IP address of the active VPN connection.
struct IPDiscoverySettings {

    private static let keyEnabled = "ipDiscoveryEnabled"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    /// Whether IP discovery is enabled. Defaults to `false`.
    static var isEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyEnabled) ?? false }
        set { userDefaults?.set(newValue, forKey: keyEnabled) }
    }
}
