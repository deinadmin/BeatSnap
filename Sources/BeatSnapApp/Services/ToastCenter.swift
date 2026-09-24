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

    var lifetime: Duration { kind == .error ? .seconds(12) : .seconds(8) }
}

/// Shared by the library and its UI. Dropping the oldest item is synchronous: there is
/// never a fourth notification waiting off-screen to reappear later.
@MainActor @Observable
final class ToastCenter {
    private(set) var items: [Toast] = []
    @ObservationIgnored private var dismissals: [Toast.ID: Task<Void, Never>] = [:]

    func show(_ kind: Toast.Kind, title: String, message: String) {
        if items.count == 3 { remove(items[0].id) }
        items.append(Toast(kind: kind, title: title, message: message))
    }

    func dismiss(_ id: Toast.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isDismissing else { return }
        // The view immediately removes this card's layout space while retaining its
        // surface for the exit animation. Capacity eviction skips that animation.
        items[index].isDismissing = true
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
