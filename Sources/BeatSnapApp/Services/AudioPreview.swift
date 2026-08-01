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
    /// Playhead in seconds, preserved across pauses.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func isActive(_ beat: Beat) -> Bool { activeBeatID == beat.id }

    func isPlaying(_ beat: Beat) -> Bool { activeBeatID == beat.id && isPlaying }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func toggle(_ beat: Beat) {
        guard activeBeatID == beat.id else {
            start(beat)
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
        if activeBeatID == beat.id { stop() }
    }

    private func start(_ beat: Beat) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: beat.fileURL) else { return }
        self.player = player
        player.prepareToPlay()
        player.play()
        activeBeatID = beat.id
        duration = player.duration
        currentTime = 0
        isPlaying = true
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
