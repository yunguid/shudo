import Combine

/// Owns a reference with @StateObject's create-once lifecycle without
/// subscribing the owning view to its changes: nothing here ever publishes,
/// so the held object's own @Published churn (e.g. a recorder's 16Hz meter
/// updates) can't re-render the owning view. Views that receive `value`
/// observe it themselves.
@MainActor
final class UnobservedHolder<Value>: ObservableObject {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
