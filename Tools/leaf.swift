// leaf: opens notes and folders in Leaf's window from the terminal. Built by Tools/build.sh into build/leaf.
import AppKit

let usage = """
Usage: leaf [path ...]

Opens notes and folders in Leaf's window, and returns at once.

  leaf                 bring Leaf to the front, opening it if needed
  leaf note.md ...     open notes; a missing .md, .markdown or .adoc file is created first
  leaf folder          add the folder to the sidebar, or show it there

Options:
  -h, --help           show this help
  -v, --version        show the version of Leaf the command opens
  --                   treat what follows as paths, even if it starts with -

Environment:
  LEAF_APP             the Leaf.app to open (default /Applications/Leaf.app)
  LEAF_APP_ARGS        arguments for Leaf when the command starts it, such as
                       "-NotebookLibrary ~/test-notes" to try a build on other notes
"""

let noteExtensions: Set<String> = ["md", "markdown", "adoc", "asciidoc"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("leaf: \(message)\n".utf8))
    exit(1)
}

func expandingTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// What a path on the command line is to Leaf.
enum Target {
    case folder(URL)
    case note(URL)
    case newNote(URL)

    var url: URL {
        switch self {
        case .folder(let url), .note(let url), .newNote(let url): url
        }
    }
}

func target(for argument: String) -> Target {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = URL(fileURLWithPath: expandingTilde(argument), relativeTo: cwd).standardizedFileURL
    let isNote = noteExtensions.contains(url.pathExtension.lowercased())
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        guard isNote else { fail("\(argument): no such file or folder (give it a .md extension to create a note)") }
        return .newNote(url)
    }
    if isDirectory.boolValue { return .folder(url) }
    guard isNote else { fail("\(argument): not a note (Leaf opens .md, .markdown and .adoc files, and folders)") }
    return .note(url)
}

func create(_ url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
    } catch {
        fail("can't create \(url.path): \(error.localizedDescription)")
    }
}

/// The instance of this very bundle that is running, not another copy with the same bundle identifier (a build next to
/// the installed app, say), which Launch Services could pick instead.
func running(_ app: URL, bundleID: String) -> NSRunningApplication? {
    let path = app.resolvingSymlinksInPath().path
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == path
    }
}

/// Sends an Open Documents event, or Reopen when there is nothing to open, to that process alone.
func send(_ urls: [URL], to pid: pid_t) -> Bool {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    let id = urls.isEmpty ? AEEventID(kAEReopenApplication) : AEEventID(kAEOpenDocuments)
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: target,
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    if !urls.isEmpty {
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
        event.setParam(list, forKeyword: keyDirectObject)
    }
    return (try? event.sendEvent(options: [.noReply], timeout: 5)) != nil
}

func launch(_ app: URL, opening urls: [URL]) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = (ProcessInfo.processInfo.environment["LEAF_APP_ARGS"] ?? "")
        .split(whereSeparator: \.isWhitespace).map { expandingTilde(String($0)) }
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    let finish: (NSRunningApplication?, Error?) -> Void = { _, error in
        failure = error
        done.signal()
    }
    if urls.isEmpty {
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: finish)
    } else {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration, completionHandler: finish)
    }
    done.wait()
    if let failure { fail("can't open \(app.path): \(failure.localizedDescription)") }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String] = []
var showsVersion = false
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--":
        paths += arguments
        arguments = []
    case "-v", "--version":
        showsVersion = true
    case _ where argument.hasPrefix("-"):
        fail("unknown option \(argument) (see leaf --help)")
    default:
        paths.append(argument)
    }
}

let app = URL(fileURLWithPath: expandingTilde(ProcessInfo.processInfo.environment["LEAF_APP"] ?? "/Applications/Leaf.app")).standardizedFileURL
guard let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier else {
    fail("no Leaf at \(app.path) (run Tools/build.sh, or set LEAF_APP)")
}

if showsVersion {
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    print("leaf \(version) (\(build)), \(app.path)")
    exit(0)
}

let targets = paths.map(target(for:))
for case .newNote(let url) in targets { create(url) }
let urls = targets.map(\.url)

if let instance = running(app, bundleID: bundleID), send(urls, to: instance.processIdentifier) {
    instance.activate()
} else {
    launch(app, opening: urls)
}
