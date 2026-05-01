// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Tracks tunnels whose `isOnDemandEnabled` was temporarily turned off so that
/// another tunnel could be activated as a manual override. When no tunnel is
/// active, `TunnelsManager` re-enables on-demand on each suspended tunnel.
///
/// Persisted in the shared app-group `UserDefaults` so that a suspension
/// survives app restart, extension restart, and device reboot. See
/// `DESIGN-multiple-on-demand-tunnels.md` for the lifecycle.
enum OnDemandSuspensionStore {

    private static let key = "suspendedOnDemandTunnelNames"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    static var suspendedTunnelNames: [String] {
        return userDefaults?.stringArray(forKey: key) ?? []
    }

    static var hasSuspensions: Bool {
        return !suspendedTunnelNames.isEmpty
    }

    static func add(_ tunnelName: String) {
        guard let userDefaults = userDefaults else { return }
        var names = userDefaults.stringArray(forKey: key) ?? []
        guard !names.contains(tunnelName) else { return }
        names.append(tunnelName)
        userDefaults.set(names, forKey: key)
    }

    static func remove(_ tunnelName: String) {
        guard let userDefaults = userDefaults else { return }
        var names = userDefaults.stringArray(forKey: key) ?? []
        guard let index = names.firstIndex(of: tunnelName) else { return }
        names.remove(at: index)
        if names.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(names, forKey: key)
        }
    }

    static func handleTunnelRenamed(from oldName: String, to newName: String) {
        guard let userDefaults = userDefaults else { return }
        var names = userDefaults.stringArray(forKey: key) ?? []
        guard let index = names.firstIndex(of: oldName) else { return }
        names[index] = newName
        userDefaults.set(names, forKey: key)
    }

    /// Drop suspension records that don't correspond to any currently known
    /// tunnel. Called after the manager loads tunnel state to recover from
    /// crashes that may have left orphaned entries.
    static func cleanup(except tunnelNamesToKeep: Set<String>) {
        guard let userDefaults = userDefaults else { return }
        let names = userDefaults.stringArray(forKey: key) ?? []
        let filtered = names.filter { tunnelNamesToKeep.contains($0) }
        if filtered.count == names.count {
            return
        }
        if filtered.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(filtered, forKey: key)
        }
    }
}
