// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// Delegate protocol for receiving failover events from the health monitor.
public protocol ConnectionHealthMonitorDelegate: AnyObject {
    /// Called when the monitor switches to a different configuration.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int)

    /// Called when the monitor detects the active connection is unhealthy.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, handshakeAge: TimeInterval)

    /// Called when a failback probe succeeds and the monitor returns to a higher-priority config.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int)
}

/// Monitors WireGuard handshake health across multiple tunnel configurations and
/// triggers failover via `WireGuardAdapter.update()` when the active connection
/// becomes unhealthy. Runs entirely in the Network Extension process.
public class ConnectionHealthMonitor {

    /// The adapter used to query runtime config and switch configurations.
    private weak var adapter: WireGuardAdapter?

    /// Ordered list of tunnel configurations (index 0 = primary).
    private let configurations: [TunnelConfiguration]

    /// Failover behavior settings.
    private let settings: FailoverSettings

    /// Delegate for failover event notifications.
    public weak var delegate: ConnectionHealthMonitorDelegate?

    /// Log handler closure matching WireGuardAdapter's convention.
    private let logHandler: (WireGuardLogLevel, String) -> Void

    /// Index of the currently active configuration.
    public private(set) var activeIndex: Int = 0

    /// Serial queue for all failover state and timer operations.
    private let workQueue = DispatchQueue(label: "WireGuardFailoverMonitor")

    /// Timer for periodic health checks.
    private var healthCheckTimer: DispatchSourceTimer?

    /// Timer for periodic failback probing.
    private var failbackTimer: DispatchSourceTimer?

    /// When the last config switch occurred (anti-flap).
    private var lastSwitchTime: Date = .distantPast

    /// Minimum time to stay on a config before switching again.
    private let minimumHoldTime: TimeInterval = 60

    /// How many full cycles through all configs without stability.
    private var consecutiveCycles: Int = 0

    /// After this many cycles, enter cooldown.
    private let maxCyclesBeforeCooldown: Int = 3

    /// Cooldown duration after too many cycles.
    private let cooldownDuration: TimeInterval = 300

    /// Whether the monitor is currently running.
    public private(set) var isRunning: Bool = false

    /// Whether a failback probe is in progress (prevents concurrent probes).
    private var isProbing: Bool = false

    // MARK: - Initialization

    public init(
        adapter: WireGuardAdapter,
        configurations: [TunnelConfiguration],
        settings: FailoverSettings,
        logHandler: @escaping (WireGuardLogLevel, String) -> Void
    ) {
        self.adapter = adapter
        self.configurations = configurations
        self.settings = settings
        self.logHandler = logHandler
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    public func start() {
        workQueue.async {
            guard !self.isRunning else { return }
            guard self.configurations.count > 1 else {
                self.logHandler(.verbose, "Failover: only one config, health monitor not needed")
                return
            }

            self.isRunning = true
            self.logHandler(.verbose, "Failover: health monitor started with \(self.configurations.count) configs, check interval \(self.settings.healthCheckInterval)s, timeout \(self.settings.handshakeTimeout)s")

            self.startHealthCheckTimer()
            if self.settings.autoFailback {
                self.startFailbackTimer()
            }
        }
    }

    public func stop() {
        workQueue.async {
            self.isRunning = false
            self.healthCheckTimer?.cancel()
            self.healthCheckTimer = nil
            self.failbackTimer?.cancel()
            self.failbackTimer = nil
            self.logHandler(.verbose, "Failover: health monitor stopped")
        }
    }

    /// Called by the adapter when the network path changes. If we're on a fallback
    /// and the network just came back online, this is a good time to probe the primary.
    public func networkPathDidChange() {
        workQueue.async {
            guard self.isRunning, self.activeIndex != 0, self.settings.autoFailback else { return }
            self.logHandler(.verbose, "Failover: network change detected while on fallback, scheduling immediate probe")
            self.workQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.probeFailback()
            }
        }
    }

    // MARK: - Health Check Timer

    private func startHealthCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.healthCheckInterval,
            repeating: settings.healthCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private func checkHealth() {
        guard isRunning, let adapter = adapter else { return }

        adapter.getRuntimeConfiguration { [weak self] configString in
            guard let self = self, let configString = configString else { return }
            self.workQueue.async {
                self.evaluateHealth(runtimeConfig: configString)
            }
        }
    }

    private func evaluateHealth(runtimeConfig: String) {
        let handshakeAge = Self.parseLastHandshakeAge(from: runtimeConfig)

        guard handshakeAge > settings.handshakeTimeout else {
            // Connection is healthy — reset cycle counter
            if consecutiveCycles > 0 {
                logHandler(.verbose, "Failover: connection stable on config #\(activeIndex), resetting cycle counter")
                consecutiveCycles = 0
            }
            return
        }

        // Connection is unhealthy
        delegate?.healthMonitor(self, didDetectUnhealthyConnectionAt: activeIndex, handshakeAge: handshakeAge)

        // Anti-flap: check minimum hold time
        let timeSinceLastSwitch = Date().timeIntervalSince(lastSwitchTime)
        guard timeSinceLastSwitch > minimumHoldTime else {
            logHandler(.verbose, "Failover: unhealthy but within hold time (\(Int(timeSinceLastSwitch))s/\(Int(minimumHoldTime))s), waiting")
            return
        }

        // Anti-flap: check cooldown after too many cycles
        if consecutiveCycles >= maxCyclesBeforeCooldown {
            guard timeSinceLastSwitch > cooldownDuration else {
                logHandler(.verbose, "Failover: in cooldown after \(consecutiveCycles) cycles, \(Int(cooldownDuration - timeSinceLastSwitch))s remaining")
                return
            }
            consecutiveCycles = 0
        }

        // Switch to next config
        let nextIndex = (activeIndex + 1) % configurations.count
        let nextName = configurations[nextIndex].name ?? "config #\(nextIndex)"
        logHandler(.error, "Failover: handshake stale (\(Int(handshakeAge))s > \(Int(settings.handshakeTimeout))s), switching to '\(nextName)'")

        switchToConfig(at: nextIndex)
    }

    // MARK: - Config Switching

    private func switchToConfig(at index: Int) {
        guard let adapter = adapter else { return }

        let config = configurations[index]
        adapter.update(tunnelConfiguration: config) { [weak self] error in
            guard let self = self else { return }
            self.workQueue.async {
                if let error = error {
                    let name = config.name ?? "config #\(index)"
                    self.logHandler(.error, "Failover: failed to switch to '\(name)': \(error.localizedDescription)")
                    // Try the next config in line (skip the one that failed)
                    let nextNext = (index + 1) % self.configurations.count
                    if nextNext != self.activeIndex {
                        self.logHandler(.verbose, "Failover: trying next config #\(nextNext)")
                        self.switchToConfig(at: nextNext)
                    }
                } else {
                    let previousIndex = self.activeIndex
                    self.activeIndex = index
                    self.lastSwitchTime = Date()
                    self.consecutiveCycles += 1

                    let name = config.name ?? "config #\(index)"
                    self.logHandler(.verbose, "Failover: switched from config #\(previousIndex) to '\(name)' (cycle \(self.consecutiveCycles))")
                    self.delegate?.healthMonitor(self, didSwitchToConfigAt: index)
                }
            }
        }
    }

    // MARK: - Failback Probing

    private func startFailbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.failbackProbeInterval,
            repeating: settings.failbackProbeInterval
        )
        timer.setEventHandler { [weak self] in
            self?.probeFailback()
        }
        timer.resume()
        failbackTimer = timer
    }

    private func probeFailback() {
        guard isRunning, activeIndex != 0, !isProbing, let adapter = adapter else { return }

        isProbing = true
        let savedIndex = activeIndex
        let primaryName = configurations[0].name ?? "config #0"
        logHandler(.verbose, "Failover: probing primary '\(primaryName)' for recovery")

        // Switch to primary
        adapter.update(tunnelConfiguration: configurations[0]) { [weak self] error in
            guard let self = self else { return }
            self.workQueue.async {
                guard error == nil else {
                    self.logHandler(.error, "Failover: failback probe failed to switch: \(error!.localizedDescription)")
                    self.isProbing = false
                    return
                }

                // Wait for a handshake to occur
                let probeWait: TimeInterval = min(15, self.settings.handshakeTimeout / 4)
                self.workQueue.asyncAfter(deadline: .now() + probeWait) { [weak self] in
                    self?.evaluateFailbackProbe(savedFallbackIndex: savedIndex)
                }
            }
        }
    }

    private func evaluateFailbackProbe(savedFallbackIndex: Int) {
        guard let adapter = adapter else {
            isProbing = false
            return
        }

        adapter.getRuntimeConfiguration { [weak self] configString in
            guard let self = self, let configString = configString else {
                self?.isProbing = false
                return
            }
            self.workQueue.async {
                let handshakeAge = Self.parseLastHandshakeAge(from: configString)

                if handshakeAge < self.settings.handshakeTimeout {
                    // Primary recovered!
                    let name = self.configurations[0].name ?? "config #0"
                    self.logHandler(.verbose, "Failover: primary '\(name)' recovered (handshake \(Int(handshakeAge))s ago). Staying on primary.")
                    self.activeIndex = 0
                    self.lastSwitchTime = Date()
                    self.consecutiveCycles = 0
                    self.isProbing = false
                    self.delegate?.healthMonitor(self, didFailbackToConfigAt: 0)
                } else {
                    // Primary still unhealthy — revert
                    let fallbackName = self.configurations[savedFallbackIndex].name ?? "config #\(savedFallbackIndex)"
                    self.logHandler(.verbose, "Failover: primary still unhealthy (\(Int(handshakeAge))s), reverting to '\(fallbackName)'")
                    adapter.update(tunnelConfiguration: self.configurations[savedFallbackIndex]) { [weak self] _ in
                        self?.isProbing = false
                    }
                }
            }
        }
    }

    // MARK: - UAPI Parsing

    /// Parse the age of the most recent handshake from a UAPI runtime config string.
    /// Returns `.infinity` if no handshake has ever occurred.
    static func parseLastHandshakeAge(from uapiConfig: String) -> TimeInterval {
        var latestHandshakeTimestamp: TimeInterval = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("last_handshake_time_sec=") {
                let value = line.dropFirst("last_handshake_time_sec=".count)
                if let timestamp = TimeInterval(value), timestamp > latestHandshakeTimestamp {
                    latestHandshakeTimestamp = timestamp
                }
            }
        }

        if latestHandshakeTimestamp > 0 {
            return Date().timeIntervalSince1970 - latestHandshakeTimestamp
        }
        return .infinity
    }
}
