// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Lightweight snapshot of VPN status written to the shared app group UserDefaults
/// so the iOS Widget can display current connection state without querying NE APIs.
struct VPNStatusData: Codable {
    enum ConnectionState: String, Codable {
        case connected
        case connecting
        case disconnected
        case disconnecting
    }

    var state: ConnectionState
    var tunnelName: String
    var connectedAt: Date?
    var isOnDemandEnabled: Bool?
    var hasOnDemandRules: Bool?

    static let userDefaultsKey = "vpnStatusData"

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

    static func load() -> VPNStatusData? {
        guard let data = userDefaults?.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(VPNStatusData.self, from: data)
    }

    static func save(_ status: VPNStatusData) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        userDefaults?.set(data, forKey: userDefaultsKey)
    }

    static func clear() {
        userDefaults?.removeObject(forKey: userDefaultsKey)
    }
}
