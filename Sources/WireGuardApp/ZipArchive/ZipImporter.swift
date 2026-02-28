// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation

struct ZipImportResult {
    var tunnelConfigurations: [TunnelConfiguration?]
    var failoverGroups: [FailoverGroupConfig]
}

class ZipImporter {
    static func importConfigFiles(from url: URL, completion: @escaping (Result<ZipImportResult, ZipArchiveError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var unarchivedFiles: [(fileBaseName: String, contents: Data)]
            do {
                unarchivedFiles = try ZipArchive.unarchive(url: url, requiredFileExtensions: ["conf"])
                for (index, unarchivedFile) in unarchivedFiles.enumerated().reversed() {
                    let fileBaseName = unarchivedFile.fileBaseName
                    let trimmedName = fileBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty {
                        unarchivedFiles[index].fileBaseName = trimmedName
                    } else {
                        unarchivedFiles.remove(at: index)
                    }
                }

                if unarchivedFiles.isEmpty {
                    throw ZipArchiveError.noTunnelsInZipArchive
                }
            } catch let error as ZipArchiveError {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            } catch {
                fatalError()
            }

            // Separate failover group configs from regular tunnel configs
            let failoverGroupSuffix = ".failovergroup"
            var tunnelFiles = [(fileBaseName: String, contents: Data)]()
            var failoverGroupFiles = [(name: String, contents: Data)]()

            for file in unarchivedFiles {
                if file.fileBaseName.lowercased().hasSuffix(failoverGroupSuffix) {
                    let groupName = String(file.fileBaseName.dropLast(failoverGroupSuffix.count))
                    if !groupName.isEmpty {
                        failoverGroupFiles.append((name: groupName, contents: file.contents))
                    }
                } else {
                    tunnelFiles.append(file)
                }
            }

            // Parse tunnel configs
            tunnelFiles.sort { TunnelsManager.tunnelNameIsLessThan($0.fileBaseName, $1.fileBaseName) }
            var configs: [TunnelConfiguration?] = Array(repeating: nil, count: tunnelFiles.count)
            for (index, file) in tunnelFiles.enumerated() {
                if index > 0 && file == tunnelFiles[index - 1] {
                    continue
                }
                guard let fileContents = String(data: file.contents, encoding: .utf8) else { continue }
                guard let tunnelConfig = try? TunnelConfiguration(fromWgQuickConfig: fileContents, called: file.fileBaseName) else { continue }
                configs[index] = tunnelConfig
            }

            // Parse failover group configs
            var failoverGroups = [FailoverGroupConfig]()
            for file in failoverGroupFiles {
                guard let fileContents = String(data: file.contents, encoding: .utf8) else { continue }
                guard let groupConfig = try? FailoverGroupConfig(from: fileContents, called: file.name) else { continue }
                failoverGroups.append(groupConfig)
            }

            let result = ZipImportResult(tunnelConfigurations: configs, failoverGroups: failoverGroups)
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }
}
