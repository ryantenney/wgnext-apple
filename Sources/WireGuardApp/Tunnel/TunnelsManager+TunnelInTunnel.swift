// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    // MARK: - TiT Group Convenience CRUD (delegates to shared GroupCRUD)

    func addTiTGroup(name: String,
                     outerTunnelName: String,
                     innerTunnelName: String,
                     onDemandActivation: OnDemandActivation,
                     completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        let spec = TiTGroupSpec(name: name, outerTunnelName: outerTunnelName, innerTunnelName: innerTunnelName, onDemandActivation: onDemandActivation)
        addGroup(spec: spec, completionHandler: completionHandler)
    }

    func modifyTiTGroup(tunnel: TunnelContainer,
                        name: String,
                        outerTunnelName: String,
                        innerTunnelName: String,
                        onDemandActivation: OnDemandActivation,
                        completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let spec = TiTGroupSpec(name: name, outerTunnelName: outerTunnelName, innerTunnelName: innerTunnelName, onDemandActivation: onDemandActivation)
        modifyGroup(tunnel: tunnel, spec: spec, completionHandler: completionHandler)
    }

    func removeTiTGroup(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        removeGroup(kind: .tunnelInTunnel, tunnel: tunnel, completionHandler: completionHandler)
    }

    // MARK: - TiT-Specific: Refresh

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

            // Refresh the group's own keychain copy of the outer config
            if let outerConfig = providerConfig[TunnelInTunnelConfigKeys.outerConfig] as? String,
               let passwordRef = Keychain.makeReference(containing: outerConfig, called: groupTunnel.name, previouslyReferencedBy: proto.passwordReference) {
                proto.passwordReference = passwordRef
            }

            proto.providerConfiguration = providerConfig
            groupTunnel.tunnelProvider.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    wg_log(.error, message: "TiT: failed to save refreshed group '\(groupTunnel.name)': \(error)")
                    return
                }
                if let index = self.titGroupTunnels.firstIndex(of: groupTunnel) {
                    self.groupListDelegate?.groupModified(kind: .tunnelInTunnel, at: index)
                }
                self.applyConfigurationToRunningGroup(groupTunnel)
            }
        }
    }

    // MARK: - TiT State Query

    /// Query runtime stats from both INNER and OUTER tunnels in a TiT group.
    func getTiTState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        getGroupState(kind: .tunnelInTunnel, for: tunnel, completionHandler: completionHandler)
    }
}
