// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    // MARK: - Failover Group CRUD

    func addFailoverGroup(name: String,
                          tunnelNames: [String],
                          settings: FailoverSettings,
                          onDemandActivation: OnDemandActivation,
                          completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        guard !name.isEmpty else {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }
        guard tunnelNames.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: group must have at least 2 tunnels")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        // Resolve all tunnel names to wg-quick configs
        let configs: [(name: String, config: String)] = tunnelNames.compactMap { tunnelName in
            guard let tunnel = self.tunnel(named: tunnelName),
                  let config = tunnel.tunnelConfiguration?.asWgQuickConfig() else {
                wg_log(.error, message: "Failover: could not load config for tunnel '\(tunnelName)'")
                return nil
            }
            return (tunnelName, config)
        }

        guard configs.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: fewer than 2 valid configs found")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        // Get the primary tunnel's passwordReference to share with the failover group manager
        guard let primaryTunnel = self.tunnel(named: tunnelNames[0]),
              let primaryProto = primaryTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              let passwordRef = primaryProto.passwordReference else {
            wg_log(.error, message: "Failover: primary tunnel '\(tunnelNames[0])' has no valid keychain reference")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        let groupId = UUID().uuidString

        let tunnelProviderManager = NETunnelProviderManager()
        tunnelProviderManager.localizedDescription = name
        tunnelProviderManager.isEnabled = true

        let proto = NETunnelProviderProtocol()
        guard let appId = Bundle.main.bundleIdentifier else {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }
        proto.providerBundleIdentifier = "\(appId).network-extension"
        proto.passwordReference = passwordRef
        proto.serverAddress = "Failover Group"

        var providerConfig: [String: Any] = [:]
        #if os(macOS)
        providerConfig["UID"] = getuid()
        #endif
        providerConfig["FailoverGroupId"] = groupId
        providerConfig["FailoverConfigs"] = configs.map { $0.config }
        providerConfig["FailoverConfigNames"] = configs.map { $0.name }
        if let settingsData = try? JSONEncoder().encode(settings) {
            providerConfig["FailoverSettings"] = settingsData
        }
        proto.providerConfiguration = providerConfig
        tunnelProviderManager.protocolConfiguration = proto

        let onDemandOption = onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = onDemandActivation.isEnabled

        let activeTunnel = (tunnels + failoverGroupTunnels).first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Failover: failed to save group manager: \(error)")
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error)))
                return
            }

            guard let self = self else { return }

            #if os(iOS)
            // HACK: In iOS, adding a tunnel causes deactivation of any currently active tunnel.
            if let activeTunnel = activeTunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            let groupTunnel = TunnelContainer(tunnel: tunnelProviderManager)
            self.failoverGroupTunnels.append(groupTunnel)
            self.failoverGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.failoverGroupListDelegate?.failoverGroupAdded(at: self.failoverGroupTunnels.firstIndex(of: groupTunnel)!)
            completionHandler(.success(groupTunnel))
        }
    }

    func modifyFailoverGroup(tunnel: TunnelContainer,
                             name: String,
                             tunnelNames: [String],
                             settings: FailoverSettings,
                             onDemandActivation: OnDemandActivation,
                             completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        guard !name.isEmpty else {
            completionHandler(TunnelsManagerError.tunnelNameEmpty)
            return
        }

        let tunnelProviderManager = tunnel.tunnelProvider
        let oldName = tunnelProviderManager.localizedDescription ?? ""
        let isNameChanged = name != oldName

        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == name }) && !failoverGroupTunnels.contains(where: { $0.name == name }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = name
            tunnelProviderManager.localizedDescription = name
        }

        // Build a lookup of existing stored configs so we can fall back to them
        // when a standalone tunnel has been deleted but the group still references it.
        let existingProto = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol
        let existingProviderConfig = existingProto?.providerConfiguration ?? [:]
        let existingNames = (existingProviderConfig["FailoverConfigNames"] as? [String]) ?? []
        let existingConfigs = (existingProviderConfig["FailoverConfigs"] as? [String]) ?? []
        var existingConfigByName: [String: String] = [:]
        for (n, c) in zip(existingNames, existingConfigs) {
            existingConfigByName[n] = c
        }

        // Resolve all tunnel names to wg-quick configs, falling back to stored config
        let configs: [(name: String, config: String)] = tunnelNames.compactMap { tunnelName in
            if let t = self.tunnel(named: tunnelName),
               let config = t.tunnelConfiguration?.asWgQuickConfig() {
                return (tunnelName, config)
            }
            if let storedConfig = existingConfigByName[tunnelName] {
                wg_log(.debug, message: "Failover: using stored config for tunnel '\(tunnelName)'")
                return (tunnelName, storedConfig)
            }
            wg_log(.error, message: "Failover: could not load config for tunnel '\(tunnelName)'")
            return nil
        }

        // Update passwordReference if primary tunnel changed
        if let primaryTunnel = self.tunnel(named: tunnelNames[0]),
           let primaryProto = primaryTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
           let passwordRef = primaryProto.passwordReference {
            (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference = passwordRef
        }

        guard let proto = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(nil)
            return
        }

        var providerConfig = proto.providerConfiguration ?? [:]
        providerConfig["FailoverConfigs"] = configs.map { $0.config }
        providerConfig["FailoverConfigNames"] = configs.map { $0.name }
        if let settingsData = try? JSONEncoder().encode(settings) {
            providerConfig["FailoverSettings"] = settingsData
        }
        proto.providerConfiguration = providerConfig

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && onDemandActivation.isEnabled
        let onDemandOption = onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = onDemandActivation.isEnabled
        tunnelProviderManager.isEnabled = true

        let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Failover: failed to save group modification: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            guard let self = self else { return }

            #if os(iOS)
            if let activeTunnel = activeTunnel, activeTunnel !== tunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            if isNameChanged {
                let oldIndex = self.failoverGroupTunnels.firstIndex(of: tunnel)!
                self.failoverGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                let newIndex = self.failoverGroupTunnels.firstIndex(of: tunnel)!
                self.failoverGroupListDelegate?.failoverGroupMoved(from: oldIndex, to: newIndex)
            }
            self.failoverGroupListDelegate?.failoverGroupModified(at: self.failoverGroupTunnels.firstIndex(of: tunnel)!)

            if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                tunnel.status = .restarting
                (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
            }

            if isActivatingOnDemand {
                tunnelProviderManager.loadFromPreferences { error in
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    if let error = error {
                        wg_log(.error, message: "Failover: Re-loading after saving configuration failed: \(error)")
                        completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                    } else {
                        completionHandler(nil)
                    }
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func removeFailoverGroup(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelProviderManager = tunnel.tunnelProvider
        // Note: we do NOT destroy the passwordReference because it belongs to the primary tunnel
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Failover: failed to remove group manager: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if let self = self, let index = self.failoverGroupTunnels.firstIndex(of: tunnel) {
                self.failoverGroupTunnels.remove(at: index)
                self.failoverGroupListDelegate?.failoverGroupRemoved(at: index, tunnel: tunnel)
            }
            completionHandler(nil)
        }
    }

    /// Update any failover groups that reference a tunnel that was modified or renamed.
    func refreshFailoverGroupsContaining(tunnelName: String, oldName: String? = nil) {
        for groupTunnel in failoverGroupTunnels {
            guard let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                  var configNames = proto.providerConfiguration?["FailoverConfigNames"] as? [String] else {
                continue
            }

            let matchName = oldName ?? tunnelName
            guard configNames.contains(matchName) else { continue }

            // Update the name if it was renamed
            if let oldName = oldName, let idx = configNames.firstIndex(of: oldName) {
                configNames[idx] = tunnelName
            }

            // Rebuild configs from current tunnel states
            let configs: [(name: String, config: String)] = configNames.compactMap { name in
                guard let t = self.tunnel(named: name),
                      let config = t.tunnelConfiguration?.asWgQuickConfig() else {
                    return nil
                }
                return (name, config)
            }

            var providerConfig = proto.providerConfiguration ?? [:]
            providerConfig["FailoverConfigs"] = configs.map { $0.config }
            providerConfig["FailoverConfigNames"] = configs.map { $0.name }

            // Update passwordReference if primary changed
            if let primaryName = configNames.first,
               let primaryTunnel = self.tunnel(named: primaryName),
               let primaryProto = primaryTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
               let passwordRef = primaryProto.passwordReference {
                proto.passwordReference = passwordRef
            }

            proto.providerConfiguration = providerConfig
            groupTunnel.tunnelProvider.saveToPreferences { [weak self] _ in
                if let self = self, let index = self.failoverGroupTunnels.firstIndex(of: groupTunnel) {
                    self.failoverGroupListDelegate?.failoverGroupModified(at: index)
                }
            }
        }
    }

    // MARK: - Failover State Query

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

    #if FAILOVER_TESTING
    /// Debug: send a force-failover command to the network extension.
    func debugForceFailover(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        debugSendCommand(messageType: 2, for: tunnel, completionHandler: completionHandler)
    }

    /// Debug: send a force-failback command to the network extension.
    func debugForceFailback(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        debugSendCommand(messageType: 3, for: tunnel, completionHandler: completionHandler)
    }

    private func debugSendCommand(messageType: UInt8, for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(false)
            return
        }
        do {
            try session.sendProviderMessage(Data([messageType])) { responseData in
                guard let data = responseData,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = result["success"] as? Bool else {
                    completionHandler(false)
                    return
                }
                completionHandler(success)
            }
        } catch {
            wg_log(.error, message: "Failover: debug command \(messageType) failed: \(error)")
            completionHandler(false)
        }
    }
    #endif
}
