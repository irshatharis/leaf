import AppIntents

/// New Note in Shortcuts, in Spotlight and on the iPhone's Action button: Notebook
/// comes to the front with a new note in the default folder and the caret in its title, as ⌘N makes one with nothing
/// open. A shortcut can give it text to start with.
///
/// It opens the app, so the system always runs it there; the app says how it makes the note (`makeNote`).
public struct NewNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Note"
    public static let description = IntentDescription("Opens Leaf with a new note in the default folder, ready for its title.")
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Text", description: "What the note starts with.", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("New note with \(\.$text)")
    }

    /// Makes the note with the text given, set by the app as it starts, before the system hands it an intent.
    @MainActor public static var makeNote: ((String) async throws -> Void)?

    public init() {}

    public init(text: String?) {
        self.text = text
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let makeNote = Self.makeNote else { throw NewNoteIntentError.notMade }
        try await makeNote(text ?? "")
        return .result()
    }
}

public enum NewNoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLocation
    case notMade

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLocation: "Choose where your notes are in Leaf first."
        case .notMade: "The note couldn’t be made."
        }
    }
}

/// The intents here, for the app to take in (`NotebookKitIntents`).
public struct NotebookCaptureIntents: AppIntentsPackage {}
