// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

class FailoverGroupCell: UITableViewCell {

    var onSwitchToggled: ((Bool) -> Void)?

    let nameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    let detailLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    let activeConfigLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .systemGreen
        return label
    }()

    let statusSwitch = UISwitch()

    let busyIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .disclosureIndicator

        for subview in [nameLabel, detailLabel, activeConfigLabel, statusSwitch, busyIndicator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalToSystemSpacingBelow: contentView.layoutMarginsGuide.topAnchor, multiplier: 0.5),
            nameLabel.leadingAnchor.constraint(equalToSystemSpacingAfter: contentView.layoutMarginsGuide.leadingAnchor, multiplier: 1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),

            activeConfigLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 1),
            activeConfigLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            activeConfigLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),
            contentView.layoutMarginsGuide.bottomAnchor.constraint(equalToSystemSpacingBelow: activeConfigLabel.bottomAnchor, multiplier: 0.5),

            statusSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusSwitch.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            busyIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            busyIndicator.trailingAnchor.constraint(equalTo: statusSwitch.leadingAnchor, constant: -8)
        ])

        statusSwitch.addTarget(self, action: #selector(switchToggled), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func switchToggled() {
        onSwitchToggled?(statusSwitch.isOn)
    }

    func configure(with group: FailoverGroup, isActive: Bool, activeConfigName: String?) {
        nameLabel.text = group.name

        let tunnelSummary = group.tunnelNames.joined(separator: " → ")
        detailLabel.text = tunnelSummary

        if isActive {
            if let activeName = activeConfigName {
                activeConfigLabel.text = "Active: \(activeName)"
            } else {
                activeConfigLabel.text = "Active: \(group.tunnelNames.first ?? "")"
            }
            activeConfigLabel.isHidden = false
            statusSwitch.setOn(true, animated: false)
            statusSwitch.onTintColor = .systemGreen
        } else {
            activeConfigLabel.isHidden = true
            statusSwitch.setOn(false, animated: false)
        }
    }
}
