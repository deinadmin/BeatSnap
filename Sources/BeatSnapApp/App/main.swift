import AppKit

// Built as a SwiftPM executable rather than an Xcode app target, so the application object
// is configured by hand instead of through @main / NSApplicationMain.
//
// NSApplication.delegate is a weak reference, so the delegate is parked in a global to keep
// it alive for the lifetime of the process.
nonisolated(unsafe) var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
