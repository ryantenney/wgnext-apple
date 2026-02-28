// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension
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

        adapter.healthMonitor?.stop()
        adapter.healthMonitor = nil

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

// MARK: - ConnectionHealthMonitorDelegate

extension PacketTunnelProvider: ConnectionHealthMonitorDelegate {
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int) {
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: now active on '\(name)'")
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, txWithoutRxDuration: TimeInterval) {
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: '\(name)' unhealthy (tx without rx for \(Int(txWithoutRxDuration))s)")
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int) {
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: successfully failed back to '\(name)'")
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
