import XCTest
@testable import NotebookKit

/// To-dos in the sidebar: a section after Search with the open to-dos of every note, under their notes by name. A
/// to-do ticked there is ticked in its note; notes and the section stay folded as you left them.
@MainActor
final class SidebarTodosTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Library") }
    private var trip: URL { library.appendingPathComponent("Kyoto trip.md") }
    private var doctor: URL { library.appendingPathComponent("Personal/Doctor.md") }
    private var window: NSWindow!
    private var sidebar: SidebarController?
    private let keys = ["NotebookLibrary", "expandedFolders", "collapsedSections", "collapsedTodoNotes"]

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sidebartodos-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Personal"), withIntermediateDirectories: true)
        try "- [ ] Pack the adapter\n- [ ] Print the tickets\n".write(to: trip, atomically: true, encoding: .utf8)
        try "# Doctor\n\n- [ ] Call Dr. Weber\n- [x] Book the taxi\n".write(to: doctor, atomically: true, encoding: .utf8)
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        NotebookSettings.shared.showsTodos = true
    }

    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        window?.close()
        try? FileManager.default.removeItem(at: base)
    }

    private func makeSidebar() async throws -> (Workspace, SidebarController) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        self.sidebar = sidebar
        workspace.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the to-dos were read") { !workspace.index.isBuilding && workspace.todos.isReady && self.todos(sidebar).count == 3 }
        window.layoutIfNeeded()
        return (workspace, sidebar)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func entries(_ sidebar: SidebarController) -> [SidebarEntry] {
        (0..<sidebar.outline.numberOfRows).compactMap { sidebar.outline.item(atRow: $0) as? SidebarEntry }
    }

    private func notes(_ sidebar: SidebarController) -> [String] {
        entries(sidebar).compactMap { if case .todoNote(_, let name) = $0.kind { name } else { nil } }
    }

    private func todos(_ sidebar: SidebarController) -> [String] {
        entries(sidebar).compactMap { if case .todo(let item) = $0.kind { item.todo.text } else { nil } }
    }

    private func section(_ sidebar: SidebarController) -> SidebarEntry? {
        entries(sidebar).first { $0.isHeader && $0.isTodos }
    }

    func testOpenTodosShowUnderTheirNotesByName() async throws {
        let (_, sidebar) = try await makeSidebar()
        let rows = entries(sidebar)
        XCTAssertTrue(rows[0].isSearch)
        XCTAssertTrue(rows[1].isHeader && rows[1].isTodos, "To-dos come right after Search")
        XCTAssertEqual(notes(sidebar), ["Doctor", "Kyoto trip"])
        XCTAssertEqual(todos(sidebar), ["Call Dr. Weber", "Pack the adapter", "Print the tickets"], "in each note's order, the ticked one left out")
    }

    func testTickingATodoTicksItInItsNote() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let pack = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Pack the adapter" })
        sidebar.tick(pack)
        try await until("the note was written") { (try? String(contentsOf: self.trip, encoding: .utf8))?.hasPrefix("- [x] Pack the adapter") == true }
        XCTAssertTrue(todos(sidebar).contains("Pack the adapter"), "it shows ticked for a moment")
        try await until("the ticked to-do went") { !self.todos(sidebar).contains("Pack the adapter") }
        XCTAssertEqual(todos(sidebar), ["Call Dr. Weber", "Print the tickets"])
    }

    func testTickedAgainItIsToDoAgain() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let pack = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Pack the adapter" })
        sidebar.tick(pack)
        try await until("the note was written") { (try? String(contentsOf: self.trip, encoding: .utf8))?.hasPrefix("- [x]") == true }
        sidebar.tick(pack)
        try await until("the note was written again") { (try? String(contentsOf: self.trip, encoding: .utf8))?.hasPrefix("- [ ] Pack the adapter") == true }
        try await until("it is listed again") { workspace.todos.items.contains { $0.todo.text == "Pack the adapter" } }
        XCTAssertTrue(todos(sidebar).contains("Pack the adapter"))
    }

    func testFoldedNotesAndSectionStayFolded() async throws {
        let (workspace, sidebar) = try await makeSidebar()
        let doctorRow = try XCTUnwrap(entries(sidebar).first { if case .todoNote(_, "Doctor") = $0.kind { true } else { false } })
        sidebar.outline.collapseItem(doctorRow)
        XCTAssertEqual(todos(sidebar), ["Pack the adapter", "Print the tickets"])

        let (_, again) = try await makeSidebarAgain(workspace)
        XCTAssertEqual(notes(again), ["Doctor", "Kyoto trip"])
        XCTAssertEqual(todos(again), ["Pack the adapter", "Print the tickets"], "Doctor stays folded")

        again.outline.collapseItem(try XCTUnwrap(section(again)))
        XCTAssertTrue(notes(again).isEmpty)
        let (_, third) = try await makeSidebarAgain(workspace)
        XCTAssertNotNil(section(third))
        XCTAssertTrue(notes(third).isEmpty, "the section stays folded")
    }

    /// A new sidebar on the same workspace, as when the app opens again.
    private func makeSidebarAgain(_ workspace: Workspace) async throws -> (Workspace, SidebarController) {
        let sidebar = SidebarController(workspace: workspace)
        self.sidebar = sidebar
        window.contentView!.subviews.forEach { $0.removeFromSuperview() }
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the section showed") { self.section(sidebar) != nil }
        window.layoutIfNeeded()
        return (workspace, sidebar)
    }
}
