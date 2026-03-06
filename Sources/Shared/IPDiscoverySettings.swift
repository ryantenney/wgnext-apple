// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// User preference and state for IP address discovery. Persisted in the shared
/// app group UserDefaults so the main app, Network Extension, and widget can
/// all access it.
///
/// When enabled, the app queries icanhazip.com on tunnel connect to discover
/// the public IP address through the active VPN tunnel.
struct IPDiscoverySettings {

    private static let keyEnabled = "ipDiscoveryEnabled"

    private static var userDefaults: UserDefaults? {
        #if os(iOS)
        let key = "com.wireguard.ios.app_group_id"
        #elseif os(macOS)
        let key = "com.wireguard.macos.app_group_id"
        #else
        #error("Unimplemented")
        #endif
        guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    /// Whether IP discovery is enabled. Defaults to `false`.
    static var isEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyEnabled) ?? false }
        set { userDefaults?.set(newValue, forKey: keyEnabled) }
    }

    private static let keyDiscoveredIP = "discoveredPublicIP"

    /// Most recently discovered public IP address. Written by the app, read by
    /// the app and the widget.
    static var discoveredIP: String? {
        get { return userDefaults?.string(forKey: keyDiscoveredIP) }
        set { userDefaults?.set(newValue, forKey: keyDiscoveredIP) }
    }
}
