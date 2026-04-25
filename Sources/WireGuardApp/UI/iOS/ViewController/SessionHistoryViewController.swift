// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

class SessionHistoryViewController: UITableViewController {

    private var records: [SessionRecord] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    init() {
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("sessionHistoryViewTitle")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: tr("sessionHistoryClearButtonTitle"),
            style: .plain,
            target: self,
            action: #selector(clearTapped)
        )

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(ChevronCell.self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        records = SessionHistoryStore.loadAll()
        tableView.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !records.isEmpty
        if records.isEmpty {
            let label = UILabel()
            label.text = tr("sessionHistoryEmptyMessage")
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: tr("sessionHistoryClearConfirmTitle"),
            message: tr("sessionHistoryClearConfirmMessage"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: tr("sessionHistoryClearButtonTitle"), style: .destructive) { [weak self] _ in
            SessionHistoryStore.clear()
            self?.reload()
        })
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return records.isEmpty ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return records.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        let record = records[indexPath.row]
        cell.message = "\(record.tunnelName) — \(dateFormatter.string(from: record.startedAt))"
        if record.endedAt != nil {
            cell.detailMessage = durationFormatter.string(from: record.duration) ?? ""
        } else {
            cell.detailMessage = tr("sessionStatusInProgress")
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let detail = SessionDetailViewController(record: records[indexPath.row])
        navigationController?.pushViewController(detail, animated: true)
    }
}
