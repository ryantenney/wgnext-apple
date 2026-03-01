// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// User preferences for VPN-related notifications. Persisted in the shared app group
/// UserDefaults so both the main app and the Network Extension can read them.
struct NotificationSettings {

    private static let keyDisconnectNotifications = "notifyOnDisconnect"
    private static let keyFailoverNotifications = "notifyOnFailover"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    static var isDisconnectNotificationEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyDisconnectNotifications) ?? false }
        set { userDefaults?.set(newValue, forKey: keyDisconnectNotifications) }
    }

    static var isFailoverNotificationEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyFailoverNotifications) ?? false }
        set { userDefaults?.set(newValue, forKey: keyFailoverNotifications) }
    }
}
