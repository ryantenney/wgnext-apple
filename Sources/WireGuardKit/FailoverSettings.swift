// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// Configuration for connection failover behavior between tunnel configurations.
public struct FailoverSettings: Codable, Equatable {
    /// Seconds of transmitting data without receiving any before declaring the connection unhealthy.
    /// The monitor detects the pattern of tx_bytes increasing while rx_bytes stays stagnant,
    /// which indicates the tunnel endpoint is unreachable.
    public var trafficTimeout: TimeInterval

    /// How often (in seconds) to poll the WireGuard backend for traffic counters.
    public var healthCheckInterval: TimeInterval

    /// How often (in seconds) to probe higher-priority configurations when running on a fallback.
    public var failbackProbeInterval: TimeInterval

    /// Whether to automatically attempt to return to higher-priority configurations.
    public var autoFailback: Bool

    public init(
        trafficTimeout: TimeInterval = 30,
        healthCheckInterval: TimeInterval = 10,
        failbackProbeInterval: TimeInterval = 300,
        autoFailback: Bool = true
    ) {
        self.trafficTimeout = trafficTimeout
        self.healthCheckInterval = healthCheckInterval
        self.failbackProbeInterval = failbackProbeInterval
        self.autoFailback = autoFailback
    }

    // MARK: - Migration from older settings

    private enum CodingKeys: String, CodingKey {
        case trafficTimeout
        case healthCheckInterval
        case failbackProbeInterval
        case autoFailback
        // Legacy key
        case handshakeTimeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try trafficTimeout first, fall back to legacy handshakeTimeout
        if let timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .trafficTimeout) {
            self.trafficTimeout = timeout
        } else if try container.decodeIfPresent(TimeInterval.self, forKey: .handshakeTimeout) != nil {
            // Legacy settings had much larger timeouts (e.g. 180s); use the new default instead
            self.trafficTimeout = 30
        } else {
            self.trafficTimeout = 30
        }
        self.healthCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .healthCheckInterval) ?? 10
        self.failbackProbeInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .failbackProbeInterval) ?? 300
        self.autoFailback = try container.decodeIfPresent(Bool.self, forKey: .autoFailback) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trafficTimeout, forKey: .trafficTimeout)
        try container.encode(healthCheckInterval, forKey: .healthCheckInterval)
        try container.encode(failbackProbeInterval, forKey: .failbackProbeInterval)
        try container.encode(autoFailback, forKey: .autoFailback)
    }
}
