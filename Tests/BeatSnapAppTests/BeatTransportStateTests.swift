import Testing
@testable import BeatSnapApp

struct BeatTransportStateTests {
    @Test func downloadCompletionNeverHidesPendingPlaybackBar() {
        // The transfer finishes (and can even be removed by a folder refresh) before
        // AVAudioPlayer finishes preparing. The same progress slot must survive every step.
        let downloading = BeatTransportState.resolve(isActive: false, isPending: true,
                                                    isDownloading: true, hasError: false)
        let preparing = BeatTransportState.resolve(isActive: false, isPending: true,
                                                  isDownloading: false, hasError: false)
        let handingOff = BeatTransportState.resolve(isActive: true, isPending: true,
                                                   isDownloading: false, hasError: false)
        let playing = BeatTransportState.resolve(isActive: true, isPending: false,
                                                isDownloading: false, hasError: false)
        let remainsVisible = [downloading, preparing, handingOff, playing].allSatisfy { $0.showsProgress }
        #expect(remainsVisible)
        #expect(downloading.isBusy && preparing.isBusy)
        #expect(handingOff == .playback && playing == .playback)
        #expect(!playing.isBusy)
    }

    @Test func completionWithoutPlaybackAndFailuresDoNotLeaveAStuckBar() {
        let dragCompleted = BeatTransportState.resolve(isActive: false, isPending: false,
                                                      isDownloading: false, hasError: false)
        let failed = BeatTransportState.resolve(isActive: false, isPending: true,
                                               isDownloading: false, hasError: true)
        #expect(dragCompleted == .idle)
        #expect(failed == .failed)
        #expect(!dragCompleted.showsProgress && !failed.showsProgress)
    }
}
