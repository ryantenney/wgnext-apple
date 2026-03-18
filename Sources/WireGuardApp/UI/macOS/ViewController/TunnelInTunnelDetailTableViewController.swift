// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

class TunnelInTunnelDetailTableViewController: NSViewController {

    private enum TableViewModelRow {
        case nameRow
        case statusRow
        case toggleStatusRow
        case tunnelRow(name: String, role: String)
        case statRow(label: String, value: String, isHeader: Bool)
        case onDemandRow
        case onDemandSSIDRow
        case spacerRow
    }

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TiTDetail")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        return tableView
    }()

    let editButton: NSButton = {
        let button = NSButton()
        button.title = tr("macButtonEdit")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.toolTip = tr("macToolTipEditTunnel")
        return button
    }()

    let box: NSBox = {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.fillColor = .unemphasizedSelectedContentBackgroundColor
        return box
    }()

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer

    private var outerTunnelName: String = ""
    private var innerTunnelName: String = ""
    private var onDemandViewModel: ActivateOnDemandViewModel

    private var tableViewModelRows = [TableViewModelRow]()

    private var statusObservationToken: AnyObject?
    private var titEditVC: TunnelInTunnelEditViewController?

    // Runtime stats
    private var titState: [String: Any]?
    private var statsTimer: Timer?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(nibName: nil, bundle: nil)
        loadGroupData()
        rebuildTableViewModelRows()
        statusObservationToken = tunnel.observe(\TunnelContainer.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .active {
                self.startPollingStats()
            } else if tunnel.status == .inactive {
                self.stopPollingStats()
                self.titState = nil
                self.rebuildTableViewModelRows()
                self.tableView.reloadData()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self

        editButton.target = self
        editButton.action = #selector(handleEditAction)

        let clipView = NSClipView()
        clipView.documentView = tableView

        let scrollView = NSScrollView()
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let containerView = NSView()
        let bottomControlsContainer = NSLayoutGuide()
        containerView.addLayoutGuide(bottomControlsContainer)
        containerView.addSubview(box)
        containerView.addSubview(scrollView)
        containerView.addSubview(editButton)
        box.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        editButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            containerView.leadingAnchor.constraint(equalTo: bottomControlsContainer.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.heightAnchor.constraint(equalToConstant: 32),
            scrollView.bottomAnchor.constraint(equalTo: bottomControlsContainer.topAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            editButton.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: editButton.bottomAnchor, constant: 0)
        ])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: box.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        view = containerView
    }

    override func viewWillAppear() {
        if tunnel.status == .active {
            startPollingStats()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let titEditVC = titEditVC {
            dismiss(titEditVC)
        }
        stopPollingStats()
    }

    private func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        outerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.outerName] as? String) ?? ""
        innerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.innerName] as? String) ?? ""
    }

    private func rebuildTableViewModelRows() {
        var rows = [TableViewModelRow]()

        rows.append(.nameRow)
        rows.append(.statusRow)
        rows.append(.toggleStatusRow)
        rows.append(.spacerRow)

        rows.append(.tunnelRow(name: outerTunnelName, role: "Outer (Server A)"))
        rows.append(.tunnelRow(name: innerTunnelName, role: "Inner (Server B)"))
        rows.append(.spacerRow)

        // Stats (when active)
        if tunnel.status == .active, let state = titState {
            appendStatRows(for: "outer", label: "Outer Tunnel (\(outerTunnelName))", state: state, rows: &rows)
            appendStatRows(for: "inner", label: "Inner Tunnel (\(innerTunnelName))", state: state, rows: &rows)
        }

        rows.append(.onDemandRow)
        if onDemandViewModel.isWiFiInterfaceEnabled {
            rows.append(.onDemandSSIDRow)
        }

        tableViewModelRows = rows
    }

    private func appendStatRows(for prefix: String, label: String, state: [String: Any], rows: inout [TableViewModelRow]) {
        var statRows = [TableViewModelRow]()
        if let rx = state["\(prefix)RxBytes"] as? UInt64, rx > 0 {
            statRows.append(.statRow(label: tr("tunnelPeerRxBytes"), value: prettyBytes(rx), isHeader: false))
        }
        if let tx = state["\(prefix)TxBytes"] as? UInt64, tx > 0 {
            statRows.append(.statRow(label: tr("tunnelPeerTxBytes"), value: prettyBytes(tx), isHeader: false))
        }
        if let timestamp = state["\(prefix)LastHandshakeTime"] as? Double {
            statRows.append(.statRow(label: tr("tunnelPeerLastHandshakeTime"), value: prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp)), isHeader: false))
        }
        if !statRows.isEmpty {
            rows.append(.statRow(label: label, value: "", isHeader: true))
            rows.append(contentsOf: statRows)
            rows.append(.spacerRow)
        }
    }

    // MARK: - Stats Polling

    private func startPollingStats() {
        pollStats()
        stopPollingStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    private func stopPollingStats() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        tunnelsManager.getTiTState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.titState = state
                self.rebuildTableViewModelRows()
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Formatting

    private func prettyBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1024:
            return "\(bytes) B"
        case 1024..<(1024 * 1024):
            return String(format: "%.2f", Double(bytes) / 1024) + " KiB"
        case (1024 * 1024)..<(1024 * 1024 * 1024):
            return String(format: "%.2f", Double(bytes) / (1024 * 1024)) + " MiB"
        case (1024 * 1024 * 1024)..<(1024 * 1024 * 1024 * 1024):
            return String(format: "%.2f", Double(bytes) / (1024 * 1024 * 1024)) + " GiB"
        default:
            return String(format: "%.2f", Double(bytes) / (1024 * 1024 * 1024 * 1024)) + " TiB"
        }
    }

    private func prettyTimeAgo(since date: Date) -> String {
        let seconds = Int64(Date().timeIntervalSince(date))
        guard seconds >= 0 else { return "the future" }
        if seconds == 0 { return "now" }

        var parts = [String]()
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }

        return parts.prefix(2).joined(separator: ", ") + " ago"
    }

    // MARK: - Actions

    @objc func handleEditAction() {
        let editVC = TunnelInTunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
        editVC.delegate = self
        presentAsSheet(editVC)
        self.titEditVC = editVC
    }

    @objc func handleToggleActiveStatusAction() {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            tunnelsManager.setOnDemandEnabled(turnOn, on: tunnel) { error in
                if error == nil && !turnOn {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        } else {
            if tunnel.status == .inactive {
                tunnelsManager.startActivation(of: tunnel)
            } else if tunnel.status == .active {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        }
    }

    // MARK: - Status helpers

    private static func localizedStatusDescription(for tunnel: TunnelContainer) -> String {
        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

        var text: String
        switch status {
        case .inactive: text = tr("tunnelStatusInactive")
        case .activating: text = tr("tunnelStatusActivating")
        case .active: text = tr("tunnelStatusActive")
        case .deactivating: text = tr("tunnelStatusDeactivating")
        case .reasserting: text = tr("tunnelStatusReasserting")
        case .restarting: text = tr("tunnelStatusRestarting")
        case .waiting: text = tr("tunnelStatusWaiting")
        }

        if tunnel.hasOnDemandRules {
            text += isOnDemandEngaged ?
                tr("tunnelStatusAddendumOnDemandEnabled") : tr("tunnelStatusAddendumOnDemandDisabled")
        }

        return text
    }

    private static func localizedToggleStatusActionText(for tunnel: TunnelContainer) -> String {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            if turnOn {
                return tr("macToggleStatusButtonEnableOnDemand")
            } else {
                if tunnel.status == .active {
                    return tr("macToggleStatusButtonDisableOnDemandDeactivate")
                } else {
                    return tr("macToggleStatusButtonDisableOnDemand")
                }
            }
        } else {
            switch tunnel.status {
            case .waiting: return tr("macToggleStatusButtonWaiting")
            case .inactive: return tr("macToggleStatusButtonActivate")
            case .activating: return tr("macToggleStatusButtonActivating")
            case .active: return tr("macToggleStatusButtonDeactivate")
            case .deactivating: return tr("macToggleStatusButtonDeactivating")
            case .reasserting: return tr("macToggleStatusButtonReasserting")
            case .restarting: return tr("macToggleStatusButtonRestarting")
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension TunnelInTunnelDetailTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableViewModelRows.count
    }
}

// MARK: - NSTableViewDelegate

extension TunnelInTunnelDetailTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let modelRow = tableViewModelRows[row]
        switch modelRow {
        case .nameRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceName"))
            cell.value = tunnel.name
            cell.isKeyInBold = true
            return cell

        case .statusRow:
            let cell: KeyValueImageRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceStatus"))
            cell.value = TunnelInTunnelDetailTableViewController.localizedStatusDescription(for: tunnel)
            cell.valueImage = TunnelListRow.image(for: tunnel)
            let changeHandler: (TunnelContainer, Any) -> Void = { [weak cell] tunnel, _ in
                guard let cell = cell else { return }
                cell.value = TunnelInTunnelDetailTableViewController.localizedStatusDescription(for: tunnel)
                cell.valueImage = TunnelListRow.image(for: tunnel)
            }
            cell.statusObservationToken = tunnel.observe(\.status, changeHandler: changeHandler)
            cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled, changeHandler: changeHandler)
            cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules, changeHandler: changeHandler)
            return cell

        case .toggleStatusRow:
            let cell: ButtonRow = tableView.dequeueReusableCell()
            cell.buttonTitle = TunnelInTunnelDetailTableViewController.localizedToggleStatusActionText(for: tunnel)
            cell.isButtonEnabled = (tunnel.hasOnDemandRules || tunnel.status == .active || tunnel.status == .inactive)
            cell.buttonToolTip = tr("macToolTipToggleStatus")
            cell.onButtonClicked = { [weak self] in
                self?.handleToggleActiveStatusAction()
            }
            let changeHandler: (TunnelContainer, Any) -> Void = { [weak cell] tunnel, _ in
                guard let cell = cell else { return }
                cell.buttonTitle = TunnelInTunnelDetailTableViewController.localizedToggleStatusActionText(for: tunnel)
                cell.isButtonEnabled = (tunnel.hasOnDemandRules || tunnel.status == .active || tunnel.status == .inactive)
            }
            cell.statusObservationToken = tunnel.observe(\.status, changeHandler: changeHandler)
            cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled, changeHandler: changeHandler)
            cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules, changeHandler: changeHandler)
            return cell

        case .tunnelRow(let name, let role):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", name)
            cell.value = role
            cell.isKeyInBold = false
            return cell

        case .statRow(let label, let value, let isHeader):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", label)
            cell.value = value
            cell.isKeyInBold = isHeader
            return cell

        case .onDemandRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemand")
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.isKeyInBold = true
            return cell

        case .onDemandSSIDRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemandSSIDs")
            let value: String
            if onDemandViewModel.ssidOption == .anySSID {
                value = onDemandViewModel.ssidOption.localizedUIString
            } else {
                value = tr(format: "tunnelOnDemandSSIDOptionDescriptionMac (%1$@: %2$@)",
                           onDemandViewModel.ssidOption.localizedUIString,
                           onDemandViewModel.selectedSSIDs.joined(separator: ", "))
            }
            cell.value = value
            cell.isKeyInBold = false
            return cell

        case .spacerRow:
            return NSView()
        }
    }
}

// MARK: - TunnelInTunnelEditViewControllerDelegate

extension TunnelInTunnelDetailTableViewController: TunnelInTunnelEditViewControllerDelegate {
    func titGroupSaved(tunnel: TunnelContainer) {
        loadGroupData()
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        rebuildTableViewModelRows()
        tableView.reloadData()
        self.titEditVC = nil
    }

    func titGroupEditingCancelled() {
        self.titEditVC = nil
    }
}
