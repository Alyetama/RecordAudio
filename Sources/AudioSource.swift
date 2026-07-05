import Foundation

/// What the recorder should capture: everything the Mac plays, or just one app.
enum AudioSource: Hashable {
    case system
    case app(bundleID: String)
}

/// A running application the user can pick as the audio source.
struct AudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}
