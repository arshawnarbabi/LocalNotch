import AppKit

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered stdout so diagnostic logs flush immediately when piped

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
