// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

/// A tunnel-in-tunnel (TiT) group pairs an OUTER WireGuard config (Server A) with an INNER
/// WireGuard config (Server B).  User traffic travels:
///   device → INNER wg-go (utun) → PipedBind → OUTER wg-go (virtual TUN) → Server A → Server B → Internet
struct TunnelInTunnelGroup: Codable, Equatable {
    var id: UUID
    /// Display name shown in the app.
    var name: String
    /// Name of the tunnel configuration that acts as the OUTER tunnel (Server A).
    var outerTunnelName: String
    /// Name of the tunnel configuration that acts as the INNER tunnel (Server B).
    var innerTunnelName: String
    /// Optional on-demand settings (same model as failover groups).
    var onDemandActivation: OnDemandActivation

    enum CodingKeys: String, CodingKey {
        case id, name, outerTunnelName, innerTunnelName, onDemandActivation
    }

    init(name: String, outerTunnelName: String, innerTunnelName: String,
         onDemandActivation: OnDemandActivation = OnDemandActivation()) {
        self.id = UUID()
        self.name = name
        self.outerTunnelName = outerTunnelName
        self.innerTunnelName = innerTunnelName
        self.onDemandActivation = onDemandActivation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        outerTunnelName = try c.decode(String.self, forKey: .outerTunnelName)
        innerTunnelName = try c.decode(String.self, forKey: .innerTunnelName)
        onDemandActivation = try c.decodeIfPresent(OnDemandActivation.self, forKey: .onDemandActivation) ?? OnDemandActivation()
    }
}

/// providerConfiguration keys used when storing a TiT session in an NETunnelProviderManager.
enum TunnelInTunnelConfigKeys {
    static let groupId     = "TiTGroupId"
    static let outerConfig = "TiTOuterConfig"
    static let innerConfig = "TiTInnerConfig"
    static let outerName   = "TiTOuterName"
    static let innerName   = "TiTInnerName"
}

/// Manages persistence and retrieval of TiT groups.
class TunnelInTunnelGroupManager {

    private static let fileName = "tit-groups.json"

    private static var fileURL: URL? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        guard let sharedFolder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        return sharedFolder.appendingPathComponent(fileName)
    }

    static func loadGroups() -> [TunnelInTunnelGroup] {
        guard let url = fileURL else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TunnelInTunnelGroup].self, from: data)) ?? []
    }

    static func saveGroups(_ groups: [TunnelInTunnelGroup]) {
        guard let url = fileURL else {
            wg_log(.error, staticMessage: "TiT: cannot determine shared folder for saving groups")
            return
        }
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "TiT: failed to save groups: \(error)")
        }
    }

    static func addGroup(_ group: TunnelInTunnelGroup) {
        var groups = loadGroups()
        groups.append(group)
        saveGroups(groups)
    }

    static func updateGroup(_ group: TunnelInTunnelGroup) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        }
        saveGroups(groups)
    }

    static func removeGroup(withId id: UUID) {
        var groups = loadGroups()
        groups.removeAll { $0.id == id }
        saveGroups(groups)
    }

    static func group(withId id: UUID) -> TunnelInTunnelGroup? {
        loadGroups().first { $0.id == id }
    }

    /// Remove groups that reference tunnels that no longer exist.
    static func cleanupGroups(existingTunnelNames: Set<String>) {
        let groups = loadGroups().filter {
            existingTunnelNames.contains($0.outerTunnelName) &&
            existingTunnelNames.contains($0.innerTunnelName)
        }
        saveGroups(groups)
    }
}

// MARK: - NETunnelProviderManager helpers

extension TunnelInTunnelGroup {

    /// Builds the providerConfiguration dictionary for an NETunnelProviderManager from two wg-quick config strings.
    static func makeProviderConfiguration(
        groupId: String,
        outerWgQuick: String, outerName: String,
        innerWgQuick: String, innerName: String
    ) -> [String: Any] {
        return [
            TunnelInTunnelConfigKeys.groupId:     groupId,
            TunnelInTunnelConfigKeys.outerConfig: outerWgQuick,
            TunnelInTunnelConfigKeys.innerConfig: innerWgQuick,
            TunnelInTunnelConfigKeys.outerName:   outerName,
            TunnelInTunnelConfigKeys.innerName:   innerName
        ]
    }
}
