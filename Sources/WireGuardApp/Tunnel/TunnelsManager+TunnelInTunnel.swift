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
        let matchName = oldName ?? tunnelName
        forEachGroupNeedingRefresh(kind: .tunnelInTunnel) { _, proto, providerConfig in
            var outerName = providerConfig[ProviderConfigurationKeys.titOuterName] as? String ?? ""
            var innerName = providerConfig[ProviderConfigurationKeys.titInnerName] as? String ?? ""

            guard outerName == matchName || innerName == matchName else { return false }

            // Update names if renamed
            if let oldName = oldName {
                if outerName == oldName { outerName = tunnelName }
                if innerName == oldName { innerName = tunnelName }
            }

            // Rebuild configs from current tunnel states
            if let outerTunnel = self.tunnel(named: outerName),
               let outerConfig = outerTunnel.tunnelConfiguration?.asWgQuickConfig() {
                providerConfig[ProviderConfigurationKeys.titOuterConfig] = outerConfig
                providerConfig[ProviderConfigurationKeys.titOuterName] = outerName
            }
            if let innerTunnel = self.tunnel(named: innerName),
               let innerConfig = innerTunnel.tunnelConfiguration?.asWgQuickConfig() {
                providerConfig[ProviderConfigurationKeys.titInnerConfig] = innerConfig
                providerConfig[ProviderConfigurationKeys.titInnerName] = innerName
            }

            // Update passwordReference from outer tunnel
            if let outerTunnel = self.tunnel(named: outerName),
               let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
               let passwordRef = outerProto.passwordReference {
                proto.passwordReference = passwordRef
            }
            return true
        }
    }

    // MARK: - TiT State Query

    /// Query runtime stats from both INNER and OUTER tunnels in a TiT group.
    func getTiTState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        getGroupState(kind: .tunnelInTunnel, for: tunnel, completionHandler: completionHandler)
    }
}
