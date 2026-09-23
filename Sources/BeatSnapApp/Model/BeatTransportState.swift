/// Preparing is a visible state: the download may have finished before playback is ready.
enum BeatTransportState: Equatable {
    case idle, downloading, preparing, playback, failed

    static func resolve(isActive: Bool, isPending: Bool, isDownloading: Bool, hasError: Bool) -> Self {
        if isActive { return .playback }
        if isDownloading { return .downloading }
        if hasError { return .failed }
        if isPending { return .preparing }
        return .idle
    }

    var showsProgress: Bool { self == .downloading || self == .preparing || self == .playback }
    var isBusy: Bool { self == .downloading || self == .preparing }
}
