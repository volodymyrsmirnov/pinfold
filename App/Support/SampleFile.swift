import Foundation

/// The sample file bundled with the app, offered on the empty Files list ("Try a Sample File")
/// so a new user, or App Review on a fresh device, has something to explore without a file of
/// their own. It is a real KMZ (folders, icons, descriptions), imported through the normal
/// pipeline like any other file.
enum SampleFile {
    /// The bundled `Rome.kmz`, or `nil` if it is missing from the bundle.
    static var url: URL? {
        Bundle.main.url(forResource: "Rome", withExtension: "kmz")
    }
}
