// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation

enum ZipExporterError: WireGuardAppError {
    case noTunnelsToExport

    var alertText: AlertText {
        return (tr("alertNoTunnelsToExportTitle"), tr("alertNoTunnelsToExportMessage"))
    }
}

class ZipExporter {
    static func exportConfigFiles(tunnelConfigurations: [TunnelConfiguration],
                                   failoverGroups: [(name: String, config: String)] = [],
                                   tunnelInTunnelGroups: [(name: String, config: String)] = [],
                                   to url: URL,
                                   completion: @escaping (WireGuardAppError?) -> Void) {

        guard !tunnelConfigurations.isEmpty else {
            completion(ZipExporterError.noTunnelsToExport)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var inputsToArchiver: [(fileName: String, contents: Data)] = []
            var lastTunnelName: String = ""
            for tunnelConfiguration in tunnelConfigurations {
                if let contents = tunnelConfiguration.asWgQuickConfig().data(using: .utf8) {
                    let name = tunnelConfiguration.name ?? "untitled"
                    if name.isEmpty || name == lastTunnelName { continue }
                    inputsToArchiver.append((fileName: "\(name).conf", contents: contents))
                    lastTunnelName = name
                }
            }
            for group in failoverGroups {
                if let contents = group.config.data(using: .utf8) {
                    inputsToArchiver.append((fileName: "\(group.name).failovergroup.conf", contents: contents))
                }
            }
            for group in tunnelInTunnelGroups {
                if let contents = group.config.data(using: .utf8) {
                    inputsToArchiver.append((fileName: "\(group.name).tunnelintunnel.conf", contents: contents))
                }
            }
            do {
                try ZipArchive.archive(inputs: inputsToArchiver, to: url)
            } catch let error as WireGuardAppError {
                DispatchQueue.main.async { completion(error) }
                return
            } catch {
                fatalError()
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }
}
