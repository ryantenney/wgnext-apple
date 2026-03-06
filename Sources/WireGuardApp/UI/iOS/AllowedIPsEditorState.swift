// SPDX-License-Identifier: MIT
// Copyright © 2026 Ryan Tenney.

import Foundation

enum AllowedIPsPreset: CaseIterable {
    case routeAll       // 0.0.0.0/0, ::/0
    case routeIPv4Only  // 0.0.0.0/0
    case custom
}

class AllowedIPsEditorState {
    private weak var peerData: TunnelViewModel.PeerData?
    private weak var tunnelViewModel: TunnelViewModel?

    private(set) var preset: AllowedIPsPreset
    private(set) var excludePrivateIPs: Bool
    private(set) var ranges: [String]

    init(peerData: TunnelViewModel.PeerData, tunnelViewModel: TunnelViewModel) {
        self.peerData = peerData
        self.tunnelViewModel = tunnelViewModel

        let allowedIPsString = peerData[.allowedIPs]
        let rangesList = allowedIPsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines)
        let rangesSet = Set(rangesList)

        // Detect preset from current state
        let hasIPv4Default = rangesSet.contains(TunnelViewModel.PeerData.ipv4DefaultRouteString)
        let hasIPv6Default = rangesSet.contains(TunnelViewModel.PeerData.ipv6DefaultRouteString)
        let hasIPv4ModRFC1918 = rangesSet.isSuperset(of: TunnelViewModel.PeerData.ipv4DefaultRouteModRFC1918String)

        if hasIPv4Default && hasIPv6Default {
            // Check if it's exactly the route-all preset (possibly with DNS servers for exclude-private)
            preset = .routeAll
            excludePrivateIPs = false
        } else if hasIPv4ModRFC1918 && hasIPv6Default {
            // Route all with exclude private IPs enabled
            preset = .routeAll
            excludePrivateIPs = true
        } else if hasIPv4Default && !hasIPv6Default {
            let nonIPv4Default = rangesSet.subtracting([TunnelViewModel.PeerData.ipv4DefaultRouteString])
            if nonIPv4Default.isEmpty || nonIPv4Default.allSatisfy({ !$0.contains(":") }) {
                preset = .routeIPv4Only
                excludePrivateIPs = false
            } else {
                preset = .custom
                excludePrivateIPs = false
            }
        } else if hasIPv4ModRFC1918 && !hasIPv6Default {
            preset = .routeIPv4Only
            excludePrivateIPs = true
        } else {
            preset = .custom
            excludePrivateIPs = false
        }

        ranges = rangesList
    }

    var isCustom: Bool {
        return preset == .custom
    }

    func selectPreset(_ newPreset: AllowedIPsPreset) {
        guard let peerData = peerData, let tunnelViewModel = tunnelViewModel else { return }
        preset = newPreset
        let dnsServers = tunnelViewModel.interfaceData[.dns]

        switch newPreset {
        case .routeAll:
            if excludePrivateIPs {
                let dnsServerStrings = dnsServers.splitToArray(trimmingCharacters: .whitespacesAndNewlines)
                let normalizedDNS = TunnelViewModel.PeerData.normalizedIPAddressRangeStrings(dnsServerStrings)
                ranges = [TunnelViewModel.PeerData.ipv6DefaultRouteString] + TunnelViewModel.PeerData.ipv4DefaultRouteModRFC1918String + normalizedDNS
            } else {
                ranges = [TunnelViewModel.PeerData.ipv4DefaultRouteString, TunnelViewModel.PeerData.ipv6DefaultRouteString]
            }
        case .routeIPv4Only:
            if excludePrivateIPs {
                let dnsServerStrings = dnsServers.splitToArray(trimmingCharacters: .whitespacesAndNewlines)
                let normalizedDNS = TunnelViewModel.PeerData.normalizedIPAddressRangeStrings(dnsServerStrings)
                ranges = TunnelViewModel.PeerData.ipv4DefaultRouteModRFC1918String + normalizedDNS
            } else {
                ranges = [TunnelViewModel.PeerData.ipv4DefaultRouteString]
            }
        case .custom:
            // Keep current ranges as-is
            break
        }

        syncToScratchpad(peerData: peerData)
    }

    func setExcludePrivateIPs(_ isOn: Bool) {
        guard let peerData = peerData, let tunnelViewModel = tunnelViewModel else { return }
        guard preset != .custom else { return }

        excludePrivateIPs = isOn
        let dnsServers = tunnelViewModel.interfaceData[.dns]

        // Reuse existing logic
        let currentAllowedIPs = ranges
        let dnsServerStrings = dnsServers.splitToArray(trimmingCharacters: .whitespacesAndNewlines)
        let modifiedIPs = TunnelViewModel.PeerData.modifiedAllowedIPs(
            currentAllowedIPs: currentAllowedIPs,
            excludePrivateIPs: isOn,
            dnsServers: dnsServerStrings,
            oldDNSServers: nil
        )

        // For routeAll, ensure ::/0 is present
        if preset == .routeAll {
            var result = modifiedIPs
            if !result.contains(TunnelViewModel.PeerData.ipv6DefaultRouteString) {
                result.insert(TunnelViewModel.PeerData.ipv6DefaultRouteString, at: 0)
            }
            ranges = result
        } else {
            // routeIPv4Only - strip IPv6 default route
            ranges = modifiedIPs.filter { $0 != TunnelViewModel.PeerData.ipv6DefaultRouteString }
        }

        syncToScratchpad(peerData: peerData)
    }

    func addRange(_ range: String) -> Bool {
        guard let peerData = peerData else { return false }
        let trimmed = range.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, IPAddressRange(from: trimmed) != nil else { return false }
        ranges.append(trimmed)
        syncToScratchpad(peerData: peerData)
        return true
    }

    func removeRange(at index: Int) {
        guard let peerData = peerData else { return }
        guard index >= 0 && index < ranges.count else { return }
        ranges.remove(at: index)
        syncToScratchpad(peerData: peerData)
    }

    private func syncToScratchpad(peerData: TunnelViewModel.PeerData) {
        peerData[.allowedIPs] = ranges.joined(separator: ", ")
    }
}
