import AVFoundation
import Observation

/// Single-slot preview player: only one beat can play at a time.
@MainActor
@Observable
final class AudioPreview {
    private(set) var playingBeatID: String?
    private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func isPlaying(_ beat: Beat) -> Bool { playingBeatID == beat.id }

    func toggle(_ beat: Beat) {
        if playingBeatID == beat.id {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: beat.fileURL) else { return }
        self.player = player
        player.prepareToPlay()
        player.play()
        playingBeatID = beat.id
        progress = 0

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingBeatID = nil
        progress = 0
    }

    /// Stop if the beat that is playing was removed.
    func stopIfPlaying(_ beat: Beat) {
        if playingBeatID == beat.id { stop() }
    }

    private func tick() {
        guard let player else { return }
        guard player.isPlaying else {
            stop()
            return
        }
        let duration = player.duration
        progress = duration > 0 ? player.currentTime / duration : 0
    }
}
