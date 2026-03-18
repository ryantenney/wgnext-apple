// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

protocol TunnelInTunnelEditDelegate: AnyObject {
    func titGroupSaved(_ tunnel: TunnelContainer)
    func titGroupDeleted(_ tunnel: TunnelContainer)
}

class TunnelInTunnelDetailTableViewController: UITableViewController {

    private enum Section {
        case status
        case tunnels
        case outerStats
        case innerStats
        case onDemand
        case delete
    }

    private enum StatField {
        case dataReceived
        case dataSent
        case lastHandshake

        var localizedUIString: String {
            switch self {
            case .dataReceived: return tr("tunnelPeerRxBytes")
            case .dataSent: return tr("tunnelPeerTxBytes")
            case .lastHandshake: return tr("tunnelPeerLastHandshakeTime")
            }
        }
    }

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer

    private var outerTunnelName: String = ""
    private var innerTunnelName: String = ""
    private var onDemandViewModel: ActivateOnDemandViewModel

    private var sections = [Section]()

    private var statusObservationToken: AnyObject?
    private var onDemandObservationToken: AnyObject?

    // Runtime stats
    private var titState: [String: Any]?
    private var statsTimer: Timer?
    private var visibleOuterStatFields: [StatField] = []
    private var visibleInnerStatFields: [StatField] = []

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)
        loadGroupData()
        loadSections()
        statusObservationToken = tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .active {
                self.startPollingStats()
            } else if tunnel.status == .inactive {
                self.stopPollingStats()
                self.titState = nil
                self.visibleOuterStatFields = []
                self.visibleInnerStatFields = []
                self.loadSections()
                self.tableView.reloadData()
            }
        }
        onDemandObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self] tunnel, _ in
            self?.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
            self?.updateActivateOnDemandFields()
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnel.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(ChevronCell.self)

        restorationIdentifier = "TiTDetailVC:\(tunnel.name)"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tunnel.status == .active {
            startPollingStats()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPollingStats()
    }

    private func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        outerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.outerName] as? String) ?? ""
        innerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.innerName] as? String) ?? ""
    }

    private func loadSections() {
        var s: [Section] = [.status, .tunnels]
        if tunnel.status == .active && !visibleOuterStatFields.isEmpty {
            s.append(.outerStats)
        }
        if tunnel.status == .active && !visibleInnerStatFields.isEmpty {
            s.append(.innerStats)
        }
        s.append(contentsOf: [.onDemand, .delete])
        sections = s
    }

    @objc func editTapped() {
        let editVC = TunnelInTunnelEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: tunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
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
                let newOuterFields = self.computeVisibleStatFields(prefix: "outer", from: state)
                let newInnerFields = self.computeVisibleStatFields(prefix: "inner", from: state)
                let hadOuterSection = self.sections.contains(.outerStats)
                let hadInnerSection = self.sections.contains(.innerStats)
                self.visibleOuterStatFields = newOuterFields
                self.visibleInnerStatFields = newInnerFields
                self.loadSections()

                let needsOuterSection = !newOuterFields.isEmpty && self.tunnel.status == .active
                let needsInnerSection = !newInnerFields.isEmpty && self.tunnel.status == .active

                if hadOuterSection != needsOuterSection || hadInnerSection != needsInnerSection {
                    self.tableView.reloadData()
                } else {
                    var reloadSet = IndexSet()
                    if needsOuterSection, let idx = self.sections.firstIndex(of: .outerStats) {
                        reloadSet.insert(idx)
                    }
                    if needsInnerSection, let idx = self.sections.firstIndex(of: .innerStats) {
                        reloadSet.insert(idx)
                    }
                    if !reloadSet.isEmpty {
                        self.tableView.reloadSections(reloadSet, with: .none)
                    }
                }
            }
        }
    }

    private func computeVisibleStatFields(prefix: String, from state: [String: Any]) -> [StatField] {
        var fields = [StatField]()
        if let rx = state["\(prefix)RxBytes"] as? UInt64, rx > 0 {
            fields.append(.dataReceived)
        }
        if let tx = state["\(prefix)TxBytes"] as? UInt64, tx > 0 {
            fields.append(.dataSent)
        }
        if state["\(prefix)LastHandshakeTime"] as? Double != nil {
            fields.append(.lastHandshake)
        }
        return fields
    }

    private func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(of: .onDemand) else { return }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }

    // MARK: - Formatting Helpers

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

    private func statValue(for field: StatField, prefix: String) -> String {
        guard let state = titState else { return "" }
        switch field {
        case .dataReceived:
            if let rx = state["\(prefix)RxBytes"] as? UInt64 { return prettyBytes(rx) }
            return ""
        case .dataSent:
            if let tx = state["\(prefix)TxBytes"] as? UInt64 { return prettyBytes(tx) }
            return ""
        case .lastHandshake:
            if let timestamp = state["\(prefix)LastHandshakeTime"] as? Double {
                return prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""
        }
    }
}

// MARK: - TunnelInTunnelEditDelegate

extension TunnelInTunnelDetailTableViewController: TunnelInTunnelEditDelegate {
    func titGroupSaved(_ tunnel: TunnelContainer) {
        loadGroupData()
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        title = tunnel.name
        restorationIdentifier = "TiTDetailVC:\(tunnel.name)"
        tableView.reloadData()
    }

    func titGroupDeleted(_ tunnel: TunnelContainer) {
        // Navigation cleanup handled by TunnelsListTableViewController
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension TunnelInTunnelDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status:
            return 1
        case .tunnels:
            return 2
        case .outerStats:
            return visibleOuterStatFields.count
        case .innerStats:
            return visibleInnerStatFields.count
        case .onDemand:
            return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        case .delete:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status:
            return tr("tunnelSectionTitleStatus")
        case .tunnels:
            return "Tunnel Chain"
        case .outerStats:
            return "Outer Tunnel (\(outerTunnelName))"
        case .innerStats:
            return "Inner Tunnel (\(innerTunnelName))"
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        case .delete:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell(for: tableView, at: indexPath)
        case .tunnels:
            return tunnelCell(for: tableView, at: indexPath)
        case .outerStats:
            return statCell(for: tableView, field: visibleOuterStatFields[indexPath.row], prefix: "outer")
        case .innerStats:
            return statCell(for: tableView, field: visibleInnerStatFields[indexPath.row], prefix: "inner")
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        case .delete:
            return deleteCell(for: tableView, at: indexPath)
        }
    }

    private func statusCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)

        func update(cell: SwitchCell?, with tunnel: TunnelContainer) {
            guard let cell = cell else { return }

            let status = tunnel.status
            let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

            let isSwitchOn = (status == .activating || status == .active || isOnDemandEngaged)
            cell.switchView.setOn(isSwitchOn, animated: true)

            if isOnDemandEngaged && !(status == .activating || status == .active) {
                cell.switchView.onTintColor = UIColor.systemYellow
            } else {
                cell.switchView.onTintColor = UIColor.systemGreen
            }

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
                text += isOnDemandEngaged ? tr("tunnelStatusAddendumOnDemand") : ""
                cell.switchView.isUserInteractionEnabled = true
                cell.isEnabled = true
            } else {
                cell.switchView.isUserInteractionEnabled = (status == .inactive || status == .active)
                cell.isEnabled = (status == .inactive || status == .active)
            }

            if tunnel.hasOnDemandRules && !isOnDemandEngaged && status == .inactive {
                text = tr("tunnelStatusOnDemandDisabled")
            }

            cell.textLabel?.text = text
        }

        update(cell: cell, with: tunnel)
        cell.statusObservationToken = tunnel.observe(\.status) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }

        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }
            if self.tunnel.hasOnDemandRules {
                self.tunnelsManager.setOnDemandEnabled(isOn, on: self.tunnel) { error in
                    if error == nil && !isOn {
                        self.tunnelsManager.startDeactivation(of: self.tunnel)
                    }
                }
            } else {
                if isOn {
                    self.tunnelsManager.startActivation(of: self.tunnel)
                } else {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        }
        return cell
    }

    private func tunnelCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        if indexPath.row == 0 {
            cell.key = outerTunnelName
            cell.value = "Outer (Server A)"
        } else {
            cell.key = innerTunnelName
            cell.value = "Inner (Server B)"
        }
        cell.copyableGesture = false
        return cell
    }

    private func statCell(for tableView: UITableView, field: StatField, prefix: String) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: IndexPath(row: 0, section: 0))
        cell.key = field.localizedUIString
        cell.value = statValue(for: field, prefix: prefix)
        cell.copyableGesture = false
        return cell
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = TunnelInTunnelDetailTableViewController.onDemandFields[indexPath.row]
        if field == .onDemand {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.key = field.localizedUIString
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.copyableGesture = false
            return cell
        } else {
            assert(field == .ssid)
            if onDemandViewModel.ssidOption == .anySSID {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.key = field.localizedUIString
                cell.value = onDemandViewModel.ssidOption.localizedUIString
                cell.copyableGesture = false
                return cell
            } else {
                let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = field.localizedUIString
                cell.detailMessage = onDemandViewModel.localizedSSIDDescription
                return cell
            }
        }
    }

    private func deleteCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = "Delete Tunnel-in-Tunnel Group"
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(
                title: "Delete Tunnel-in-Tunnel Group",
                message: "Are you sure you want to delete '\(self.tunnel.name)'? This won't delete the individual tunnels.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.tunnelsManager.removeTiTGroup(tunnel: self.tunnel) { error in
                    if error != nil {
                        print("Error removing TiT group: \(String(describing: error))")
                    }
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
        return cell
    }
}

// MARK: - Row Selection

extension TunnelInTunnelDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .onDemand = sections[indexPath.section],
           case .ssid = TunnelInTunnelDetailTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .onDemand = sections[indexPath.section],
           case .ssid = TunnelInTunnelDetailTableViewController.onDemandFields[indexPath.row] {
            let ssidDetailVC = SSIDOptionDetailTableViewController(title: onDemandViewModel.ssidOption.localizedUIString, ssids: onDemandViewModel.selectedSSIDs)
            navigationController?.pushViewController(ssidDetailVC, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
