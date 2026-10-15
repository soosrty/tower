import SwiftUI
import UIKit

private struct TowerChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value
    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }
    func body(content: Content) -> some View {
        content.onAppear {
            previous = value
            if initial { action(value, value) }
        }.onChange(of: value) { next in
            let old = previous
            previous = next
            action(old, next)
        }
    }
}

enum TowerFeedbackKind { case selection, success }

extension View {
    func towerOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(TowerChangeModifier(value: value, initial: initial, action: action))
    }
    func towerOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        towerOnChange(of: value, initial: initial) { _, _ in action() }
    }
    func towerOnChange<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        onChange(of: value, perform: action)
    }
    func towerFeedback<V: Equatable>(_ kind: TowerFeedbackKind, trigger: V, condition: @escaping (V, V) -> Bool = { _, _ in true }) -> some View {
        towerOnChange(of: trigger) { old, new in
            guard condition(old, new) else { return }
            switch kind {
            case .selection: UISelectionFeedbackGenerator().selectionChanged()
            case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
    func towerNavigationDestination<Item, Destination: View>(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        navigationDestination(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { destination(value) }
        }
    }
}

/// iOS 16 has no native animation completion. The guarded cleanup delay is
/// approximate; callers retain their existing cancellation/session tokens.
@MainActor
func towerWithAnimation(_ animation: Animation? = .default, _ body: () -> Void, completion: @escaping () -> Void) {
    if #available(iOS 17, *) {
        withAnimation(animation, completionCriteria: .removed, body, completion: completion)
    } else {
        withAnimation(animation, body)
        DispatchQueue.main.asyncAfter(deadline: .now() + (animation == nil ? 0 : 0.5), execute: completion)
    }
}
