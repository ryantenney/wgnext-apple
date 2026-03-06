// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Traffic statistics and metadata written by the Network Extension to shared app group
/// UserDefaults so the iOS Widget can display real-time tunnel information.
struct VPNTrafficData: Codable {

    struct TrafficSample: Codable {
        var timestamp: Date
        var rxRate: Double
        var txRate: Double
    }

    /// Total bytes transmitted since tunnel start.
    var txBytes: UInt64
    /// Total bytes received since tunnel start.
    var rxBytes: UInt64
    /// Current transmit rate in bytes per second.
    var txRate: Double
    /// Current receive rate in bytes per second.
    var rxRate: Double
    /// When the tunnel connected (written once by the NE at start, stable over the session).
    var connectedSince: Date
    /// For failover groups: the name of the currently active configuration.
    var activeConfigName: String?
    /// Timestamp of the most recent WireGuard handshake, if any.
    var lastHandshakeTime: Date?
    /// Rolling array of traffic samples for sparkline rendering.
    var trafficSamples: [TrafficSample]
    /// Public IP address discovered via icanhazip.com, if IP discovery is enabled.
    var discoveredIP: String?
    /// When this data was last updated by the Network Extension.
    var updatedAt: Date

    static let userDefaultsKey = "vpnTrafficData"
    static let maxSamples = 30

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

    static func load() -> VPNTrafficData? {
        guard let data = userDefaults?.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(VPNTrafficData.self, from: data)
    }

    static func save(_ trafficData: VPNTrafficData) {
        guard let data = try? JSONEncoder().encode(trafficData) else { return }
        userDefaults?.set(data, forKey: userDefaultsKey)
    }

    static func clear() {
        userDefaults?.removeObject(forKey: userDefaultsKey)
    }
}
