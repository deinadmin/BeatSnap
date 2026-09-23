import AppKit
import UniformTypeIdentifiers

enum BeatDragProvider {
    /// Keep the native local-file representation for existing DAW compatibility. Cloud
    /// drags advertise both an audio file and a deferred file URL; neither is delivered
    /// until the real file is local. No placeholder or temporary copy is exported.
    @MainActor
    static func make(for beat: Beat, load: @escaping @MainActor () async throws -> URL) -> NSItemProvider {
        if !beat.needsDownload && !CloudFileAccess.needsDownload(at: beat.fileURL) {
            let provider = NSItemProvider(contentsOf: beat.fileURL) ?? NSItemProvider()
            provider.suggestedName = beat.fileName
            return provider
        }
        // Begin on drag initiation, even if a destination hasn't requested its data yet.
        let download = Task { try await load() }
        return deferred(for: beat, load: { try await download.value })
    }

    static func deferred(for beat: Beat, load: @escaping @Sendable () async throws -> URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = beat.fileName
        let type = UTType(filenameExtension: beat.fileURL.pathExtension) ?? .audio
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                             fileOptions: .openInPlace, visibility: .all) { completion in
            let task = Task {
                do {
                    let url = try await load()
                    try Task.checkCancellation()
                    completion(url, true, nil)
                } catch { completion(nil, false, error) }
            }
            let progress = Progress(totalUnitCount: -1)
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        // Several DAWs request public.file-url instead of loading the audio representation.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                             visibility: .all) { completion in
            let task = Task {
                do {
                    let url = try await load()
                    try Task.checkCancellation()
                    completion(url.dataRepresentation, nil)
                } catch { completion(nil, error) }
            }
            let progress = Progress(totalUnitCount: -1)
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
