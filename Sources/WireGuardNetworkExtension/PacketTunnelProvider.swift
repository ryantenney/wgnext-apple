// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension
import UserNotifications
import os

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()

    /// All tunnel configurations for failover (index 0 = primary). Empty if failover is not configured.
    private var failoverConfigs: [TunnelConfiguration] = []

    /// Names corresponding to failoverConfigs, for display/logging.
    private var failoverConfigNames: [String] = []

    /// Index of the currently active configuration within failoverConfigs.
    private var activeConfigIndex: Int = 0

    // MARK: - Widget Stats Writer

    /// Timer that periodically writes traffic stats to shared UserDefaults for the widget.
    private var statsTimer: DispatchSourceTimer?

    /// tx_bytes from the previous stats poll (for rate computation).
    private var previousStatsTxBytes: UInt64 = 0

    /// rx_bytes from the previous stats poll (for rate computation).
    private var previousStatsRxBytes: UInt64 = 0

    /// Timestamp of the previous stats poll.
    private var previousStatsTime: Date?

    /// Rolling traffic samples for sparkline.
    private var trafficSamples: [VPNTrafficData.TrafficSample] = []

    /// When this tunnel session connected.
    private var tunnelConnectedSince: Date?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        // Load failover configurations from providerConfiguration, if present
        let providerConfig = tunnelProviderProtocol.providerConfiguration
        loadFailoverConfigs(from: providerConfig)

        // Determine the primary tunnel configuration
        let tunnelConfiguration: TunnelConfiguration
        if let primary = failoverConfigs.first {
            tunnelConfiguration = primary
            wg_log(.info, message: "Failover: loaded \(failoverConfigs.count) configs [\(failoverConfigNames.joined(separator: ", "))]")
        } else {
            guard let config = tunnelProviderProtocol.asTunnelConfiguration() else {
                errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                return
            }
            tunnelConfiguration = config
        }

        // Start the tunnel
        adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
            guard let adapterError = adapterError else {
                let interfaceName = self.adapter.interfaceName ?? "unknown"

                wg_log(.info, message: "Tunnel interface is \(interfaceName)")

                // Start health monitor if failover is configured
                self.startHealthMonitorIfNeeded(providerConfig: providerConfig)

                // Start writing traffic stats to shared UserDefaults for the widget
                self.startStatsWriter()

                completionHandler(nil)
                return
            }

            switch adapterError {
            case .cannotLocateTunnelFileDescriptor:
                wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
                errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

            case .dnsResolution(let dnsErrors):
                let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                    .joined(separator: ", ")
                wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

            case .setNetworkSettings(let error):
                wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

            case .startWireGuardBackend(let errorCode):
                wg_log(.error, message: "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(PacketTunnelProviderError.couldNotStartBackend)

            case .invalidState:
                // Must never happen
                fatalError()
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wg_log(.info, staticMessage: "Stopping tunnel")

        // Determine a display name for disconnect notifications
        let displayName: String
        if let configNames = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["FailoverConfigNames"] as? [String], let firstName = configNames.first {
            displayName = firstName
        } else if let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.asTunnelConfiguration() {
            displayName = config.name ?? "WireGuard"
        } else {
            displayName = "WireGuard"
        }

        // Post a disconnect notification if the user enabled it and the stop was
        // not triggered by the user themselves (e.g. network lost, server closed).
        #if os(iOS)
        if reason != .none && reason != .userInitiated {
            postDisconnectNotificationIfEnabled(tunnelName: displayName, reason: reason)
        }
        #endif

        adapter.healthMonitor?.stop()
        adapter.healthMonitor = nil
        stopStatsWriter()

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            completionHandler()

            #if os(macOS)
            // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
            // Remove it when they finally fix this upstream and the fix has been rolled out to
            // sufficient quantities of users.
            exit(0)
            #endif
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        guard messageData.count >= 1 else {
            completionHandler(nil)
            return
        }

        switch messageData[0] {
        case 0:
            // Existing: get runtime configuration
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completionHandler(data)
            }

        case 1:
            // Failover: get current failover state + runtime stats
            var state: [String: Any] = [
                "activeIndex": activeConfigIndex,
                "activeConfig": failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : "unknown",
                "totalConfigs": failoverConfigs.count,
                "configNames": failoverConfigNames,
                "isFailoverActive": failoverConfigs.count > 1
            ]

            let group = DispatchGroup()

            // Gather health monitor state
            if let monitor = adapter.healthMonitor {
                group.enter()
                monitor.getStateSnapshot { snapshot in
                    for (key, value) in snapshot {
                        state[key] = value
                    }
                    group.leave()
                }
            }

            // Gather runtime peer stats (tx/rx bytes, last handshake)
            group.enter()
            adapter.getRuntimeConfiguration { configString in
                if let configString = configString {
                    let (tx, rx) = ConnectionHealthMonitor.parseTxRxBytes(from: configString)
                    state["txBytes"] = tx
                    state["rxBytes"] = rx
                    let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: configString)
                    if handshakeAge != .infinity {
                        state["lastHandshakeTime"] = Date().timeIntervalSince1970 - handshakeAge
                    }
                }
                group.leave()
            }

            group.notify(queue: .main) {
                completionHandler(try? JSONSerialization.data(withJSONObject: state))
            }

        #if FAILOVER_TESTING
        case 2:
            // Debug: force failover to next config
            guard let monitor = adapter.healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceSwitch { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }

        case 3:
            // Debug: force failback to primary
            guard let monitor = adapter.healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceFailback { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }
        #endif

        default:
            completionHandler(nil)
        }
    }

    // MARK: - Widget Stats Writer

    private func startStatsWriter() {
        tunnelConnectedSince = Date()
        previousStatsTxBytes = 0
        previousStatsRxBytes = 0
        previousStatsTime = nil
        trafficSamples = []

        // Determine initial active config name for failover groups
        let initialActiveConfig: String?
        if !failoverConfigNames.isEmpty {
            initialActiveConfig = failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : nil
        } else {
            initialActiveConfig = nil
        }

        // Write initial traffic data immediately so the widget sees it right away
        let initial = VPNTrafficData(
            txBytes: 0,
            rxBytes: 0,
            txRate: 0,
            rxRate: 0,
            connectedSince: tunnelConnectedSince!,
            activeConfigName: initialActiveConfig,
            lastHandshakeTime: nil,
            trafficSamples: [],
            updatedAt: Date()
        )
        VPNTrafficData.save(initial)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.pollAndWriteStats()
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsWriter() {
        statsTimer?.cancel()
        statsTimer = nil
        VPNTrafficData.clear()
    }

    private func pollAndWriteStats() {
        adapter.getRuntimeConfiguration { [weak self] configString in
            guard let self = self, let configString = configString else { return }

            let now = Date()
            let (currentTx, currentRx) = ConnectionHealthMonitor.parseTxRxBytes(from: configString)

            // Compute rates
            var txRate: Double = 0
            var rxRate: Double = 0
            if let prevTime = self.previousStatsTime {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0 {
                    txRate = Double(currentTx - self.previousStatsTxBytes) / elapsed
                    rxRate = Double(currentRx - self.previousStatsRxBytes) / elapsed
                }
            }

            self.previousStatsTxBytes = currentTx
            self.previousStatsRxBytes = currentRx
            self.previousStatsTime = now

            // Parse last handshake
            let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: configString)
            let lastHandshake: Date? = handshakeAge != .infinity ? now.addingTimeInterval(-handshakeAge) : nil

            // Append to rolling traffic samples
            let sample = VPNTrafficData.TrafficSample(timestamp: now, rxRate: rxRate, txRate: txRate)
            self.trafficSamples.append(sample)
            if self.trafficSamples.count > VPNTrafficData.maxSamples {
                self.trafficSamples.removeFirst(self.trafficSamples.count - VPNTrafficData.maxSamples)
            }

            // Determine active config name for failover
            let activeConfig: String?
            if !self.failoverConfigNames.isEmpty {
                activeConfig = self.failoverConfigNames.indices.contains(self.activeConfigIndex) ? self.failoverConfigNames[self.activeConfigIndex] : nil
            } else {
                activeConfig = nil
            }

            let trafficData = VPNTrafficData(
                txBytes: currentTx,
                rxBytes: currentRx,
                txRate: txRate,
                rxRate: rxRate,
                connectedSince: self.tunnelConnectedSince ?? now,
                activeConfigName: activeConfig,
                lastHandshakeTime: lastHandshake,
                trafficSamples: self.trafficSamples,
                updatedAt: now
            )
            VPNTrafficData.save(trafficData)
        }
    }

    // MARK: - Failover Setup

    private func loadFailoverConfigs(from providerConfig: [String: Any]?) {
        guard let configStrings = providerConfig?["FailoverConfigs"] as? [String] else { return }

        let names = providerConfig?["FailoverConfigNames"] as? [String] ?? []
        failoverConfigNames = names

        failoverConfigs = configStrings.enumerated().compactMap { index, configString in
            let name = names.indices.contains(index) ? names[index] : nil
            do {
                return try TunnelConfiguration(fromWgQuickConfig: configString, called: name)
            } catch {
                wg_log(.error, message: "Failover: failed to parse config #\(index) '\(name ?? "unknown")': \(error)")
                return nil
            }
        }
    }

    private func startHealthMonitorIfNeeded(providerConfig: [String: Any]?) {
        guard failoverConfigs.count > 1 else { return }

        var settings = FailoverSettings()
        if let settingsData = providerConfig?["FailoverSettings"] as? Data {
            if let decoded = try? JSONDecoder().decode(FailoverSettings.self, from: settingsData) {
                settings = decoded
            }
        }

        let monitor = ConnectionHealthMonitor(
            adapter: adapter,
            configurations: failoverConfigs,
            settings: settings
        ) { (logLevel: FailoverLogLevel, message: String) in
            wg_log(logLevel.osLogLevel, message: message)
        }
        monitor.delegate = self
        adapter.healthMonitor = monitor
        monitor.start()
    }
}

// MARK: - Local Notifications

#if os(iOS)
extension PacketTunnelProvider {
    private func postDisconnectNotificationIfEnabled(tunnelName: String, reason: NEProviderStopReason) {
        guard NotificationSettings.isDisconnectNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Disconnected"
        content.body = "'\(tunnelName)' has been disconnected."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-disconnect-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post disconnect notification: \(error.localizedDescription)")
            }
        }
    }

    func postFailoverNotificationIfEnabled(from fromName: String, to toName: String) {
        guard NotificationSettings.isFailoverNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Failover"
        content.body = "Switched from '\(fromName)' to '\(toName)'."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-failover-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post failover notification: \(error.localizedDescription)")
            }
        }
    }

    func postFailbackNotificationIfEnabled(to name: String) {
        guard NotificationSettings.isFailoverNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Failback"
        content.body = "Returned to primary connection '\(name)'."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-failback-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post failback notification: \(error.localizedDescription)")
            }
        }
    }
}
#endif

// MARK: - ConnectionHealthMonitorDelegate

extension PacketTunnelProvider: ConnectionHealthMonitorDelegate {
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int) {
        let previousName = failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : "config #\(activeConfigIndex)"
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: now active on '\(name)'")
        #if os(iOS)
        postFailoverNotificationIfEnabled(from: previousName, to: name)
        #endif
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, txWithoutRxDuration: TimeInterval) {
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: '\(name)' unhealthy (tx without rx for \(Int(txWithoutRxDuration))s)")
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int) {
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: successfully failed back to '\(name)'")
        #if os(iOS)
        postFailbackNotificationIfEnabled(to: name)
        #endif
    }
}

extension FailoverLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

extension WireGuardAdapter: FailoverAdapterProtocol {
    public func update(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (Error?) -> Void) {
        update(tunnelConfiguration: tunnelConfiguration) { (error: WireGuardAdapterError?) in
            completionHandler(error)
        }
    }
}
