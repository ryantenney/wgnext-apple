// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    // MARK: - Tunnel-in-Tunnel Group CRUD

    func addTiTGroup(name: String,
                     outerTunnelName: String,
                     innerTunnelName: String,
                     onDemandActivation: OnDemandActivation,
                     completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        guard !name.isEmpty else {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }
        guard outerTunnelName != innerTunnelName else {
            wg_log(.error, staticMessage: "TiT: outer and inner tunnels must be different")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        // Resolve tunnel configs
        guard let outerTunnel = self.tunnel(named: outerTunnelName),
              let outerConfig = outerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for outer tunnel '\(outerTunnelName)'")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }
        guard let innerTunnel = self.tunnel(named: innerTunnelName),
              let innerConfig = innerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for inner tunnel '\(innerTunnelName)'")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        // Get outer tunnel's passwordReference to share
        guard let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              let passwordRef = outerProto.passwordReference else {
            wg_log(.error, message: "TiT: outer tunnel '\(outerTunnelName)' has no valid keychain reference")
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
        proto.serverAddress = "Tunnel-in-Tunnel"

        var providerConfig = TunnelInTunnelGroup.makeProviderConfiguration(
            groupId: groupId,
            outerWgQuick: outerConfig, outerName: outerTunnelName,
            innerWgQuick: innerConfig, innerName: innerTunnelName
        )
        #if os(macOS)
        providerConfig["UID"] = getuid()
        #endif
        proto.providerConfiguration = providerConfig
        tunnelProviderManager.protocolConfiguration = proto

        let onDemandOption = onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = onDemandActivation.isEnabled

        let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "TiT: failed to save group manager: \(error)")
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error)))
                return
            }

            guard let self = self else { return }

            #if os(iOS)
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
            self.titGroupTunnels.append(groupTunnel)
            self.titGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.titGroupListDelegate?.titGroupAdded(at: self.titGroupTunnels.firstIndex(of: groupTunnel)!)
            completionHandler(.success(groupTunnel))
        }
    }

    func modifyTiTGroup(tunnel: TunnelContainer,
                        name: String,
                        outerTunnelName: String,
                        innerTunnelName: String,
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
            guard !tunnels.contains(where: { $0.name == name }) && !failoverGroupTunnels.contains(where: { $0.name == name }) && !titGroupTunnels.contains(where: { $0.name == name }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = name
            tunnelProviderManager.localizedDescription = name
        }

        // Resolve tunnel configs
        guard let outerTunnel = self.tunnel(named: outerTunnelName),
              let outerConfig = outerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for outer tunnel '\(outerTunnelName)'")
            completionHandler(nil)
            return
        }
        guard let innerTunnel = self.tunnel(named: innerTunnelName),
              let innerConfig = innerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for inner tunnel '\(innerTunnelName)'")
            completionHandler(nil)
            return
        }

        // Update passwordReference from outer tunnel
        if let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
           let passwordRef = outerProto.passwordReference {
            (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference = passwordRef
        }

        guard let proto = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(nil)
            return
        }

        var providerConfig = proto.providerConfiguration ?? [:]
        let groupId = providerConfig[TunnelInTunnelConfigKeys.groupId] as? String ?? UUID().uuidString
        let newConfig = TunnelInTunnelGroup.makeProviderConfiguration(
            groupId: groupId,
            outerWgQuick: outerConfig, outerName: outerTunnelName,
            innerWgQuick: innerConfig, innerName: innerTunnelName
        )
        for (key, value) in newConfig {
            providerConfig[key] = value
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
                wg_log(.error, message: "TiT: failed to save group modification: \(error)")
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
                let oldIndex = self.titGroupTunnels.firstIndex(of: tunnel)!
                self.titGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                let newIndex = self.titGroupTunnels.firstIndex(of: tunnel)!
                self.titGroupListDelegate?.titGroupMoved(from: oldIndex, to: newIndex)
            }
            self.titGroupListDelegate?.titGroupModified(at: self.titGroupTunnels.firstIndex(of: tunnel)!)

            if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                tunnel.status = .restarting
                (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
            }

            if isActivatingOnDemand {
                tunnelProviderManager.loadFromPreferences { error in
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    if let error = error {
                        wg_log(.error, message: "TiT: Re-loading after saving configuration failed: \(error)")
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

    func removeTiTGroup(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelProviderManager = tunnel.tunnelProvider
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "TiT: failed to remove group manager: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if let self = self, let index = self.titGroupTunnels.firstIndex(of: tunnel) {
                self.titGroupTunnels.remove(at: index)
                self.titGroupListDelegate?.titGroupRemoved(at: index, tunnel: tunnel)
            }
            completionHandler(nil)
        }
    }

    // MARK: - TiT State Query

    /// Query runtime stats from both INNER and OUTER tunnels in a TiT group.
    func getTiTState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(nil)
            return
        }

        do {
            try session.sendProviderMessage(Data([UInt8(4)])) { responseData in
                guard let data = responseData,
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(nil)
                    return
                }
                completionHandler(state)
            }
        } catch {
            wg_log(.error, message: "TiT: failed to query state: \(error)")
            completionHandler(nil)
        }
    }

    /// Update any TiT groups that reference a tunnel that was modified or renamed.
    func refreshTiTGroupsContaining(tunnelName: String, oldName: String? = nil) {
        for groupTunnel in titGroupTunnels {
            guard let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                  var providerConfig = proto.providerConfiguration else {
                continue
            }

            let matchName = oldName ?? tunnelName
            var outerName = providerConfig[TunnelInTunnelConfigKeys.outerName] as? String ?? ""
            var innerName = providerConfig[TunnelInTunnelConfigKeys.innerName] as? String ?? ""

            guard outerName == matchName || innerName == matchName else { continue }

            // Update names if renamed
            if let oldName = oldName {
                if outerName == oldName { outerName = tunnelName }
                if innerName == oldName { innerName = tunnelName }
            }

            // Rebuild configs from current tunnel states
            if let outerTunnel = self.tunnel(named: outerName),
               let outerConfig = outerTunnel.tunnelConfiguration?.asWgQuickConfig() {
                providerConfig[TunnelInTunnelConfigKeys.outerConfig] = outerConfig
                providerConfig[TunnelInTunnelConfigKeys.outerName] = outerName
            }
            if let innerTunnel = self.tunnel(named: innerName),
               let innerConfig = innerTunnel.tunnelConfiguration?.asWgQuickConfig() {
                providerConfig[TunnelInTunnelConfigKeys.innerConfig] = innerConfig
                providerConfig[TunnelInTunnelConfigKeys.innerName] = innerName
            }

            // Update passwordReference from outer tunnel
            if let outerTunnel = self.tunnel(named: outerName),
               let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
               let passwordRef = outerProto.passwordReference {
                proto.passwordReference = passwordRef
            }

            proto.providerConfiguration = providerConfig
            groupTunnel.tunnelProvider.saveToPreferences { [weak self] _ in
                if let self = self, let index = self.titGroupTunnels.firstIndex(of: groupTunnel) {
                    self.titGroupListDelegate?.titGroupModified(at: index)
                }
            }
        }
    }

}
