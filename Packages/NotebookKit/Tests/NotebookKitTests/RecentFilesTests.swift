import XCTest
@testable import NotebookKit

/// What you opened last. The iPhone's first screen lists the note you are in too, so going back to it doesn't put the
/// note's row in once you are there; menus, search and ⌘K leave it out.
@MainActor
final class RecentFilesTests: XCTestCase {
    private var library: URL!
    private var groceries: URL { library.appendingPathComponent("Groceries.md") }
    private var trip: URL { library.appendingPathComponent("Trip.md") }

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-recent-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "Milk, eggs.\n".write(to: groceries, atomically: true, encoding: .utf8)
        try "Five days in October.\n".write(to: trip, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName"] { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: library)
    }

    private func readWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        workspace.start()
        let end = Date().addingTimeInterval(5)
        while !(workspace.hasReadLocations && workspace.reader.isIdle) {
            guard Date() < end else { throw XCTSkip("the library was never read") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return workspace
    }

    func testTheOpenNoteIsRecentOnlyWhereAskedFor() async throws {
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(trip)
        XCTAssertEqual(workspace.recentURLs.map(\.lastPathComponent), ["Groceries.md"])
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Groceries.md"])
    }

    /// A renamed file keeps its place among the files opened last, under its new name.
    func testARenamedFileKeepsItsPlace() async throws {
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(trip)
        let shopping = library.appendingPathComponent("Shopping.md")
        try await rename(groceries, to: shopping, in: workspace)
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Shopping.md"])
    }

    /// A file from a folder that is no longer one of the locations isn't recent any more: Notebook can't
    /// read it (on the Mac the sandbox shows that it is there, but not what is in it).
    func testFilesOutsideTheLocationsAreLeftOut() async throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-elsewhere-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("Solution strategy.adoc")
        try "== Solution Strategy\n".write(to: outside, atomically: true, encoding: .utf8)
        let workspace = try await readWorkspace()
        workspace.open(groceries)
        workspace.open(outside)
        workspace.open(trip)
        XCTAssertEqual(workspace.recentURLs(includingOpen: true).map(\.lastPathComponent), ["Trip.md", "Groceries.md"])
        XCTAssertTrue(workspace.recents.contains(outside.path), "kept, for when the folder is added again")
    }

    private func rename(_ url: URL, to new: URL, in workspace: Workspace) async throws {
        _ = await workspace.rename(url, to: new.deletingPathExtension().lastPathComponent).value
        let end = Date().addingTimeInterval(5)
        while workspace.recents.contains(url.path) || !FileManager.default.fileExists(atPath: new.path) {
            guard Date() < end else { return XCTFail("never renamed") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
