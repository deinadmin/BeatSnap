import Foundation
import Observation

struct Toast: Identifiable, Equatable {
    static let dismissalDuration = 0.24
    enum Kind { case error, info, success }
    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    var isDismissing = false
    /// Capacity eviction fades, blurs, shrinks, and drops. A manual or timed dismissal slides away.
    var isEvicted = false

    var lifetime: Duration { .seconds(3) }
}

/// Shared by the library and its UI. A fourth toast frees the oldest card's layout
/// immediately while that surface fades, blurs, shrinks, and drops; it never waits
/// off-screen to reappear.
@MainActor @Observable
final class ToastCenter {
    private(set) var items: [Toast] = []
    @ObservationIgnored private var dismissals: [Toast.ID: Task<Void, Never>] = [:]

    func show(_ kind: Toast.Kind, title: String, message: String) {
        let active = items.filter { !$0.isDismissing }
        if active.count == 3 { beginDismissal(active[0].id, isEvicted: true) }
        items.append(Toast(kind: kind, title: title, message: message))
    }

    func clear() {
        for task in dismissals.values { task.cancel() }
        dismissals.removeAll()
        items.removeAll()
    }

    func dismiss(_ id: Toast.ID) {
        beginDismissal(id, isEvicted: false)
    }

    /// Layout space is released immediately. The surface stays until the exit finishes
    /// so a fourth toast can take the slot while the oldest one disappears.
    private func beginDismissal(_ id: Toast.ID, isEvicted: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isDismissing else { return }
        items[index].isDismissing = true
        items[index].isEvicted = isEvicted
        dismissals[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Toast.dismissalDuration)) } catch { return }
            self?.remove(id)
        }
    }

    private func remove(_ id: Toast.ID) {
        dismissals.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    /// A failure can cross several layers (download → playback/editor). Only its first
    /// presenter adds a toast; the wrapped error still carries the original explanation.
    @discardableResult
    func report(_ error: Error, title: String) -> Error {
        guard !(error is ReportedError), !(error is CancellationError) else { return error }
        show(.error, title: title, message: error.localizedDescription)
        return ReportedError(underlying: error)
    }

    private struct ReportedError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }
}
