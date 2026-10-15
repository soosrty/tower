import SwiftUI
import UIKit

/// A single, non-scrolling native row. Its parent supplies the card's intrinsic
/// height; it does not need a SwiftUI List's diffing and self-sizing machinery.
struct CardSwipeRow<Content: View>: UIViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let content: Content
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDelete: onDelete) }

    func makeUIView(context: Context) -> CardSwipeTableView {
        let table = CardSwipeTableView(frame: .zero, style: .plain)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.isScrollEnabled = false
        table.scrollsToTop = false
        table.delaysContentTouches = false
        table.allowsSelection = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.insetsContentViewsToSafeArea = false
        table.layoutMargins = .zero
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.showsVerticalScrollIndicator = false
        table.showsHorizontalScrollIndicator = false
        table.register(UITableViewCell.self, forCellReuseIdentifier: "card")
        return table
    }

    func updateUIView(_ table: CardSwipeTableView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDelete = onDelete
        let environment = context.environment
        coordinator.configuration = UIHostingConfiguration {
            content
                .environmentObject(model)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.locale, environment.locale)
                .environment(\.isEnabled, environment.isEnabled)
        }
        .margins(.all, 0)
        .background(.clear)
        if let cell = table.cellForRow(at: IndexPath(row: 0, section: 0)) {
            withTransaction(context.transaction) {
                cell.contentConfiguration = coordinator.configuration
            }
        }
    }

    static func dismantleUIView(_ table: CardSwipeTableView, coordinator: Coordinator) {
        table.dataSource = nil
        table.delegate = nil
        table.visibleCells.forEach { $0.contentConfiguration = nil }
        coordinator.configuration = nil
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var onDelete: () -> Void
        var configuration: (any UIContentConfiguration)?

        init(onDelete: @escaping () -> Void) { self.onDelete = onDelete }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            cell.backgroundConfiguration = .clear()
            cell.layoutMargins = .zero
            cell.contentView.layoutMargins = .zero
            cell.contentConfiguration = configuration
            return cell
        }

        func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            deletionActions()
        }

        func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            deletionActions()
        }

        private func deletionActions() -> UISwipeActionsConfiguration {
            // A normal action only requests confirmation. A destructive action
            // can visually remove the row before the user confirms deletion.
            let action = UIContextualAction(style: .normal, title: String(localized: "删除")) { [weak self] _, _, completion in
                completion(true)
                self?.onDelete()
            }
            action.image = UIImage(systemName: "trash")
            action.backgroundColor = .systemRed
            let actions = UISwipeActionsConfiguration(actions: [action])
            actions.performsFirstActionWithFullSwipe = false
            return actions
        }
    }
}

final class CardSwipeTableView: UITableView {
    override func layoutSubviews() {
        let height = max(1, bounds.height)
        if rowHeight != height {
            rowHeight = height
            // Only geometry changes (including Dynamic Type) require a new row
            // height. Presenting or dragging another sheet does not reload it.
            invalidateIntrinsicContentSize()
        }
        super.layoutSubviews()
    }
}
