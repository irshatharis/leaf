#if os(iOS)
import SwiftUI

/// To-dos at the top of the iPhone's first screen and the iPad's sidebar, with how many are due.
struct HomeTodos: View {
    let workspace: Workspace
    /// Shows To-dos: its own screen on the iPhone, next to the sidebar on the iPad.
    let open: () -> Void

    var body: some View {
        if NotebookSettings.shared.showsTodos {
            Section {
                Button(action: open) {
                    LabeledContent {
                        Text(workspace.dueTodoCount, format: .number)
                    } label: {
                        Label("To-dos", systemImage: "checklist")
                    }
                }
                .tint(.primary)
                .accessibilityAddTraits(.isLink)
            }
        }
    }
}

/// A location's top level on the first screen: its folders, each with how much is in it, and its notes. A folder with
/// folders in it has an arrow that unfolds them below it, indented and quieter, as Notes shows folders in folders; a
/// tap anywhere else on the row opens it.
struct HomeFileRows: View {
    let workspace: Workspace
    let nodes: [FileNode]
    @Binding var newFolderIn: URL?
    /// The folders unfolded, by path, one to a line: kept between launches.
    @AppStorage(HomeFileRows.unfoldedKey) private var unfoldedList = ""

    static let unfoldedKey = "unfoldedFolders"

    struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: URL { node.url }
    }

    var body: some View {
        let unfolded = Set(unfoldedList.split(separator: "\n").map(String.init))
        ForEach(rows(unfolded: unfolded)) { row in
            if row.node.isFolder {
                folderRow(row, unfolded: unfolded)
            } else {
                NavigationLink(value: Page(url: row.node.url, isFolder: false)) { row.node.row(in: workspace) }
                    .fileDragAndDrop(row.node.url, isFolder: false, workspace: workspace)
                    .appContextMenu { FileActions.entries(workspace, row.node.url) { newFolderIn = $0 } }
            }
        }
    }

    private func folderRow(_ row: Row, unfolded: Set<String>) -> some View {
        let url = row.node.url
        let canFold = !(workspace.shownSubfolders(of: url) ?? []).isEmpty
        let isUnfolded = canFold && unfolded.contains(url.path)
        let count = workspace.shownCount(of: url)
        return NavigationLink(value: Page(url: url, isFolder: true)) {
            HStack(spacing: 6) {
                row.node.row(in: workspace, isQuiet: row.depth > 0)
                    .padding(.leading, CGFloat(row.depth) * 28)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if canFold {
                    Button { fold(url, unfolded: unfolded) } label: {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(isUnfolded ? 90 : 0))
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                }
            }
        }
        // The arrow says it folds; the row's own chevron would say it opens, twice.
        .navigationLinkIndicatorVisibility(canFold ? .hidden : .automatic)
        .fileDragAndDrop(url, isFolder: true, workspace: workspace)
        .appContextMenu { FileActions.entries(workspace, url) { newFolderIn = $0 } }
        .accessibilityValue(count.map { "\($0) items" } ?? "")
        .accessibilityActions {
            if canFold {
                Button(isUnfolded ? "Hide Folders Inside" : "Show Folders Inside") { fold(url, unfolded: unfolded) }
            }
        }
    }

    private func fold(_ url: URL, unfolded: Set<String>) {
        var unfolded = unfolded
        if unfolded.contains(url.path) { unfolded.remove(url.path) } else { unfolded.insert(url.path) }
        withAnimation { unfoldedList = unfolded.sorted().joined(separator: "\n") }
    }

    /// The nodes, each followed by the folders in it when it is unfolded, and so on down.
    private func rows(unfolded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func add(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isFolder, depth < 8, unfolded.contains(node.url.path), let subfolders = workspace.shownSubfolders(of: node.url) {
                    add(subfolders, depth: depth + 1)
                }
            }
        }
        add(nodes, depth: 0)
        return rows
    }
}

/// The files kept on their own, under the folders on the first screen: each opens its screen, and a swipe or its menu
/// takes it off the list, leaving the file where it is.
struct KeptFileRows: View {
    let workspace: Workspace
    @Binding var newFolderIn: URL?

    var body: some View {
        let kept = workspace.keptFileURLs
        if !kept.isEmpty {
            Section("Files") {
                ForEach(kept, id: \.self) { url in
                    NavigationLink(value: Page(url: url, isFolder: false)) { workspace.row(for: url) }
                        .fileDragAndDrop(url, isFolder: false, workspace: workspace)
                        .appContextMenu { FileActions.entries(workspace, url) { newFolderIn = $0 } }
                        .swipeActions(edge: .trailing) {
                            Button { withAnimation { workspace.removeKeptFile(url) } } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .tint(.red)
                        }
                }
            }
        }
    }
}
#endif
