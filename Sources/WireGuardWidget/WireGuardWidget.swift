// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct VPNStatusEntry: TimelineEntry {
    let date: Date
    let state: VPNStatusData.ConnectionState
    let tunnelName: String
    let connectedAt: Date?
}

// MARK: - Timeline Provider

struct VPNStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNStatusEntry {
        VPNStatusEntry(date: Date(), state: .disconnected, tunnelName: "My Tunnel", connectedAt: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNStatusEntry) -> Void) {
        let entry: VPNStatusEntry
        if context.isPreview {
            entry = VPNStatusEntry(date: Date(), state: .connected, tunnelName: "My Tunnel", connectedAt: Date().addingTimeInterval(-3600))
        } else if let status = VPNStatusData.load() {
            entry = VPNStatusEntry(date: Date(), state: status.state, tunnelName: status.tunnelName, connectedAt: status.connectedAt)
        } else {
            entry = VPNStatusEntry(date: Date(), state: .disconnected, tunnelName: "", connectedAt: nil)
        }
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNStatusEntry>) -> Void) {
        let entry: VPNStatusEntry
        if let status = VPNStatusData.load() {
            entry = VPNStatusEntry(date: Date(), state: status.state, tunnelName: status.tunnelName, connectedAt: status.connectedAt)
        } else {
            entry = VPNStatusEntry(date: Date(), state: .disconnected, tunnelName: "", connectedAt: nil)
        }
        // Refresh every 15 minutes; the app also triggers reloads on status changes.
        let nextUpdate = Date().addingTimeInterval(15 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget View

struct VPNStatusWidgetView: View {
    var entry: VPNStatusEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(.fill.tertiary, for: .widget)
        } else {
            content.padding()
        }
    }

    @ViewBuilder
    var content: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon
                Text("WireGuard")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusLabel
                .font(.headline)
            if !entry.tunnelName.isEmpty {
                Text(entry.tunnelName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if let connectedAt = entry.connectedAt, entry.state == .connected {
                Text(connectedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var mediumView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    statusIcon
                    Text("WireGuard")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusLabel
                    .font(.headline)
                if !entry.tunnelName.isEmpty {
                    Text(entry.tunnelName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let connectedAt = entry.connectedAt, entry.state == .connected {
                VStack(alignment: .trailing) {
                    Spacer()
                    Text("Connected")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(connectedAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var statusIcon: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    var statusLabel: some View {
        Text(statusText)
            .foregroundColor(statusColor)
    }

    var statusText: String {
        switch entry.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .disconnecting: return "Disconnecting..."
        }
    }

    var statusColor: Color {
        switch entry.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .disconnecting: return .orange
        }
    }
}

// MARK: - Widget Configuration

@main
struct WireGuardStatusWidget: Widget {
    let kind: String = "WireGuardStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VPNStatusProvider()) { entry in
            VPNStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("VPN Status")
        .description("Shows current WireGuard VPN connection status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
