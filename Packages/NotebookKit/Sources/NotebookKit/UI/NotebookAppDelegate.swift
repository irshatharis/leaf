#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Notes opened from the Finder, the Dock icon or the leaf command open in the main window, also those outside every
/// folder in the sidebar; folders open in the sidebar.
public final class NotebookAppDelegate: NSObject, NSApplicationDelegate {
    /// Before a click on a reminder's notification, which can be what started the app, reaches it.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ReminderNotifications.activate()
            Workspace.shared.followMainWindow()
        }
    }

    /// Quitting waits for notes still being written, off the main thread, which keeps going meanwhile. So it does for
    /// changes to to-dos, such as Move to Note….
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let workspace = Workspace.shared
            workspace.saveAll(quitting: true)
            PDFDrawingSession.saveAll()
            guard NoteDocument.isWriting || workspace.isWritingTodos || PDFInk.isWriting else { return .terminateNow }
            // The to-dos and PDFs are waited for ten seconds at most: quitting never gets stuck.
            let reply = QuitReply()
            Task { @MainActor in
                await workspace.todosWritten()
                await PDFInk.written()
                reply.send()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                reply.send()
            }
            return .terminateLater
        }
    }

    /// Notes are written as you switch to another app.
    public func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { Workspace.shared.saveAll() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Workspace.shared.saveAll(quitting: true) }
    }

    /// Closing the window leaves Notebook running, as Notes does: the Dock icon and Window › Notebook bring it back,
    /// and SwiftUI would otherwise quit an app whose one window is closed.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Workspace.shared.openFromOutside(urls) }
    }
}

/// Lets quitting go on once, when the to-dos are written or the wait for them is over, and the notes are written.
@MainActor
private final class QuitReply {
    private var isSent = false

    func send() {
        guard !isSent else { return }
        isSent = true
        NoteDocument.whenAllWritten { NSApp.reply(toApplicationShouldTerminate: true) }
    }
}

@MainActor
extension Workspace {
    /// Folders and notes from the Finder, the Dock icon or the leaf command, all in the main window, brought to the
    /// front. A note outside every location is kept on its own (`keep`), which lets it into the recent files. Nothing
    /// waits for the locations to be looked up: which folders there are is known at once, also as the app starts.
    public func openFromOutside(_ urls: [URL]) {
        start()
        var opening: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            if FileNode.isFolder(url) {
                if location(containing: url) == nil { addLocation(url) }
                isSidebarVisible = true
                opening.append(url)
            } else if FileKind(url: url, isDirectory: false) == .note {
                keep(url)
                opening.append(url)
            }
        }
        guard !opening.isEmpty else { return }
        // Each goes into Back and the recent files; the last one shows.
        inMainWindow { [weak self] in opening.forEach { self?.open($0) } }
        NSApp?.activate()
    }

    /// File › Open: any Markdown or AsciiDoc file, anywhere, or a folder such as iCloud Drive to show in the sidebar.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = NoteSyntax.noteExtensions.sorted().compactMap { UTType(filenameExtension: $0) } + [.plainText, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openFromOutside(panel.urls)
    }

    /// Follows which window you are working in: the File and Edit menus have no note while another one, such as
    /// Settings, is in front, and a sheet over a window, or a panel such as Spelling, leaves it as it is.
    func followMainWindow() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { Workspace.shared.windowBecameMain(window) }
        }
    }

    func windowBecameMain(_ window: NSWindow) {
        var window = window
        while let below = window.sheetParent ?? window.parent { window = below }
        let isMain = isMainWindow(window)
        if isOtherWindowInFront == isMain { isOtherWindowInFront = !isMain }
        // What was kept for Undo while the main window was closed, if it couldn't go there as it opened.
        if isMain { moveUndoToMainWindow() }
    }
}

#endif
