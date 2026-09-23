import AVFoundation
import Observation

/// Single-slot preview player: only one beat is ever loaded. Pausing keeps the beat loaded
/// so its playhead survives, while starting another beat tears the previous one down — which
/// is what makes every other row drop back to its idle state.
@MainActor
@Observable
final class AudioPreview {
    /// The loaded beat, playing or paused.
    private(set) var activeBeatID: String?
    private(set) var isPlaying = false
    private(set) var pendingBeatID: String?
    /// Playhead in seconds, preserved across pauses.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var preparation: Task<Void, Never>?

    func isActive(_ beat: Beat) -> Bool { activeBeatID == beat.id }

    func isPlaying(_ beat: Beat) -> Bool { activeBeatID == beat.id && isPlaying }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func toggle(_ beat: Beat, library: BeatLibrary) {
        if pendingBeatID == beat.id {
            stop()
            return
        }
        guard activeBeatID == beat.id else {
            stop()
            pendingBeatID = beat.id
            preparation = Task { [weak self] in
                do {
                    let url = try await library.availableURL(for: beat)
                    try Task.checkCancellation()
                    // Preparing can take time even after the file is local. Keep the pending
                    // state published and do this work off the UI actor so animations continue.
                    let player = try await Task.detached(priority: .userInitiated) {
                        let player = try AVAudioPlayer(contentsOf: url)
                        guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                        return player
                    }.value
                    try Task.checkCancellation()
                    guard let self, self.pendingBeatID == beat.id,
                          library.beats.contains(where: { $0.id == beat.id }) else { return }
                    self.preparation = nil
                    try self.start(beat, player: player)
                } catch {
                    guard !Task.isCancelled, self?.pendingBeatID == beat.id else { return }
                    self?.pendingBeatID = nil
                    self?.preparation = nil
                    library.errorMessage = "Could not play \(beat.title): \(error.localizedDescription)"
                }
            }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    /// Move the playhead of the loaded beat. `fraction` is 0...1 of its duration.
    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let time = min(duration, max(0, fraction * duration))
        player.currentTime = time
        currentTime = time
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        pendingBeatID = nil
        stopTimer()
        player?.stop()
        player = nil
        activeBeatID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Stop if the beat that is loaded was removed.
    func stopIfPlaying(_ beat: Beat) {
        if activeBeatID == beat.id || pendingBeatID == beat.id { stop() }
    }

    private func start(_ beat: Beat, player: AVAudioPlayer) throws {
        guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        self.player = player
        activeBeatID = beat.id
        duration = player.duration
        currentTime = 0
        isPlaying = true
        // Publish the active player before ending preparation: there is never an idle gap.
        pendingBeatID = nil
        startTimer()
    }

    private func pause() {
        guard let player else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        stopTimer()
    }

    private func resume() {
        guard let player else { return }
        // A beat parked at its end restarts rather than doing nothing.
        if duration > 0, player.currentTime >= duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        // Reaching the end unloads the beat, so the row returns to its idle tile.
        guard player.isPlaying else {
            stop()
            return
        }
        currentTime = player.currentTime
    }
}
