import Foundation

/// The App Group the app shares with its extensions (`NOTEBOOK_APP_GROUP` in Config/Shared.xcconfig): Quick Look reads
/// the look and the folders' bookmarks the app keeps there. Builds without it have none of this.
public enum AppGroup {
    /// From the Info.plist of the app or the extension; nil in a build without the App Group.
    public static var identifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "NotebookAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A folder of the group's own, in its container.
    static func folder(_ name: String) -> URL? {
        identifier
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .map { $0.appendingPathComponent("Library/Application Support/\(name)", isDirectory: true) }
    }

    /// The group's settings.
    public static var defaults: UserDefaults? { identifier.flatMap { UserDefaults(suiteName: $0) } }
}
