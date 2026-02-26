// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// A group of tunnel configurations with automatic failover between them.
/// The first tunnel is primary; subsequent tunnels are fallbacks in priority order.
struct FailoverGroup: Codable, Equatable {
    var id: UUID
    var name: String
    var tunnelNames: [String]
    var settings: FailoverSettings

    init(name: String, tunnelNames: [String], settings: FailoverSettings = FailoverSettings()) {
        self.id = UUID()
        self.name = name
        self.tunnelNames = tunnelNames
        self.settings = settings
    }
}

/// Manages persistence and retrieval of failover groups.
class FailoverGroupManager {

    private static let fileName = "failover-groups.json"

    private static var fileURL: URL? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        guard let sharedFolder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        return sharedFolder.appendingPathComponent(fileName)
    }

    static func loadGroups() -> [FailoverGroup] {
        guard let url = fileURL else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FailoverGroup].self, from: data)) ?? []
    }

    static func saveGroups(_ groups: [FailoverGroup]) {
        guard let url = fileURL else {
            wg_log(.error, staticMessage: "Failover: cannot determine shared folder for saving groups")
            return
        }
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "Failover: failed to save groups: \(error)")
        }
    }

    static func addGroup(_ group: FailoverGroup) {
        var groups = loadGroups()
        groups.append(group)
        saveGroups(groups)
    }

    static func updateGroup(_ group: FailoverGroup) {
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

    static func group(withId id: UUID) -> FailoverGroup? {
        return loadGroups().first { $0.id == id }
    }

    /// Clean up groups that reference tunnels that no longer exist.
    static func cleanupGroups(existingTunnelNames: Set<String>) {
        var groups = loadGroups()
        var modified = false
        for i in groups.indices {
            let filtered = groups[i].tunnelNames.filter { existingTunnelNames.contains($0) }
            if filtered != groups[i].tunnelNames {
                groups[i].tunnelNames = filtered
                modified = true
            }
        }
        // Remove groups with fewer than 2 tunnels (failover needs at least 2)
        let before = groups.count
        groups.removeAll { $0.tunnelNames.count < 2 }
        if modified || groups.count != before {
            saveGroups(groups)
        }
    }
}
