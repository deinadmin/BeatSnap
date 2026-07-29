import Foundation

/// Thread-safe accumulator for a child process's output streams.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()
    private var pendingLine = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var output: String {
        lock.withLock { String(data: outputData, encoding: .utf8) ?? "" }
    }

    var error: String {
        lock.withLock { String(data: errorData, encoding: .utf8) ?? "" }
    }

    func appendOutput(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            outputData.append(chunk)
            guard onLine != nil else { return [] }
            pendingLine.append(chunk)

            var completed: [String] = []
            // yt-dlp rewrites progress in place with \r; treat both terminators as breaks.
            while let index = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pendingLine[pendingLine.startIndex..<index]
                pendingLine.removeSubrange(pendingLine.startIndex...index)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    completed.append(line)
                }
            }
            return completed
        }
        // Deliver outside the lock so a slow consumer can't stall the reader.
        lines.forEach { onLine?($0) }
    }

    func appendError(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { errorData.append(chunk) }
    }
}

extension Process {
    struct Result {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
    }

    enum RunError: LocalizedError {
        case failed(command: String, exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .failed(_, _, let message): message
            }
        }
    }

    /// Run a tool to completion, collecting stdout/stderr.
    ///
    /// `onOutputLine` receives stdout lines as they arrive so long-running downloads can
    /// report progress.
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            // GUI apps launch with a minimal PATH; make sure the bundled ffmpeg is findable
            // by yt-dlp's own subprocess lookups.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = [
                Tools.bundledToolsDirectory.path,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            ].joined(separator: ":")
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Pipe callbacks arrive on arbitrary queues, so the buffers live behind a lock
            // in a reference type rather than being captured as mutable locals.
            let collector = OutputCollector(onLine: onOutputLine)

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendOutput(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendError(handle.availableData)
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything buffered after the last read.
                collector.appendOutput(outputPipe.fileHandleForReading.availableData)
                collector.appendError(errorPipe.fileHandleForReading.availableData)

                continuation.resume(
                    returning: Result(
                        exitCode: process.terminationStatus,
                        standardOutput: collector.output,
                        standardError: collector.error
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
