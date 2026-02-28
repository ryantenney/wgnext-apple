// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Protocol abstracting the adapter operations needed by the health monitor.
/// `WireGuardAdapter` conforms to this protocol.
public protocol FailoverAdapterProtocol: AnyObject {
    func getRuntimeConfiguration(completionHandler: @escaping (String?) -> Void)
    func update(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (Error?) -> Void)
}

/// Delegate protocol for receiving failover events from the health monitor.
public protocol ConnectionHealthMonitorDelegate: AnyObject {
    /// Called when the monitor switches to a different configuration.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int)

    /// Called when the monitor detects the active connection is unhealthy.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, txWithoutRxDuration: TimeInterval)

    /// Called when a failback probe succeeds and the monitor returns to a higher-priority config.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int)
}

/// Log level for failover messages.
public enum FailoverLogLevel: Int32 {
    case verbose = 0
    case error = 1
}

/// Monitors WireGuard tunnel health by tracking traffic counters (tx_bytes / rx_bytes)
/// across multiple tunnel configurations and triggers failover when the active connection
/// is sending data without receiving any — indicating the tunnel endpoint is unreachable.
/// Runs entirely in the Network Extension process.
public class ConnectionHealthMonitor {

    /// The adapter used to query runtime config and switch configurations.
    private weak var adapter: FailoverAdapterProtocol?

    /// Ordered list of tunnel configurations (index 0 = primary).
    private let configurations: [TunnelConfiguration]

    /// Failover behavior settings.
    private let settings: FailoverSettings

    /// Delegate for failover event notifications.
    public weak var delegate: ConnectionHealthMonitorDelegate?

    /// Log handler closure.
    private let logHandler: (FailoverLogLevel, String) -> Void

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

    // MARK: - Traffic Tracking State

    /// Total tx_bytes from the last health check poll.
    private var lastTxBytes: UInt64 = 0

    /// Total rx_bytes from the last health check poll.
    private var lastRxBytes: UInt64 = 0

    /// When we first noticed tx increasing without rx. `nil` when healthy or idle.
    private var txWithoutRxSince: Date?

    // MARK: - Initialization

    public init(
        adapter: FailoverAdapterProtocol,
        configurations: [TunnelConfiguration],
        settings: FailoverSettings,
        logHandler: @escaping (FailoverLogLevel, String) -> Void
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
            self.logHandler(.verbose, "Failover: health monitor started with \(self.configurations.count) configs, check interval \(self.settings.healthCheckInterval)s, traffic timeout \(self.settings.trafficTimeout)s")

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

        adapter.getRuntimeConfiguration { [weak self] (configString: String?) in
            guard let self = self, let configString = configString else { return }
            self.workQueue.async {
                self.evaluateHealth(runtimeConfig: configString)
            }
        }
    }

    private func evaluateHealth(runtimeConfig: String) {
        let (currentTx, currentRx) = Self.parseTxRxBytes(from: runtimeConfig)

        let txDelta = currentTx - lastTxBytes
        let rxDelta = currentRx - lastRxBytes

        // Update stored values for next check
        let isFirstPoll = (lastTxBytes == 0 && lastRxBytes == 0)
        lastTxBytes = currentTx
        lastRxBytes = currentRx

        // Skip evaluation on the first poll — we need a baseline
        if isFirstPoll {
            return
        }

        if rxDelta > 0 {
            // Receiving data — connection is healthy
            if txWithoutRxSince != nil {
                logHandler(.verbose, "Failover: rx resumed on config #\(activeIndex), connection healthy")
                txWithoutRxSince = nil
            }
            if consecutiveCycles > 0 {
                logHandler(.verbose, "Failover: connection stable on config #\(activeIndex), resetting cycle counter")
                consecutiveCycles = 0
            }
            return
        }

        if txDelta == 0 {
            // No outgoing traffic — tunnel is idle, not unhealthy
            txWithoutRxSince = nil
            return
        }

        // tx is increasing but rx is not — potential problem
        if txWithoutRxSince == nil {
            txWithoutRxSince = Date()
            logHandler(.verbose, "Failover: tx without rx detected on config #\(activeIndex) (tx +\(txDelta) bytes)")
            return
        }

        let duration = Date().timeIntervalSince(txWithoutRxSince!)
        guard duration > settings.trafficTimeout else {
            logHandler(.verbose, "Failover: tx without rx for \(Int(duration))s/\(Int(settings.trafficTimeout))s on config #\(activeIndex)")
            return
        }

        // Connection is unhealthy — sending data but receiving nothing
        delegate?.healthMonitor(self, didDetectUnhealthyConnectionAt: activeIndex, txWithoutRxDuration: duration)

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
        logHandler(.error, "Failover: tx without rx for \(Int(duration))s (>\(Int(settings.trafficTimeout))s), switching to '\(nextName)'")

        switchToConfig(at: nextIndex)
    }

    // MARK: - Config Switching

    private func switchToConfig(at index: Int) {
        guard let adapter = adapter else { return }

        let config = configurations[index]
        adapter.update(tunnelConfiguration: config) { [weak self] (error: Error?) in
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

                    // Reset traffic tracking for the new config
                    self.lastTxBytes = 0
                    self.lastRxBytes = 0
                    self.txWithoutRxSince = nil

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
        adapter.update(tunnelConfiguration: configurations[0]) { [weak self] (error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                guard error == nil else {
                    self.logHandler(.error, "Failover: failback probe failed to switch: \(error!.localizedDescription)")
                    self.isProbing = false
                    return
                }

                // Wait for a handshake to occur — switching configs triggers a handshake attempt,
                // so handshake completion reliably proves the endpoint is reachable.
                let probeWait: TimeInterval = min(15, self.settings.trafficTimeout)
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

        adapter.getRuntimeConfiguration { [weak self] (configString: String?) in
            guard let self = self, let configString = configString else {
                self?.isProbing = false
                return
            }
            self.workQueue.async {
                let handshakeAge = Self.parseLastHandshakeAge(from: configString)

                if handshakeAge < self.settings.trafficTimeout {
                    // Primary recovered!
                    let name = self.configurations[0].name ?? "config #0"
                    self.logHandler(.verbose, "Failover: primary '\(name)' recovered (handshake \(Int(handshakeAge))s ago). Staying on primary.")
                    self.activeIndex = 0
                    self.lastSwitchTime = Date()
                    self.consecutiveCycles = 0
                    self.lastTxBytes = 0
                    self.lastRxBytes = 0
                    self.txWithoutRxSince = nil
                    self.isProbing = false
                    self.delegate?.healthMonitor(self, didFailbackToConfigAt: 0)
                } else {
                    // Primary still unhealthy — revert
                    let fallbackName = self.configurations[savedFallbackIndex].name ?? "config #\(savedFallbackIndex)"
                    self.logHandler(.verbose, "Failover: primary still unhealthy (\(Int(handshakeAge))s), reverting to '\(fallbackName)'")
                    adapter.update(tunnelConfiguration: self.configurations[savedFallbackIndex]) { [weak self] (_: Error?) in
                        guard let self = self else { return }
                        self.workQueue.async {
                            self.lastTxBytes = 0
                            self.lastRxBytes = 0
                            self.txWithoutRxSince = nil
                            self.isProbing = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - State Snapshot

    /// Returns a snapshot of the health monitor's current state for IPC reporting.
    /// Dispatches to the internal work queue for thread safety.
    public func getStateSnapshot(completionHandler: @escaping ([String: Any]) -> Void) {
        workQueue.async {
            var state = [String: Any]()
            if self.consecutiveCycles > 0 {
                state["consecutiveCycles"] = self.consecutiveCycles
            }
            if self.isProbing {
                state["isProbing"] = true
            }
            if self.lastSwitchTime != .distantPast {
                state["lastSwitchTime"] = self.lastSwitchTime.timeIntervalSince1970
            }
            if let txWithoutRxSince = self.txWithoutRxSince {
                state["txWithoutRxSince"] = txWithoutRxSince.timeIntervalSince1970
            }
            completionHandler(state)
        }
    }

    // MARK: - UAPI Parsing

    /// Parse total tx_bytes and rx_bytes from a UAPI runtime config string.
    /// Sums across all peers.
    static func parseTxRxBytes(from uapiConfig: String) -> (tx: UInt64, rx: UInt64) {
        var totalTx: UInt64 = 0
        var totalRx: UInt64 = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("tx_bytes=") {
                let value = line.dropFirst("tx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalTx += bytes
                }
            } else if line.hasPrefix("rx_bytes=") {
                let value = line.dropFirst("rx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalRx += bytes
                }
            }
        }

        return (totalTx, totalRx)
    }

    /// Parse the age of the most recent handshake from a UAPI runtime config string.
    /// Used for failback probing. Returns `.infinity` if no handshake has ever occurred.
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

    #if FAILOVER_TESTING
    // MARK: - Debug: Force Failover

    /// Force an immediate switch to the next configuration, bypassing health checks.
    public func forceSwitch(completionHandler: @escaping (Bool) -> Void) {
        workQueue.async {
            guard self.isRunning else {
                completionHandler(false)
                return
            }
            let nextIndex = (self.activeIndex + 1) % self.configurations.count
            let name = self.configurations[nextIndex].name ?? "config #\(nextIndex)"
            self.logHandler(.verbose, "Failover: DEBUG force switch to '\(name)'")
            self.switchToConfig(at: nextIndex)
            completionHandler(true)
        }
    }

    /// Force an immediate failback to the primary configuration (index 0).
    public func forceFailback(completionHandler: @escaping (Bool) -> Void) {
        workQueue.async {
            guard self.isRunning, self.activeIndex != 0 else {
                completionHandler(false)
                return
            }
            let name = self.configurations[0].name ?? "config #0"
            self.logHandler(.verbose, "Failover: DEBUG force failback to '\(name)'")
            self.switchToConfig(at: 0)
            completionHandler(true)
        }
    }
    #endif
}
