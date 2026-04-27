// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndexer {
    private static let itemIdentifier = "app"
    private static let domainIdentifier = "app.wgnext.spotlight"
    private static let indexedVersionKey = "SpotlightIndexedVersion"

    static func indexAppIfNeeded() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard UserDefaults.standard.string(forKey: indexedVersionKey) != version else { return }

        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        attributes.keywords = ["wireguard", "wire guard", "vpn", "wg-quick", "wg", "tunnel"]

        let item = CSSearchableItem(uniqueIdentifier: itemIdentifier,
                                    domainIdentifier: domainIdentifier,
                                    attributeSet: attributes)

        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                wg_log(.error, message: "Spotlight indexing failed: \(error.localizedDescription)")
            } else {
                UserDefaults.standard.set(version, forKey: indexedVersionKey)
            }
        }
    }
}
