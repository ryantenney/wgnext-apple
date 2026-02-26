// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension

extension TunnelsManager {

    /// Activate a failover group: loads all referenced configs, packs them into
    /// the primary tunnel's `providerConfiguration`, and starts the primary tunnel.
    func startActivation(ofFailoverGroup group: FailoverGroup) {
        guard group.tunnelNames.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: group must have at least 2 tunnels")
            return
        }

        // Resolve all tunnel names to configurations
        let configs: [(name: String, config: String)] = group.tunnelNames.compactMap { name in
            guard let tunnel = self.tunnel(named: name),
                  let config = tunnel.tunnelConfiguration?.asWgQuickConfig() else {
                wg_log(.error, message: "Failover: could not load config for tunnel '\(name)'")
                return nil
            }
            return (name, config)
        }

        guard configs.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: fewer than 2 valid configs found, cannot activate group")
            return
        }

        guard let primaryTunnel = self.tunnel(named: group.tunnelNames[0]) else {
            wg_log(.error, message: "Failover: primary tunnel '\(group.tunnelNames[0])' not found")
            return
        }

        // Pack failover configs into providerConfiguration
        let tunnelProvider = primaryTunnel.tunnelProvider
        guard let proto = tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }

        var providerConfig: [String: Any] = proto.providerConfiguration ?? [:]
        #if os(macOS)
        providerConfig["UID"] = getuid()
        #endif
        providerConfig["FailoverConfigs"] = configs.map { $0.config }
        providerConfig["FailoverConfigNames"] = configs.map { $0.name }
        if let settingsData = try? JSONEncoder().encode(group.settings) {
            providerConfig["FailoverSettings"] = settingsData
        }
        providerConfig["FailoverGroupId"] = group.id.uuidString

        proto.providerConfiguration = providerConfig

        tunnelProvider.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Failover: failed to save provider configuration: \(error)")
                return
            }
            wg_log(.info, message: "Failover: activating group '\(group.name)' with \(configs.count) configs")
            self?.startActivation(of: primaryTunnel)
        }
    }

    /// Query the failover state from the active tunnel's network extension.
    func getFailoverState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(nil)
            return
        }

        do {
            try session.sendProviderMessage(Data([UInt8(1)])) { responseData in
                guard let data = responseData,
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(nil)
                    return
                }
                completionHandler(state)
            }
        } catch {
            wg_log(.error, message: "Failover: failed to query state: \(error)")
            completionHandler(nil)
        }
    }

    /// Check if the given tunnel is currently running as part of a failover group.
    func activeFailoverGroupId(for tunnel: TunnelContainer) -> String? {
        let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol
        return proto?.providerConfiguration?["FailoverGroupId"] as? String
    }

    /// Deactivate a failover group by stopping the active tunnel and clearing the
    /// failover configuration from providerConfiguration.
    func stopFailoverGroup(primaryTunnel: TunnelContainer, completionHandler: @escaping () -> Void) {
        // Stop the tunnel first
        startDeactivation(of: primaryTunnel)

        // Clean up the failover keys from providerConfiguration
        let tunnelProvider = primaryTunnel.tunnelProvider
        guard let proto = tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler()
            return
        }

        var providerConfig = proto.providerConfiguration ?? [:]
        providerConfig.removeValue(forKey: "FailoverConfigs")
        providerConfig.removeValue(forKey: "FailoverConfigNames")
        providerConfig.removeValue(forKey: "FailoverSettings")
        providerConfig.removeValue(forKey: "FailoverGroupId")
        proto.providerConfiguration = providerConfig

        tunnelProvider.saveToPreferences { _ in
            completionHandler()
        }
    }
}
