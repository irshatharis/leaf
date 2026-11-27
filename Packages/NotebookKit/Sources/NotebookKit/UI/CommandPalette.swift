#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// What the palette shows.
enum PaletteMode: Hashable {
    /// ⌘K: commands only.
    case commands
    /// ⌘P: notes and files by name, recently opened first.
    case files
    /// ⌥⌘F: names, headings and the words in notes and PDFs.
    case search
    /// The folders, to move a file into.
    case move(URL)
    /// The notes, to move a to-do in no note into.
    case moveTodo(TodoReference)
}

/// One row of ⌘K.
struct PaletteRow: Identifiable {
    enum Action {
        case result(SearchResult)
        case command(PaletteCommand)
        case moveInto(URL)
        case moveTodoInto(URL)
    }

    var id: String
    var section: String?
    var title: String
    var snippet: String?
    var matches: [Range<String.Index>] = []
    var detail: String?
    var symbol: String
    /// A folder's emoji, shown instead of the symbol.
    var emoji: String?
    var tint: Color
    var keys: [String] = []
    var action: Action
}

/// The palette over the window: ⌘K runs commands, ⌘P goes to a file, ⌥⌘F searches inside notes. Arrow keys and
/// Return pick, Escape closes. It appears and goes at once, with no animation.
struct CommandPalette: View {
    let workspace: Workspace
    let mode: PaletteMode
    let actions: PaletteActions
    @State private var query = ""
    @State private var selected: String?
    /// Moved with the arrow keys or the pointer since the last letter typed: the choice then stays as results come in.
    @State private var hasChosen = false
    /// Where the pointer was last seen over the list: rows that move under a pointer that stays where it is don't take
    /// the choice from the arrow keys.
    @State private var pointer: CGPoint?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var search: SearchSession { workspace.paletteSearch }

    var body: some View {
        let rows = makeRows()
        VStack(spacing: 0) {
            if case .move(let url) = mode {
                ContextChip(title: "Move “\(SearchSection.displayName(url))” to…")
            } else if case .moveTodo(let todo) = mode {
                ContextChip(title: "Move “\(Todos.line(todo.source).map { $0.text.isEmpty ? "To-do" : $0.text } ?? "To-do")” to…")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                    #if os(macOS)
                    .focusOnAppear()
                    #endif
                    .accessibilityLabel("Search or run a command")
                    #if os(iOS)
                    // The on-screen keyboard's Return; a keyboard's goes to the key handler below.
                    .onSubmit { run(rows.first { $0.id == currentID(rows) }) }
                    #endif
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .onKeyPress(.downArrow) { move(1, rows); return .handled }
            .onKeyPress(.upArrow) { move(-1, rows); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            // Return as the arrow keys are handled, before the field: SwiftUI's submit didn't always come.
            .onKeyPress(.return) {
                run(rows.first { $0.id == currentID(rows) })
                return .handled
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            list(rows)
        }
        .frame(maxWidth: 640)
        // Like Spotlight: a glass panel over the window.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear {
            focused = true
            configure()
            if mode != .commands { search.update(query) }
        }
        // Spotlight's Search in App, as the palette opens or while it is open.
        .onChange(of: workspace.paletteStart?.id, initial: true) { _, _ in
            guard let start = workspace.paletteStart else { return }
            workspace.paletteStart = nil
            query = start.query
        }
        #if DEBUG
        // palettetype <text>, palettekey down|up|return|escape: the keyboard, for the debug remote.
        .onReceive(NotificationCenter.default.publisher(for: .notebookDebug)) { notification in
            let argument = notification.userInfo?["argument"] as? String ?? ""
            switch notification.userInfo?["command"] as? String {
            case "palettetype": query = argument
            case "palettekey":
                switch argument {
                case "down": move(1, rows)
                case "up": move(-1, rows)
                case "return": run(rows.first { $0.id == currentID(rows) })
                default: close()
                }
            default: break
            }
        }
        #endif
        .onChange(of: query) { _, text in
            hasChosen = false
            if mode != .commands { search.update(text) }
        }
    }

    private var placeholder: String {
        switch mode {
        case .commands: "Run a command"
        case .files: "Go to file"
        case .search: "Search in notes"
        case .move: "Find a folder"
        case .moveTodo: "Find a note"
        }
    }

    private func configure() {
        if case .move = mode {
            search.limits = SearchCorpus.Limits(files: 0, folders: 30, headings: 0, texts: 0, pictures: 0, others: 0)
            search.offersNewNote = false
        } else if case .moveTodo = mode {
            search.limits = SearchCorpus.Limits(files: 30, folders: 0, headings: 0, texts: 0, pictures: 0)
            search.offersNewNote = false
        } else if case .files = mode {
            search.limits = SearchCorpus.Limits(files: 40, folders: 0, headings: 0, texts: 0, pictures: 0, others: 10)
            search.offersNewNote = false
        } else {
            search.limits = SearchCorpus.Limits(files: 6, folders: 4, headings: 4, texts: 12, pictures: 4)
            search.offersNewNote = false
        }
        search.recentLimit = mode == .files ? 12 : 0
    }

    // MARK: - The list

    private func list(_ rows: [PaletteRow]) -> some View {
        let current = currentID(rows)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                        if let section = row.section, position == 0 || rows[position - 1].section != section {
                            Text(section)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.theme(Theme.textTertiary))
                                .lineLimit(1)
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        rowView(row, isSelected: row.id == current)
                            .id(row.id)
                            .onTapGesture { run(row) }
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                guard case .active(let location) = phase, location != pointer else { return }
                                let moved = pointer != nil
                                pointer = location
                                // The first place seen is where it already was when the list came.
                                guard moved else { return }
                                selected = row.id
                                hasChosen = true
                            }
                    }
                    if rows.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.theme(Theme.textSecondary))
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: current) { _, id in
                if let id, hasChosen { proxy.scrollTo(id) }
            }
            .onChange(of: query) { _, _ in
                if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    private var emptyText: String {
        if workspace.index.isBuilding, workspace.index.corpus.items.isEmpty { return "Reading your files…" }
        if search.isSearching { return "Searching…" }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return mode == .files ? "No recent files. Type a name." : "Type to search" }
        return "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”"
    }

    private func rowView(_ row: PaletteRow, isSelected: Bool) -> some View {
        HStack(alignment: row.snippet == nil ? .center : .top, spacing: 10) {
            Group {
                if let emoji = row.emoji {
                    Text(emoji).font(.system(size: 13))
                } else {
                    Image(systemName: row.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(row.tint)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.theme(Theme.text))
                    .lineLimit(1)
                if let snippet = row.snippet {
                    Text(highlighted(snippet, row.matches))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.theme(Theme.textSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            if !row.keys.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in Keycap(key, emphasized: isSelected) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, row.snippet == nil ? 0 : 8)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? highlight : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    /// The row under the arrow keys: a soft tint of the accent colour, as in Issues.
    private var highlight: Color {
        Color.theme(Theme.accent).opacity(colorScheme == .dark ? 0.24 : 0.14)
    }

    /// The words searched for, in the colour of the text.
    private func highlighted(_ snippet: String, _ matches: [Range<String.Index>]) -> AttributedString {
        var text = AttributedString(snippet)
        for match in matches {
            guard let range = Range(match, in: text) else { continue }
            text[range].foregroundColor = Color.theme(Theme.text)
            text[range].font = .system(size: 12, weight: .semibold)
        }
        return text
    }

    // MARK: - Rows

    private func makeRows() -> [PaletteRow] {
        if case .move(let url) = mode { return folderRows(moving: url) }
        if case .moveTodo = mode { return noteRows() }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if case .commands = mode {
            let commands = workspace.paletteCommands(actions)
            return Self.matching(commands, trimmed).map { Self.commandRow($0, section: trimmed.isEmpty ? $0.section : "Commands") }
        }
        // While results for what was typed are on their way, the last ones stay.
        return Self.resultRows(shown(search.sections).filter { $0.title != nil })
    }

    /// Without what was just deleted, which search finds until it has read the folder again.
    private func shown(_ sections: [SearchSection]) -> [SearchSection] {
        sections.map { section in
            var section = section
            section.items = section.items.filter { item in item.result.url.map { !workspace.isThrownAway($0) } ?? true }
            return section
        }
    }


    private static func matching(_ commands: [PaletteCommand], _ filter: String) -> [PaletteCommand] {
        guard !filter.isEmpty else { return commands }
        return scoredMatching(commands, filter).map(\.command)
    }

    /// The commands that match, best first.
    private static func scoredMatching(_ commands: [PaletteCommand], _ filter: String) -> [(command: PaletteCommand, score: Int)] {
        commands.compactMap { command in command.score(filter).map { (command, $0) } }
            .sorted { $0.1 > $1.1 }
    }

    private static func commandRow(_ command: PaletteCommand, section: String) -> PaletteRow {
        PaletteRow(id: "command:" + command.id, section: section, title: command.title, symbol: command.symbol,
                   tint: Color.theme(Theme.textSecondary), keys: command.keys, action: .command(command))
    }

    private static func resultRows(_ sections: [SearchSection]) -> [PaletteRow] {
        sections.flatMap { section in
            section.items.map { item in
                // By section too: a scanned PDF can be found by its text and by its pictures.
                PaletteRow(id: (section.title ?? "") + "/" + Self.id(of: item.result), section: section.title, title: item.title, snippet: item.snippet,
                           matches: item.matches, detail: item.snippet == nil ? item.place : nil, symbol: item.image,
                           emoji: item.emoji, tint: tint(of: item), action: .result(item.result))
            }
        }
    }

    private static func tint(of item: SearchItem) -> Color {
        guard let kind = item.kind else { return Color.theme(Theme.accent) }
        if item.symbol != nil { return Color.theme(Theme.textSecondary) }
        return item.folderIcon?.color?.color ?? Color.theme(kind.tint)
    }

    private static func id(of result: SearchResult) -> String {
        switch result {
        case .file(let url): "file:" + url.path
        case .text(let url, _, _): "text:" + url.path
        case .heading(let url, let title): "heading:" + url.path + "#" + title
        case .picture(let url, let asset): "picture:" + url.path + "#" + (asset ?? "")
        case .newNote: "new"
        }
    }

    /// The folders a file can go into: as you type, those whose names match; before, the locations and the folders
    /// of what you opened last.
    private func folderRows(moving url: URL) -> [PaletteRow] {
        let from = url.deletingLastPathComponent().standardizedFileURL
        let allowed: (URL) -> Bool = { folder in
            let folder = folder.standardizedFileURL
            return !FileNode.samePath(folder, from) && !FileNode.samePath(folder, url) && !folder.path.hasPrefix(url.standardizedFileURL.path + "/")
        }
        // Folders as the sidebar shows them, with the symbol or emoji and colour you chose.
        func row(_ folder: URL, name: String, place: String?, symbol: String = "folder", icon: FolderIcon? = nil, section: String = "Folders") -> PaletteRow {
            PaletteRow(id: "folder:" + folder.path, section: section, title: name, detail: place,
                       symbol: icon.flatMap { $0.symbol == nil ? nil : $0.shownSymbol } ?? symbol, emoji: icon?.emoji,
                       tint: icon?.color?.color ?? Color.theme(Theme.accent), action: .moveInto(folder))
        }
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return search.sections.flatMap(\.items).compactMap { item in
                guard case .file(let folder) = item.result, allowed(folder) else { return nil }
                return row(folder, name: item.title, place: item.place, icon: item.folderIcon)
            }
        }
        var rows = workspace.locations.filter { allowed($0.url) }.map {
            row($0.url, name: $0.name, place: "Top level", symbol: $0.isICloudDrive ? "icloud" : "externaldrive")
        }
        var seen = Set<String>()
        for recent in workspace.recentURLs {
            let folder = recent.deletingLastPathComponent().standardizedFileURL
            guard allowed(folder), seen.insert(folder.path).inserted, !workspace.locations.contains(where: { FileNode.samePath($0.url, folder) }) else { continue }
            rows.append(row(folder, name: workspace.folderName(folder), place: workspace.index.entry(for: folder)?.place,
                            icon: workspace.folderIcon(for: folder), section: "Recent Folders"))
            if seen.count == 6 { break }
        }
        return rows
    }

    /// The notes a to-do can go into: as you type, those whose names match; before, the notes with to-dos, most
    /// recently changed first, and the notes you opened last.
    private func noteRows() -> [PaletteRow] {
        func isNote(_ url: URL) -> Bool {
            FileKind(url: url, isDirectory: false) == .note && !workspace.isLoose(url) && !workspace.index.isHidden(url)
        }
        func row(_ note: URL, section: String) -> PaletteRow {
            PaletteRow(id: "note:" + section + note.path, section: section, title: SearchSection.displayName(note),
                       detail: workspace.index.entry(for: note)?.place, symbol: FileKind.note.symbol, tint: Color.theme(FileKind.note.tint),
                       action: .moveTodoInto(note))
        }
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return search.sections.flatMap(\.items).compactMap { item in
                guard case .file(let note) = item.result, isNote(note) else { return nil }
                return row(note, section: "Notes")
            }
        }
        var seen = Set<String>()
        var rows: [PaletteRow] = []
        for item in workspace.todos.items where !item.isLoose && isNote(item.url) && seen.insert(item.url.path).inserted {
            rows.append(row(item.url, section: "Checklists"))
            if rows.count == 6 { break }
        }
        for recent in workspace.recentURLs where isNote(recent) && seen.insert(recent.path).inserted {
            rows.append(row(recent, section: "Recent Notes"))
            if rows.count == 12 { break }
        }
        return rows
    }

    // MARK: - Keys

    /// The row the arrow keys are on: the one chosen, while it is there, else the one Return runs.
    private func currentID(_ rows: [PaletteRow]) -> String? {
        if hasChosen, let selected, rows.contains(where: { $0.id == selected }) { return selected }
        return Self.defaultRow(in: rows)?.id
    }

    /// The row Return runs before the arrow keys choose one: the first, but not one only a bit like what was typed,
    /// so with only those New Note makes the note.
    static func defaultRow(in rows: [PaletteRow]) -> PaletteRow? {
        rows.first { !SearchSection.isSimilar($0.section) } ?? rows.first
    }

    private func move(_ delta: Int, _ rows: [PaletteRow]) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == currentID(rows) } ?? 0
        selected = rows[(index + delta + rows.count) % rows.count].id
        hasChosen = true
    }

    private func close() {
        workspace.palette = nil
        workspace.paletteSearch.clear()
        workspace.focusContent()
    }

    private func run(_ row: PaletteRow?) {
        guard let row else { return }
        #if DEBUG && os(macOS)
        DebugRemote.log("palette runs \(row.id)")
        #endif
        switch row.action {
        case .command(let command):
            workspace.palette = nil
            workspace.focusContent()
            command.run()
            // A command that opens another step of ⌘K, as Move To… does, keeps it open.
            if workspace.palette == nil { workspace.paletteSearch.clear() }
        case .result(let result):
            close()
            workspace.open(result)
            workspace.focusContent()
        case .moveInto(let folder):
            guard case .move(let url) = mode else { return }
            close()
            workspace.move(url, into: folder)
        case .moveTodoInto(let note):
            guard case .moveTodo(let todo) = mode else { return }
            close()
            workspace.moveTodo(todo, toNote: note)
        }
    }
}

/// What a step of ⌘K is about, above its field, as in Issues.
private struct ContextChip: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(Color.theme(Theme.textBody))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
    }
}

/// A key on the keyboard, as menus show shortcuts.
struct Keycap: View {
    var text: String
    var emphasized = false

    init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.theme(emphasized ? Theme.textBody : Theme.textSecondary))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// ⌘K over the window: the window dims, and a click outside closes it.
struct PaletteHost: View {
    let workspace: Workspace
    let actions: PaletteActions
    var top: CGFloat = 110

    var body: some View {
        ZStack(alignment: .top) {
            if let mode = workspace.palette {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        workspace.palette = nil
                        workspace.paletteSearch.clear()
                        workspace.focusContent()
                    }
                CommandPalette(workspace: workspace, mode: mode, actions: actions)
                    .id(mode)
                    .padding(.top, top)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transaction { $0.animation = nil }
    }
}

@MainActor
extension Workspace {
    /// ⌘K for commands, ⌘P for files, ⌥⌘F to search: the same key again closes it, another switches to its mode.
    func togglePalette(_ mode: PaletteMode = .commands) {
        if palette == mode {
            palette = nil
            paletteSearch.clear()
            focusContent()
        } else {
            paletteSearch.clear()
            palette = mode
        }
    }

    /// Go › Search (⌥⌘F): the palette searching inside notes, left open if it is.
    func openSearch() {
        if palette != .search { togglePalette(.search) }
    }

    /// Search at the top of the sidebar: ⌘P.
    func openFiles() {
        if palette != .files { togglePalette(.files) }
    }

    /// The keyboard back to what is open: the note's text, after ⌘K or search.
    func focusContent() {
        guard note?.isLoaded == true else { return }
        #if os(macOS)
        editor.makeTextFirstResponder()
        #endif
    }
}
