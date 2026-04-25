// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Persists per-VPN-session records to JSON files in the App Group shared container.
///
/// Two files are used:
///   - `session-history.json` — array of completed `SessionRecord`s, capped at `maxRecords`.
///   - `current-session.json` — the in-progress session, rewritten atomically by the extension.
///
/// The Network Extension is the sole writer; the main app is the sole reader (plus orphan recovery).
enum SessionHistoryStore {

    static let maxRecords = 500
    private static let historyFileName = "session-history.json"
    private static let currentFileName = "current-session.json"

    private static var sharedFolderURL: URL? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var historyURL: URL? {
        sharedFolderURL?.appendingPathComponent(historyFileName)
    }

    private static var currentURL: URL? {
        sharedFolderURL?.appendingPathComponent(currentFileName)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Writers

    /// Persists the in-progress session record. Called from the extension on every relevant change.
    static func saveCurrent(_ record: SessionRecord) {
        guard let url = currentURL else { return }
        do {
            let data = try makeEncoder().encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "SessionHistory: failed to save current session: \(error)")
        }
    }

    /// Removes the in-progress session file (called after appendCompleted).
    static func clearCurrent() {
        guard let url = currentURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Appends a completed record to the history archive, pruning to `maxRecords`.
    static func appendCompleted(_ record: SessionRecord) {
        guard let url = historyURL else { return }
        var records = loadAllRaw()
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        do {
            let data = try makeEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "SessionHistory: failed to append completed session: \(error)")
        }
    }

    // MARK: - Readers

    /// Returns all completed sessions, newest first.
    static func loadAll() -> [SessionRecord] {
        return loadAllRaw().reversed()
    }

    /// Returns the in-progress session, if any.
    static func loadCurrent() -> SessionRecord? {
        guard let url = currentURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(SessionRecord.self, from: data)
    }

    /// Internal helper: returns records in stored (chronological) order.
    private static func loadAllRaw() -> [SessionRecord] {
        guard let url = historyURL else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? makeDecoder().decode([SessionRecord].self, from: data)) ?? []
    }

    // MARK: - Lifecycle

    /// Deletes both the history archive and any in-progress current session file.
    static func clear() {
        if let url = historyURL { try? FileManager.default.removeItem(at: url) }
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
    }

    /// If a `current-session.json` exists, finalize it as `endedUnexpectedly` and append to history.
    /// Safe to call from the app process at launch. Caller is responsible for ensuring no tunnel is
    /// currently connecting/connected when invoked (otherwise we may finalize a still-running session).
    static func recoverOrphanedCurrent() {
        guard var record = loadCurrent() else { return }
        record.endedAt = Date()
        record.deactivationReason = .endedUnexpectedly
        appendCompleted(record)
        clearCurrent()
    }
}
