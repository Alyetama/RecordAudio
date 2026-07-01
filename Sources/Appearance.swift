import AppKit

/// Dock-icon (activation policy) helpers. Kept out of `RecorderModel` so that
/// changing app-appearance settings never triggers the recording UI to re-render.
enum Appearance {
    static let showMenuBarKey = "showMenuBarIcon"
    static let showDockKey = "showDockIcon"

    static func applyDockPolicy(_ showDock: Bool) {
        NSApp?.setActivationPolicy(showDock ? .regular : .accessory)
    }

    static func applyDockPolicyFromDefaults() {
        let showDock = (UserDefaults.standard.object(forKey: showDockKey) as? Bool) ?? true
        applyDockPolicy(showDock)
    }
}
