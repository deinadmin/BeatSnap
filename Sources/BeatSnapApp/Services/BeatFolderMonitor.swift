import Darwin
import Foundation

/// One kernel-backed watch for the directory; idle folders do not trigger scans.
@MainActor
final class BeatFolderMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var directory: URL?
    private var pending: DispatchWorkItem?
    var onChange: (() -> Void)?

    func watch(_ url: URL) {
        guard directory != url || source == nil else { return }
        pending?.cancel()
        source?.cancel()
        source = nil
        directory = url
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return } // The recovery scan retries unavailable folders.
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke, .attrib], queue: .main
        )
        watch.setCancelHandler { close(descriptor) }
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    source.cancel()
                    self.source = nil
                }
                self.pending?.cancel()
                let pending = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.onChange?() }
                }
                self.pending = pending
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: pending)
            }
        }
        source = watch
        watch.activate()
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}
