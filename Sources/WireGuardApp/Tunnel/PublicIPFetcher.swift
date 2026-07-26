// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Discovers the device's public IPv4 address after tunnel state changes.
/// Requests ride the active tunnel, so the result reflects the VPN exit
/// address. Extracted from TunnelsManager, which is an orchestrator, not an
/// HTTP client.
enum PublicIPFetcher {

    /// Plain-text IPv4 echo service used for discovery.
    static let discoveryURL = URL(string: "https://ipv4.icanhazip.com")!

    /// Fetch and store the public IP if IP discovery is enabled. Delays
    /// slightly to let the tunnel settle before fetching.
    static func fetchIfEnabled() {
        guard IPDiscoverySettings.isEnabled else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            var request = URLRequest(url: discoveryURL)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let task = URLSession.shared.dataTask(with: request) { data, _, error in
                if let error = error {
                    wg_log(.error, message: "IP discovery failed: \(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !ip.isEmpty else { return }
                IPDiscoverySettings.discoveredIP = ip
                wg_log(.info, message: "IP discovery: \(ip)")
            }
            task.resume()
        }
    }

    static func clearDiscoveredIP() {
        IPDiscoverySettings.discoveredIP = nil
    }
}
