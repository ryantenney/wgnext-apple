// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import NetworkExtension

class FailoverGroupDetailTableViewController: UITableViewController {

    private enum Section {
        case status
        case tunnels
        case settings
        case onDemand
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
        sections = [.status, .tunnels, .settings, .onDemand, .delete]
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
        failoverStateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
                let newActiveConfig = state["activeConfig"] as? String
                if newActiveConfig != self.activeConfigName {
                    self.activeConfigName = newActiveConfig
                    if let tunnelsSection = self.sections.firstIndex(of: .tunnels) {
                        self.tableView.reloadSections(IndexSet(integer: tunnelsSection), with: .none)
                    }
                }
            }
        }
    }

    // MARK: - On-Demand Updates

    private func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(of: .onDemand) else { return }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
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
        case .settings:
            return SettingsField.allCases.count
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
            return "Connections"
        case .settings:
            return "Failover Settings"
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
        case .settings:
            return settingsCell(for: tableView, at: indexPath)
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
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        let name = tunnelNames[indexPath.row]
        cell.key = name
        var detail = indexPath.row == 0 ? "Primary" : "Fallback #\(indexPath.row)"
        if let activeConfigName = activeConfigName, activeConfigName == name {
            detail += " (Active)"
        }
        cell.value = detail
        cell.copyableGesture = false
        return cell
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
