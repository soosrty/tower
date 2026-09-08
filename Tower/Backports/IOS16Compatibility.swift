import SwiftUI

/// Lightweight replacement for iOS 17's ContentUnavailableView.
struct TowerEmptyState: View {
    private let title: Text
    private let systemImage: String
    private let description: Text?

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.description = description
    }

    static func search(text: String) -> TowerEmptyState {
        TowerEmptyState(
            "没有搜索结果",
            systemImage: "magnifyingglass",
            description: text.isEmpty ? nil : Text("未找到“\(text)”")
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            title
                .font(.headline)
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
}

/// Builder-based replacement for ContentUnavailableView label/description/actions.
struct TowerContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            label.font(.headline)
            description
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
}

extension TowerContentUnavailableView where Actions == EmptyView {
    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description
    ) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}
