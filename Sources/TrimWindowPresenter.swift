import AppKit
import SwiftUI

/// Presents the Trim editor as a standalone window. Done in AppKit so it works
/// regardless of whether the main SwiftUI window is open (e.g. menu-bar-only
/// mode), and so we can keep it a single focused window per recording.
@MainActor
final class TrimWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = TrimWindowPresenter()

    private var windows = Set<NSWindow>()

    /// - Parameter onSaved: called if the user saved a trimmed version.
    func present(url: URL, onSaved: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)

        let onClose: (Bool) -> Void = { [weak window] saved in
            if saved { onSaved() }
            window?.close()
        }

        window.contentViewController = NSHostingController(
            rootView: TrimView(url: url, onClose: onClose))
        window.title = "Trim Recording"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        windows.insert(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }
}
