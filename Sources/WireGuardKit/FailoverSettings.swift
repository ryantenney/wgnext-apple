// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// Configuration for connection failover behavior between tunnel configurations.
public struct FailoverSettings: Codable, Equatable {
    /// Seconds without a successful handshake before declaring the connection unhealthy.
    /// Should be greater than 2x `persistentKeepAlive` to avoid false positives.
    public var handshakeTimeout: TimeInterval

    /// How often (in seconds) to poll the WireGuard backend for handshake freshness.
    public var healthCheckInterval: TimeInterval

    /// How often (in seconds) to probe higher-priority configurations when running on a fallback.
    public var failbackProbeInterval: TimeInterval

    /// Whether to automatically attempt to return to higher-priority configurations.
    public var autoFailback: Bool

    public init(
        handshakeTimeout: TimeInterval = 180,
        healthCheckInterval: TimeInterval = 30,
        failbackProbeInterval: TimeInterval = 300,
        autoFailback: Bool = true
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.healthCheckInterval = healthCheckInterval
        self.failbackProbeInterval = failbackProbeInterval
        self.autoFailback = autoFailback
    }
}
