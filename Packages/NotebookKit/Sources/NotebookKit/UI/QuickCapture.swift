import AppIntents
import NotebookCapture

/// Notes asked for from outside the window: the New Note intent, from Shortcuts, Spotlight and the Action button. The
/// intent is in NotebookCapture; the notes are made here.
@MainActor
public enum QuickCapture {
    /// Called as the app starts, before the system hands it an intent that started it.
    public static func start() {
        NewNoteIntent.makeNote = { text in
            let workspace = Workspace.shared
            guard await workspace.newNoteFromOutside(text: text) != nil else {
                throw workspace.locations.isEmpty ? NewNoteIntentError.noLocation : .notMade
            }
        }
    }
}

/// NotebookKit's intents, for the app to take into its App Shortcuts (`NotebookShortcuts` in the app target).
public struct NotebookKitIntents: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [NotebookCaptureIntents.self] }
}
