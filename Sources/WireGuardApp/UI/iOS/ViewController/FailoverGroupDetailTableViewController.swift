// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

class FailoverGroupDetailTableViewController: UITableViewController {

    private enum Section {
        case status
        case tunnels
        case activeConnection
        case settings
        case onDemand
        #if FAILOVER_TESTING
        case debug
        #endif
        case delete
    }

    private enum SettingsField: CaseIterable {
        case trafficTimeout
        case healthCheckInterval
        case failbackProbeInterval
        case autoFailback

        var localizedUIString: String {
            switch self {
            case .trafficTimeout: return "Traffic Timeout"
            case .healthCheckInterval: return "Health Check Interval"
            case .failbackProbeInterval: return "Failback Probe Interval"
            case .autoFailback: return "Auto Failback"
            }
        }
    }

    private enum ConnectionStatus {
        case active          // green: this tunnel is active and healthy
        case unhealthy       // yellow: this tunnel is active but tx without rx
        case hotSpareReady   // green: hot spare with valid handshake
        case hotSpareWaiting // yellow: hot spare probe running, no handshake yet
        case probing         // yellow: failback probe in progress for this tunnel
        case idle            // gray: not active, not being probed

        var indicatorColor: UIColor {
            switch self {
            case .active, .hotSpareReady: return .systemGreen
            case .unhealthy, .hotSpareWaiting, .probing: return .systemYellow
            case .idle: return .systemGray
            }
        }

        var label: String {
            switch self {
            case .active: return "Active"
            case .unhealthy: return "Unhealthy"
            case .hotSpareReady: return "Standby"
            case .hotSpareWaiting: return "Connecting"
            case .probing: return "Probing"
            case .idle: return "Idle"
            }
        }
    }

    private enum ActiveConnectionField {
        case dataReceived
        case dataSent
        case lastHandshake
        case failoverCount
        case lastFailover
        case healthStatus
        case failbackProbe
        case hotSpare

        var localizedUIString: String {
            switch self {
            case .dataReceived: return tr("tunnelPeerRxBytes")
            case .dataSent: return tr("tunnelPeerTxBytes")
            case .lastHandshake: return tr("tunnelPeerLastHandshakeTime")
            case .failoverCount: return "Failover Count"
            case .lastFailover: return "Last Failover"
            case .healthStatus: return "Health"
            case .failbackProbe: return "Failback Probe"
            case .hotSpare: return "Hot Spare"
            }
        }
    }

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer

    private var tunnelNames: [String] = []
    private var settings = FailoverSettings()
    private var onDemandViewModel: ActivateOnDemandViewModel

    private var sections = [Section]()

    private var statusObservationToken: AnyObject?
    private var onDemandObservationToken: AnyObject?
    private var activeConfigName: String?
    private var failoverStateTimer: Timer?

    // Runtime state from the network extension
    private var failoverState: [String: Any]?
    private var visibleActiveConnectionFields: [ActiveConnectionField] = []

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
                self.startPollingFailoverState()
            } else if tunnel.status == .inactive {
                self.stopPollingFailoverState()
                self.activeConfigName = nil
                self.failoverState = nil
                self.visibleActiveConnectionFields = []
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

        restorationIdentifier = "FailoverGroupDetailVC:\(tunnel.name)"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tunnel.status == .active {
            startPollingFailoverState()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPollingFailoverState()
    }

    private func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        tunnelNames = (providerConfig["FailoverConfigNames"] as? [String]) ?? []
        if let settingsData = providerConfig["FailoverSettings"] as? Data {
            settings = (try? JSONDecoder().decode(FailoverSettings.self, from: settingsData)) ?? FailoverSettings()
        } else {
            settings = FailoverSettings()
        }
    }

    private func loadSections() {
        var s: [Section] = [.status, .tunnels]
        if tunnel.status == .active && !visibleActiveConnectionFields.isEmpty {
            s.append(.activeConnection)
        }
        s.append(contentsOf: [.settings, .onDemand])
        #if FAILOVER_TESTING
        if tunnel.status == .active {
            s.append(.debug)
        }
        #endif
        s.append(.delete)
        sections = s
    }

    @objc func editTapped() {
        let editVC = FailoverGroupEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: tunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
    }

    // MARK: - Failover State Polling

    private func startPollingFailoverState() {
        pollFailoverState()
        stopPollingFailoverState()
        failoverStateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollFailoverState()
        }
    }

    private func stopPollingFailoverState() {
        failoverStateTimer?.invalidate()
        failoverStateTimer = nil
    }

    private func pollFailoverState() {
        tunnelsManager.getFailoverState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.failoverState = state

                let newActiveConfig = state["activeConfig"] as? String
                let activeConfigChanged = (newActiveConfig != self.activeConfigName)
                self.activeConfigName = newActiveConfig

                let newVisibleFields = self.computeVisibleActiveConnectionFields(from: state)
                let hadSection = self.sections.contains(.activeConnection)
                let needsSection = !newVisibleFields.isEmpty && self.tunnel.status == .active
                self.visibleActiveConnectionFields = newVisibleFields
                self.loadSections()

                if !hadSection && needsSection {
                    // Section appeared
                    if let idx = self.sections.firstIndex(of: .activeConnection) {
                        self.tableView.insertSections(IndexSet(integer: idx), with: .automatic)
                    }
                    if let tunnelsIdx = self.sections.firstIndex(of: .tunnels) {
                        self.tableView.reloadSections(IndexSet(integer: tunnelsIdx), with: .none)
                    }
                } else if hadSection && !needsSection {
                    // Section disappeared — reload all to be safe
                    self.tableView.reloadData()
                } else {
                    // Reload tunnels + active connection sections on every poll
                    var reloadSet = IndexSet()
                    if let tunnelsIdx = self.sections.firstIndex(of: .tunnels) {
                        reloadSet.insert(tunnelsIdx)
                    }
                    if needsSection, let idx = self.sections.firstIndex(of: .activeConnection) {
                        reloadSet.insert(idx)
                    }
                    if !reloadSet.isEmpty {
                        self.tableView.reloadSections(reloadSet, with: .none)
                    }
                }
            }
        }
    }

    private func computeVisibleActiveConnectionFields(from state: [String: Any]) -> [ActiveConnectionField] {
        var fields = [ActiveConnectionField]()

        if let rx = state["rxBytes"] as? UInt64, rx > 0 {
            fields.append(.dataReceived)
        }
        if let tx = state["txBytes"] as? UInt64, tx > 0 {
            fields.append(.dataSent)
        }
        if state["lastHandshakeTime"] as? Double != nil {
            fields.append(.lastHandshake)
        }
        if let count = state["consecutiveCycles"] as? Int, count > 0 {
            fields.append(.failoverCount)
        }
        if state["lastSwitchTime"] as? Double != nil {
            fields.append(.lastFailover)
        }
        if state["txWithoutRxSince"] as? Double != nil {
            fields.append(.healthStatus)
        }
        if let probing = state["isProbing"] as? Bool, probing {
            fields.append(.failbackProbe)
        }
        if state["hotSpareConfigIndex"] as? Int != nil {
            fields.append(.hotSpare)
        }

        return fields
    }

    // MARK: - On-Demand Updates

    private func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(of: .onDemand) else { return }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }

    // MARK: - Per-Tunnel Status

    private func connectionStatus(forTunnelAt index: Int) -> ConnectionStatus {
        guard tunnel.status == .active, let state = failoverState else { return .idle }

        let name = tunnelNames[index]

        // Is this the active tunnel?
        if let activeName = activeConfigName, activeName == name {
            if state["txWithoutRxSince"] as? Double != nil {
                return .unhealthy
            }
            return .active
        }

        // Is this the hot spare target?
        if let hotSpareIndex = state["hotSpareConfigIndex"] as? Int, hotSpareIndex == index {
            if let age = state["hotSpareHandshakeAge"] as? Double, age < settings.trafficTimeout {
                return .hotSpareReady
            }
            let isActive = state["hotSpareActive"] as? Bool ?? false
            return isActive ? .hotSpareWaiting : .idle
        }

        // Is this being failback-probed? (failback always probes index 0)
        if index == 0, let probing = state["isProbing"] as? Bool, probing {
            return .probing
        }

        return .idle
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
}

// MARK: - FailoverGroupEditDelegate

extension FailoverGroupDetailTableViewController: FailoverGroupEditDelegate {
    func failoverGroupSaved(_ tunnel: TunnelContainer) {
        loadGroupData()
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        title = tunnel.name
        restorationIdentifier = "FailoverGroupDetailVC:\(tunnel.name)"
        tableView.reloadData()
    }

    func failoverGroupDeleted(_ tunnel: TunnelContainer) {
        // Navigation cleanup is handled by TunnelsListTableViewController.failoverGroupRemoved
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension FailoverGroupDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status:
            return 1
        case .tunnels:
            return tunnelNames.count
        case .activeConnection:
            return visibleActiveConnectionFields.count
        case .settings:
            return SettingsField.allCases.count
        case .onDemand:
            return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        #if FAILOVER_TESTING
        case .debug:
            return 2
        #endif
        case .delete:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status:
            return tr("tunnelSectionTitleStatus")
        case .tunnels:
            return "Connections"
        case .activeConnection:
            return "Active Connection"
        case .settings:
            return "Failover Settings"
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        #if FAILOVER_TESTING
        case .debug:
            return "Debug"
        #endif
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
        case .activeConnection:
            return activeConnectionCell(for: tableView, at: indexPath)
        case .settings:
            return settingsCell(for: tableView, at: indexPath)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        #if FAILOVER_TESTING
        case .debug:
            return debugCell(for: tableView, at: indexPath)
        #endif
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
            case .inactive:
                text = tr("tunnelStatusInactive")
            case .activating:
                text = tr("tunnelStatusActivating")
            case .active:
                text = tr("tunnelStatusActive")
            case .deactivating:
                text = tr("tunnelStatusDeactivating")
            case .reasserting:
                text = tr("tunnelStatusReasserting")
            case .restarting:
                text = tr("tunnelStatusRestarting")
            case .waiting:
                text = tr("tunnelStatusWaiting")
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
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "TunnelCell")
        let name = tunnelNames[indexPath.row]
        let role = indexPath.row == 0 ? "Primary" : "Failover #\(indexPath.row)"
        let status = connectionStatus(forTunnelAt: indexPath.row)

        let circle = NSAttributedString(string: "\u{25CF} ", attributes: [
            .foregroundColor: status.indicatorColor,
            .font: UIFont.systemFont(ofSize: 14)
        ])
        let nameAttr = NSAttributedString(string: name, attributes: [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17)
        ])
        let combined = NSMutableAttributedString()
        combined.append(circle)
        combined.append(nameAttr)
        cell.textLabel?.attributedText = combined

        cell.detailTextLabel?.text = "\(role) · \(status.label)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none
        return cell
    }

    private func activeConnectionCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = visibleActiveConnectionFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = activeConnectionValue(for: field)
        cell.copyableGesture = false
        return cell
    }

    private func activeConnectionValue(for field: ActiveConnectionField) -> String {
        guard let state = failoverState else { return "" }

        switch field {
        case .dataReceived:
            if let rx = state["rxBytes"] as? UInt64 {
                return prettyBytes(rx)
            }
            return ""

        case .dataSent:
            if let tx = state["txBytes"] as? UInt64 {
                return prettyBytes(tx)
            }
            return ""

        case .lastHandshake:
            if let timestamp = state["lastHandshakeTime"] as? Double {
                return prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""

        case .failoverCount:
            if let count = state["consecutiveCycles"] as? Int {
                return "\(count)"
            }
            return ""

        case .lastFailover:
            if let timestamp = state["lastSwitchTime"] as? Double {
                return prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""

        case .healthStatus:
            if let since = state["txWithoutRxSince"] as? Double {
                let duration = Int(Date().timeIntervalSince1970 - since)
                return "Unhealthy (tx without rx for \(duration)s)"
            }
            return "Healthy"

        case .failbackProbe:
            if let bgProbe = state["backgroundProbeActive"] as? Bool, bgProbe {
                return "Background probe running..."
            }
            return "Probing primary..."

        case .hotSpare:
            if let index = state["hotSpareConfigIndex"] as? Int {
                let name = index < tunnelNames.count ? tunnelNames[index] : "config #\(index)"
                if let age = state["hotSpareHandshakeAge"] as? Double {
                    if age < settings.trafficTimeout {
                        return "\(name): Connected (\(Int(age))s ago)"
                    } else {
                        return "\(name): Stale handshake (\(Int(age))s ago)"
                    }
                }
                let isActive = state["hotSpareActive"] as? Bool ?? false
                return isActive ? "\(name): Waiting for handshake..." : "\(name): Starting..."
            }
            return "Active"
        }
    }

    private func settingsCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = SettingsField.allCases[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        switch field {
        case .trafficTimeout:
            cell.value = "\(Int(settings.trafficTimeout))s"
        case .healthCheckInterval:
            cell.value = "\(Int(settings.healthCheckInterval))s"
        case .failbackProbeInterval:
            cell.value = "\(Int(settings.failbackProbeInterval))s"
        case .autoFailback:
            cell.value = settings.autoFailback ? "Yes" : "No"
        }
        cell.copyableGesture = false
        return cell
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = FailoverGroupDetailTableViewController.onDemandFields[indexPath.row]
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

    #if FAILOVER_TESTING
    private func debugCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        if indexPath.row == 0 {
            cell.buttonText = "Force Failover"
            cell.hasDestructiveAction = false
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.debugForceFailover(for: self.tunnel) { success in
                    DispatchQueue.main.async {
                        if success {
                            self.pollFailoverState()
                        }
                    }
                }
            }
        } else {
            cell.buttonText = "Force Failback to Primary"
            cell.hasDestructiveAction = false
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.debugForceFailback(for: self.tunnel) { success in
                    DispatchQueue.main.async {
                        if success {
                            self.pollFailoverState()
                        }
                    }
                }
            }
        }
        return cell
    }
    #endif

    private func deleteCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = "Delete Failover Group"
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(
                title: "Delete Failover Group",
                message: "Are you sure you want to delete '\(self.tunnel.name)'? This won't delete the individual tunnels.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.tunnelsManager.removeFailoverGroup(tunnel: self.tunnel) { error in
                    if error != nil {
                        print("Error removing failover group: \(String(describing: error))")
                        return
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

extension FailoverGroupDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .onDemand = sections[indexPath.section],
           case .ssid = FailoverGroupDetailTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .onDemand = sections[indexPath.section],
           case .ssid = FailoverGroupDetailTableViewController.onDemandFields[indexPath.row] {
            let ssidDetailVC = SSIDOptionDetailTableViewController(title: onDemandViewModel.ssidOption.localizedUIString, ssids: onDemandViewModel.selectedSSIDs)
            navigationController?.pushViewController(ssidDetailVC, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
