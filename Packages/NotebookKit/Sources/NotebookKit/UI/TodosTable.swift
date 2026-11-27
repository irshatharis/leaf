#if os(macOS)
import AppKit
import SwiftUI

/// A row of To-dos on the Mac, as the table lays it out.
enum TodosTableRow: Equatable {
    case header
    /// A group's name. `isEmpty` while a to-do is dragged and the group has none: it says what dropping there does.
    case title(TodoSection.Kind, isEmpty: Bool)
    /// A to-do or a reminded note. Being edited, it keeps the id it had when editing began, while its line changes.
    case todo(TodoRow, TodoSection.Kind, editing: TodoEditing?)
    case newTodo(TodoSection.Kind)
    /// Room after the last group.
    case end

    var id: String {
        switch self {
        case .header: "header"
        case .title(let kind, _): "title\u{0}\(kind.rawValue)"
        case .todo(let row, _, let editing): editing?.rowID ?? row.id
        case .newTodo(let kind): "new\u{0}\(kind.rawValue)"
        case .end: "end"
        }
    }

    var kind: TodoSection.Kind? {
        switch self {
        case .title(let kind, _), .todo(_, let kind, _), .newTodo(let kind): kind
        case .header, .end: nil
        }
    }

    var editing: TodoEditing? {
        if case .todo(_, _, let editing) = self { editing } else { nil }
    }

    static func == (a: TodosTableRow, b: TodosTableRow) -> Bool {
        switch (a, b) {
        case (.header, .header), (.end, .end): true
        case let (.title(kind, empty), .title(otherKind, otherEmpty)): kind == otherKind && empty == otherEmpty
        case let (.todo(row, kind, editing), .todo(otherRow, otherKind, otherEditing)):
            row == otherRow && kind == otherKind && editing === otherEditing
        case let (.newTodo(kind), .newTodo(otherKind)): kind == otherKind
        default: false
        }
    }
}

/// What the table shows: its rows, and how they look.
struct TodosTableModel {
    var rows: [TodosTableRow] = []
    /// Rows just ticked, still there for a moment.
    var ticked: Set<String> = []
    var selected: String?
    var isListFocused = false
    /// The group a dragged to-do is over.
    var dropTarget: TodoSection.Kind?
    /// Limited to a folder, a to-do's note shows with the folders on the way to it.
    var folder: URL?
    var scroll: TodosScrollRequest?
}

/// A row to scroll to; asked again for the same row, it scrolls again.
struct TodosScrollRequest: Equatable {
    let id: String
    private let token = UUID()

    init(_ id: String) { self.id = id }
}

/// The keys of the row selected.
enum TodosKey { case up, down, delete, enter, escape }

/// What the table asks To-dos to do.
struct TodosTableActions {
    var header: () -> AnyView
    var editingRow: (TodoRow, TodoSection.Kind, TodoEditing) -> AnyView
    var tick: (TodoRow, TodoSection.Kind) -> Void
    var edit: (TodoList.Item, Int?) -> Void
    var open: (TodoRow) -> Void
    /// Remind Me, by `rect` of `view`.
    var ask: (TodoRow, NSView, NSRect) -> Void
    /// The row's right-click menu, with Remind Me where it shows.
    var menu: (TodoRow, TodoSection.Kind, @escaping () -> Void) -> [MenuEntry]
    var select: (TodoRow) -> Void
    var newTodo: (TodoSection.Kind) -> Void
    var endEditing: () -> Void
    /// True when the key did something.
    var key: (TodosKey) -> Bool
    var focused: (Bool) -> Void
    var dragging: (Bool) -> Void
    var target: (TodoSection.Kind?) -> Void
    var drop: ([String], TodoSection.Kind) -> Bool
    var scrolledAway: (Bool) -> Void
    /// Where the to-do being edited is, in the window's content from its top.
    var editingFrame: (CGRect) -> Void
}

/// To-dos on the Mac: a table of rows drawn by AppKit, as the sidebar's, which scroll at the display's rate. The to-do
/// being edited is SwiftUI, in its row.
struct TodosTable: NSViewRepresentable {
    let workspace: Workspace
    let model: TodosTableModel
    let actions: TodosTableActions

    func makeCoordinator() -> TodosTableController { TodosTableController(workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(model, actions: actions)
    }
}

@MainActor
final class TodosTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let workspace: Workspace
    let table = TodosTableView()
    let scrollView = NSScrollView()
    private var model = TodosTableModel()
    private(set) var actions: TodosTableActions?
    /// The to-dos' rows measured, by id, for the width they were measured at.
    private var layouts: [String: TodoCellLayout] = [:]
    private var header: TodosHosted?
    private var editingHost: (session: TodoEditing, hosted: TodosHosted)?
    private var isScrolledAway = false
    private var editingFrame: CGRect?
    private var dropTarget: TodoSection.Kind?
    private var hoveredRow = -1
    private var isHoverQueued = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("todos"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.controller = self
        table.registerForDraggedTypes([.string])
        table.draggingDestinationFeedbackStyle = .none
        table.setAccessibilityLabel("To-dos")
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// The column the to-dos are in: at most `TodosView.width` wide, in the middle, with a margin either side.
    var column: (x: CGFloat, width: CGFloat) {
        let width = max(160, min(TodosView.width, table.bounds.width - 2 * TodosView.margin))
        return ((table.bounds.width - width) / 2, width)
    }

    // MARK: - Updating

    func update(_ new: TodosTableModel, actions: TodosTableActions) {
        self.actions = actions
        let old = model
        model = new
        header?.set(actions.header())
        if let editingHost {
            if case .todo(let row, let kind, let session?)? = new.rows.first(where: { $0.editing === editingHost.session }) {
                editingHost.hosted.set(actions.editingRow(row, kind, session))
            } else {
                self.editingHost = nil
            }
        }
        if old.folder != new.folder { layouts = [:] }

        let oldIDs = old.rows.map(\.id), newIDs = new.rows.map(\.id)
        let before = Dictionary(old.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in newIDs where before[id] == nil { layouts[id] = nil }
        if oldIDs != newIDs {
            if !old.rows.isEmpty, let changes = RowChanges(from: oldIDs, to: newIDs, limit: 60) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    table.beginUpdates()
                    for step in changes.steps {
                        switch step {
                        case .remove(let index): table.removeRows(at: [index], withAnimation: .effectFade)
                        case .move(let from, let to): table.moveRow(at: from, to: to)
                        case .insert(let index): table.insertRows(at: [index], withAnimation: .effectFade)
                        }
                    }
                    table.endUpdates()
                }
            } else {
                table.reloadData()
            }
        }
        // Rows that stay and show something else: a to-do changed in its note, ticked, edited or done editing.
        var changed = IndexSet()
        var ticked: [Int] = []
        for (index, row) in new.rows.enumerated() {
            guard let was = before[row.id] else { continue }
            let isTicked = new.ticked.contains(row.id)
            guard was != row || old.ticked.contains(row.id) != isTicked else { continue }
            changed.insert(index)
            layouts[row.id] = nil
            if isTicked { ticked.append(index) }
        }
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            table.noteHeightOfRows(withIndexesChanged: changed)
            for index in ticked { (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TodoCell)?.pop() }
        }
        if layouts.count > new.rows.count + 100 {
            let shown = Set(newIDs)
            layouts = layouts.filter { shown.contains($0.key) }
        }
        if old.selected != new.selected || old.isListFocused != new.isListFocused || old.dropTarget != new.dropTarget {
            table.enumerateAvailableRowViews { view, row in decorate(view, row: row) }
        }
        if new.isListFocused, !old.isListFocused, let window = table.window, window.firstResponder !== table {
            window.makeFirstResponder(table)
        }
        if let request = new.scroll, request != old.scroll, let row = newIDs.firstIndex(of: request.id) {
            scrollToVisible(row)
        }
        DispatchQueue.main.async { [weak self] in
            self?.reportEditingFrame()
            self?.updateHover()
        }
    }

    /// The table took another width: the to-dos' words wrap anew.
    func widthChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.table.numberOfRows > 0 else { return }
            self.layouts = [:]
            let all = IndexSet(integersIn: 0..<self.table.numberOfRows)
            self.table.noteHeightOfRows(withIndexesChanged: all)
            let shown = self.table.rows(in: self.table.visibleRect)
            self.table.reloadData(forRowIndexes: IndexSet(integersIn: shown.location..<NSMaxRange(shown)), columnIndexes: [0])
            self.table.enumerateAvailableRowViews { view, row in self.decorate(view, row: row) }
        }
    }

    private func scrollToVisible(_ row: Int) {
        let rect = table.rect(ofRow: row)
        let shown = table.visibleRect
        guard rect.minY < shown.minY || rect.maxY > shown.maxY else { return }
        let clip = scrollView.contentView
        let y = rect.minY < shown.minY ? clip.bounds.minY - (shown.minY - rect.minY) - 20 : clip.bounds.minY + (rect.maxY - shown.maxY) + 20
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        let away = scrollView.contentView.bounds.minY + scrollView.contentInsets.top > 70
        if away != isScrolledAway {
            isScrolledAway = away
            actions?.scrolledAway(away)
        }
        reportEditingFrame()
        queueHoverUpdate()
    }

    private func reportEditingFrame() {
        guard let index = model.rows.firstIndex(where: { $0.editing.map { !$0.isEnded } ?? false }), index < table.numberOfRows,
              let content = table.window?.contentView else {
            editingFrame = nil
            return
        }
        var rect = table.rect(ofRow: index)
        rect.origin.x = column.x
        rect.size.width = column.width
        rect.size.height -= TodosRowView.divider
        let inWindow = table.convert(rect, to: nil)
        let frame = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        guard frame != editingFrame else { return }
        editingFrame = frame
        actions?.editingFrame(frame)
    }

    // MARK: - Rows

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard model.rows.indices.contains(row) else { return 1 }
        let width = column.width
        switch model.rows[row] {
        case .header: return max(1, headerHosted().height(for: width))
        case .title(_, let isEmpty): return TodosTitleCell.height(isEmpty: isEmpty)
        case .newTodo: return NewTodoCell.height
        case .end: return 60
        case .todo(let todo, let kind, let editing):
            if let editing { return editingHosted(todo, kind, editing).height(for: width) + TodosRowView.divider }
            return layout(of: todo, kind: kind).height + TodosRowView.divider
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (x, width) = column
        switch model.rows[row] {
        case .header:
            return TodosHostCell(hosting: headerHosted().controller.view, x: x, width: width, bottom: 0)
        case .title(let kind, let isEmpty):
            let cell = tableView.makeView(withIdentifier: TodosTitleCell.identifier, owner: nil) as? TodosTitleCell ?? TodosTitleCell()
            cell.configure(kind, isEmpty: isEmpty, x: x)
            return cell
        case .newTodo(let kind):
            let cell = tableView.makeView(withIdentifier: NewTodoCell.identifier, owner: nil) as? NewTodoCell ?? NewTodoCell()
            cell.configure(kind, x: x)
            return cell
        case .end:
            return nil
        case .todo(let todo, let kind, let editing):
            if let editing {
                return TodosHostCell(hosting: editingHosted(todo, kind, editing).controller.view, x: x, width: width, bottom: TodosRowView.divider)
            }
            let cell = tableView.makeView(withIdentifier: TodoCell.identifier, owner: nil) as? TodoCell ?? TodoCell()
            cell.configure(layout(of: todo, kind: kind), x: x)
            cell.setAccessibilityCustomActions(accessibilityActions(todo, kind))
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: TodosRowView.identifier, owner: nil) as? TodosRowView ?? TodosRowView()
        decorate(view, row: row)
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        queueHoverUpdate()
    }

    private func decorate(_ view: NSTableRowView, row: Int) {
        guard let view = view as? TodosRowView, model.rows.indices.contains(row) else { return }
        let item = model.rows[row]
        view.column = column
        view.hasDivider = { if case .todo = item { true } else { false } }()
        view.isSelectedRow = item.id == model.selected && item.editing == nil
        view.isFocused = model.isListFocused
        if let target = model.dropTarget, item.kind == target {
            let isTitle = { if case .title = item { true } else { false } }()
            view.panel = (first: isTitle, last: model.rows.indices.contains(row + 1) ? model.rows[row + 1].kind != target : true)
        } else {
            view.panel = nil
        }
    }

    private func layout(of row: TodoRow, kind: TodoSection.Kind) -> TodoCellLayout {
        let width = column.width
        if let cached = layouts[row.id], cached.width == width { return cached }
        let layout = TodoCellLayout(row: row, section: kind, isTicked: model.ticked.contains(row.id), folder: model.folder, width: width)
        layouts[row.id] = layout
        return layout
    }

    private func headerHosted() -> TodosHosted {
        if let header { return header }
        let hosted = TodosHosted(actions?.header() ?? AnyView(EmptyView()))
        hosted.sizeChanged = { [weak self] in self?.hostedSizeChanged("header") }
        header = hosted
        return hosted
    }

    private func editingHosted(_ row: TodoRow, _ kind: TodoSection.Kind, _ session: TodoEditing) -> TodosHosted {
        if let editingHost, editingHost.session === session { return editingHost.hosted }
        let hosted = TodosHosted(actions?.editingRow(row, kind, session) ?? AnyView(EmptyView()))
        hosted.sizeChanged = { [weak self, weak session] in
            guard let session else { return }
            self?.hostedSizeChanged(session.rowID)
        }
        editingHost = (session, hosted)
        return hosted
    }

    /// A row of SwiftUI grew or shrank: the buttons of the to-do being edited came or went.
    private func hostedSizeChanged(_ id: String) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }), index < table.numberOfRows else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            table.noteHeightOfRows(withIndexesChanged: [index])
        }
        DispatchQueue.main.async { [weak self] in self?.reportEditingFrame() }
    }

    private func accessibilityActions(_ row: TodoRow, _ kind: TodoSection.Kind) -> [NSAccessibilityCustomAction] {
        var actions = [NSAccessibilityCustomAction(name: model.ticked.contains(row.id) ? "Not Done" : "Mark as Done") { [weak self] in
            self?.actions?.tick(row, kind)
            return true
        }]
        if case .todo(let item) = row {
            actions.append(NSAccessibilityCustomAction(name: "Edit") { [weak self] in
                self?.actions?.edit(item, nil)
                return true
            })
        }
        actions.append(NSAccessibilityCustomAction(name: "Open Note") { [weak self] in
            self?.actions?.open(row)
            return true
        })
        return actions
    }

    // MARK: - Clicks and keys

    func mouseDown(_ event: NSEvent) {
        guard let actions else { return }
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard model.rows.indices.contains(index) else { return actions.endEditing() }
        switch model.rows[index] {
        case .header, .title, .end:
            actions.endEditing()
        case .newTodo(let kind):
            actions.newTodo(kind)
        case .todo(let row, let kind, let editing):
            guard editing == nil, let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TodoCell else { return }
            let point = cell.convert(event.locationInWindow, from: nil)
            let hit = cell.hit(at: point)
            // A circle is a button; anywhere else a press can be the start of a drag to another group.
            switch hit?.target {
            case .circle, .lineCircle: break
            default: guard table.clickOrDrag(event, row: index, id: row.id) else { return }
            }
            perform(hit, at: point, on: row, in: kind, cell: cell)
        }
    }

    private func perform(_ hit: (target: TodoCellLayout.Target, frame: CGRect)?, at point: NSPoint, on row: TodoRow, in kind: TodoSection.Kind, cell: TodoCell) {
        guard let actions else { return }
        guard let hit else { return actions.select(row) }
        switch hit.target {
        case .circle:
            actions.tick(row, kind)
        case .title:
            guard case .todo(let item) = row else { return actions.open(row) }
            // The words read as they are written, unless they have Markdown in them: then the caret goes to the end.
            let plain = Todos.parts(of: item.todo.source)?.words == item.todo.text
            let inWords = CGPoint(x: point.x - hit.frame.minX, y: point.y - hit.frame.minY)
            actions.edit(item, plain ? TodoText.offset(at: inWords, in: item.todo.text, width: hit.frame.width, size: TodosView.titleSize) : nil)
        case .lineCircle(let line):
            if case .todo(let item) = row { workspace.toggle(line, under: item) }
        case .line:
            if case .todo(let item) = row { actions.edit(item, nil) }
        case .when, .place, .info:
            actions.ask(row, cell, hit.frame)
        case .note:
            actions.open(row)
        }
    }

    func showMenu(for event: NSEvent) {
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard model.rows.indices.contains(index), case .todo(let row, let kind, nil) = model.rows[index], let actions,
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TodoCell else { return }
        let entries = actions.menu(row, kind) { [weak cell] in
            guard let cell else { return }
            actions.ask(row, cell, cell.infoFrame)
        }
        GlassMenu.show(entries, at: event, in: table)
    }

    // MARK: - Under the pointer

    func queueHoverUpdate() {
        guard !isHoverQueued else { return }
        isHoverQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.isHoverQueued = false
            self?.updateHover()
        }
    }

    func updateHover() {
        var row = -1
        var point = NSPoint.zero
        if let window = table.window, window.isKeyWindow {
            point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if table.visibleRect.contains(point) { row = table.row(at: point) }
        }
        if hoveredRow != row, hoveredRow >= 0, hoveredRow < table.numberOfRows {
            (table.view(atColumn: 0, row: hoveredRow, makeIfNecessary: false) as? TodosHoverable)?.hover(at: nil)
        }
        hoveredRow = row
        if row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TodosHoverable & NSView {
            cell.hover(at: cell.convert(point, from: table))
        }
    }

    // MARK: - Dragging to another group

    func setDropTarget(_ kind: TodoSection.Kind?) {
        guard kind != dropTarget else { return }
        dropTarget = kind
        actions?.target(kind)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !Self.todoIDs(info).isEmpty, let kind = kind(at: row, dropOperation), kind != .overdue else {
            setDropTarget(nil)
            return []
        }
        setDropTarget(kind)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let kind = kind(at: row, dropOperation)
        setDropTarget(nil)
        guard let kind, let actions else { return false }
        return actions.drop(Self.todoIDs(info), kind)
    }

    /// The group a drop at a row goes into: the row's, or for a drop between rows the one above's.
    private func kind(at row: Int, _ operation: NSTableView.DropOperation) -> TodoSection.Kind? {
        let rows = model.rows
        if operation == .on, rows.indices.contains(row) { return rows[row].kind }
        return (rows.indices.contains(row - 1) ? rows[row - 1].kind : nil) ?? (rows.indices.contains(row) ? rows[row].kind : nil)
    }

    private static func todoIDs(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []).filter { $0.hasPrefix(TodosView.dragPrefix) }
    }
}

/// The table: a press on a row is a click or the start of a drag, a right-click its menu in glass, and the arrows,
/// Delete, Return and Escape the keys of the row selected.
final class TodosTableView: NSTableView {
    weak var controller: TodosTableController?
    private var hoverArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.mouseDown(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if GlassMenu.isContextClick(event), let controller {
            controller.showMenu(for: event)
            return nil
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if let key = flags.isEmpty ? Self.key(event.keyCode) : nil, controller?.actions?.key(key) == true { return }
        super.keyDown(with: event)
    }

    private static func key(_ code: UInt16) -> TodosKey? {
        switch code {
        case 125: .down
        case 126: .up
        case 51, 117: .delete
        case 36, 76: .enter
        case 53: .escape
        default: nil
        }
    }

    /// Edit › Delete.
    @objc func delete(_ sender: Any?) {
        if controller?.actions?.key(.delete) != true { beep() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.controller?.actions?.focused(true) } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.controller?.actions?.focused(false) } }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { controller?.widthChanged() }
    }

    // MARK: Pressed

    /// Follows the pointer after a press on a row: true when it comes up near where it went down, a click; false when
    /// it moved away, and the row was dragged instead.
    func clickOrDrag(_ event: NSEvent, row: Int, id: String) -> Bool {
        guard let window else { return true }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { return true }
            guard hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 else { continue }
            drag(row: row, id: id, event: next)
            return false
        }
        return true
    }

    private func drag(row: Int, id: String, event: NSEvent) {
        guard let rowView = rowView(atRow: row, makeIfNecessary: false) else { return }
        let item = NSDraggingItem(pasteboardWriter: (TodosView.dragPrefix + id) as NSString)
        let bounds = rowView.bounds
        if let picture = rowView.bitmapImageRepForCachingDisplay(in: bounds) {
            rowView.cacheDisplay(in: bounds, to: picture)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(picture)
            item.setDraggingFrame(rowView.frame, contents: image)
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        controller?.actions?.dragging(true)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.setDropTarget(nil)
        controller?.actions?.dragging(false)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        controller?.setDropTarget(nil)
    }

    // MARK: Under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.updateHover()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controller?.updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.updateHover()
    }
}

/// A row of the table. It draws what is behind the row's cell: the selection, a group's panel lit up while a to-do is
/// dragged over it, and the line under a to-do.
final class TodosRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("todosRow")
    static let divider: CGFloat = 1

    var column: (x: CGFloat, width: CGFloat) = (0, 0) { didSet { needsDisplay = true } }
    var hasDivider = false { didSet { if hasDivider != oldValue { needsDisplay = true } } }
    var isSelectedRow = false { didSet { if isSelectedRow != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    /// The row is part of the group lit up: the group's first row rounds its top, its last its bottom.
    var panel: (first: Bool, last: Bool)? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Clicks go to the table, except in the to-do being edited.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let around = NSRect(x: column.x - 8, y: 0, width: column.width + 16, height: bounds.height)
        if let panel {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: around).setClip()
            var shape = around
            if !panel.first { shape.origin.y -= 10; shape.size.height += 10 }
            if !panel.last { shape.size.height += 10 }
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: shape, xRadius: 10, yRadius: 10).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if isSelectedRow {
            (isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: around.insetBy(dx: 0, dy: 0).divided(atDistance: hasDivider ? Self.divider : 0, from: .maxYEdge).remainder,
                         xRadius: 8, yRadius: 8).fill()
        }
        if hasDivider {
            NSColor.separatorColor.setFill()
            let lead = TodoCircle.side + 10
            NSRect(x: column.x + lead, y: bounds.height - Self.divider, width: column.width - lead, height: Self.divider).fill()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        panel = nil
        isSelectedRow = false
    }
}

/// A cell that answers the pointer over it.
@MainActor
protocol TodosHoverable: AnyObject {
    /// Where the pointer is in the cell; nil once it left.
    func hover(at point: NSPoint?)
}

/// A to-do's row, drawn as `TodoCellLayout` places it: its circle, its words, the lines under it and its details.
final class TodoCell: NSView, TodosHoverable {
    static let identifier = NSUserInterfaceItemIdentifier("todo")
    private let circle = TodoCircleView()
    private(set) var layout: TodoCellLayout?
    private var x: CGFloat = 0
    private var isHovered = false
    private var isLinkHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        addSubview(circle)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ layout: TodoCellLayout, x: CGFloat) {
        self.layout = layout
        self.x = x
        circle.frame = layout.circle.offsetBy(dx: x, dy: 0)
        circle.mark = layout.mark
        setAccessibilityLabel(layout.label)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Ticked: the circle pops a little, as Reminders' circles do.
    func pop() { circle.pop() }

    /// Remind Me's button, where it shows under the pointer.
    var infoFrame: CGRect { (layout?.info ?? .zero).offsetBy(dx: x, dy: 0) }

    /// What a click at `point` is on, and where that is in the cell.
    func hit(at point: NSPoint) -> (target: TodoCellLayout.Target, frame: CGRect)? {
        guard let layout else { return nil }
        let local = NSPoint(x: point.x - x, y: point.y)
        guard let hit = layout.targets.first(where: { $0.frame.contains(local) }) else { return nil }
        return (hit.target, hit.frame.offsetBy(dx: x, dy: 0))
    }

    func hover(at point: NSPoint?) {
        let link = point.map { point in layout?.link.map { $0.hover.offsetBy(dx: x, dy: 0).contains(point) } ?? false } ?? false
        guard (point != nil) != isHovered || link != isLinkHovered else { return }
        isHovered = point != nil
        isLinkHovered = link
        needsDisplay = true
    }

    override func resetCursorRects() {
        if let link = layout?.link { addCursorRect(link.hover.offsetBy(dx: x, dy: 0), cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        for text in layout.texts {
            text.string.draw(with: text.frame.offsetBy(dx: x, dy: 0), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        for line in layout.circles { TodoCircleView.draw(line.mark, in: line.frame.offsetBy(dx: x, dy: 0)) }
        for symbol in layout.symbols { TodoSymbols.draw(symbol.image, in: symbol.frame.offsetBy(dx: x, dy: 0), color: symbol.color) }
        if let link = layout.link {
            let color = isLinkHovered ? NSColor.controlAccentColor : Theme.textTertiary
            if isLinkHovered {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: link.hover.offsetBy(dx: x, dy: 0), xRadius: 5, yRadius: 5).fill()
            }
            TodoSymbols.draw(link.symbol.image, in: link.symbol.frame.offsetBy(dx: x, dy: 0), color: color)
            TodoCellLayout.text(link.name, TodoCellLayout.metaFont, color, breaking: link.truncation)
                .draw(with: link.text.offsetBy(dx: x, dy: 0), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        if isHovered, let info = TodoSymbols.image("info.circle", size: 14) {
            TodoSymbols.draw(info, in: layout.info.offsetBy(dx: x, dy: 0), color: .controlAccentColor)
        }
    }
}

/// A to-do's row measured and placed for a width, once: what `TodoCell` draws and what a click there is on. As
/// `TodoRowView` lays it out: the circle beside the words, then the lines under it, how many more, and its details.
@MainActor
struct TodoCellLayout {
    enum Target: Equatable { case circle, title, lineCircle(Int), line, when, place, note, info }
    struct Text { var string: NSAttributedString; var frame: CGRect }
    struct Symbol { var image: NSImage; var frame: CGRect; var color: NSColor }
    struct Link { var name: String; var truncation: NSLineBreakMode; var symbol: Symbol; var text: CGRect; var hover: CGRect }

    static let titleFont = NSFont.systemFont(ofSize: TodosView.titleSize)
    static let notesFont = NSFont.systemFont(ofSize: TodosView.notesSize)
    static let metaFont = NSFont.systemFont(ofSize: TodosView.metaSize)
    private static let bulletFont = NSFont.systemFont(ofSize: TodosView.notesSize, weight: .bold)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: TodosView.notesSize, weight: .regular)
    private static let padding: CGFloat = 9

    let width: CGFloat
    private(set) var height: CGFloat = 0
    let mark: TaskMark
    private(set) var circle: CGRect = .zero
    private(set) var info: CGRect = .zero
    private(set) var texts: [Text] = []
    private(set) var symbols: [Symbol] = []
    private(set) var circles: [(mark: TaskMark, frame: CGRect)] = []
    private(set) var link: Link?
    /// What a click lands on, the first that holds the point.
    private(set) var targets: [(frame: CGRect, target: Target)] = []
    /// For VoiceOver: the words, when, where and the note.
    private(set) var label = ""

    init(row: TodoRow, section: TodoSection.Kind, isTicked: Bool, folder: URL?, width: CGFloat) {
        self.width = width
        mark = isTicked ? .done : row.mark
        let tertiary = Theme.textTertiary
        let side = TodoCircle.side
        let textX = side + 10
        let infoSize = TodoSymbols.image("info.circle", size: 14)?.size ?? CGSize(width: 16, height: 16)
        let textWidth = max(60, width - textX - 10 - infoSize.width)
        let textEnd = textX + textWidth

        let title = Self.text(row.title, Self.titleFont, isTicked || row.mark == .cancelled ? tertiary : Theme.text, strike: row.mark == .cancelled)
        let titleFrame = CGRect(x: textX, y: 0, width: textWidth, height: Self.measure(title, width: textWidth).height)
        texts.append(Text(string: title, frame: titleFrame))
        // The circle and Remind Me sit on the words' first line: the circle's middle a little above its baseline.
        let baseline = Self.titleFont.ascender
        circle = CGRect(x: 0, y: baseline - side / 2 - TodoCircle.lift, width: side, height: side)
        info = CGRect(x: width - infoSize.width, y: baseline - infoSize.height + 2, width: infoSize.width, height: infoSize.height)
        targets = [(circle.insetBy(dx: -6, dy: -6), .circle), (info.insetBy(dx: -4, dy: -4), .info), (titleFrame, .title)]
        var y = titleFrame.maxY

        if case .todo(let item) = row {
            let shown = item.todo.lines.enumerated().filter { $0.element.kind != .blank && $0.element.kind != .other && !$0.element.text.isEmpty }
            for (offset, line) in shown.prefix(TodoRowView.shownLines) {
                y += 3
                let small = side * 0.78
                var x = textX + CGFloat(line.depth - 1) * TodosView.indentStep
                let lineBaseline = y + Self.notesFont.ascender
                switch line.kind {
                case .todo(let lineMark):
                    let frame = CGRect(x: x, y: lineBaseline - small / 2 - TodoCircle.lift * small / side, width: small, height: small)
                    circles.append((lineMark, frame))
                    targets.append((frame.insetBy(dx: -5, dy: -5), .lineCircle(offset)))
                    x += small + 6
                case .bullet:
                    let bullet = Self.text("•", Self.bulletFont, tertiary)
                    let size = bullet.size()
                    texts.append(Text(string: bullet, frame: CGRect(x: x + (small - size.width) / 2, y: y, width: ceil(size.width), height: ceil(size.height))))
                    x += small + 6
                case .ordered(let number):
                    let marker = Self.text(number, Self.numberFont, tertiary)
                    let size = marker.size()
                    let markerWidth = max(small, ceil(size.width))
                    texts.append(Text(string: marker, frame: CGRect(x: x + markerWidth - ceil(size.width), y: y, width: ceil(size.width), height: ceil(size.height))))
                    x += markerWidth + 6
                default:
                    break
                }
                let color: NSColor = if case .todo(let lineMark) = line.kind { lineMark.isClosed ? tertiary : Theme.text } else { Theme.textSecondary }
                let words = Self.text(line.text, Self.notesFont, color, strike: line.kind == .todo(.cancelled))
                let wordsWidth = max(20, textEnd - x)
                let frame = CGRect(x: x, y: y, width: wordsWidth, height: Self.measure(words, width: wordsWidth, lines: line.kind == .text ? 3 : 2).height)
                texts.append(Text(string: words, frame: frame))
                targets.append((CGRect(x: textX, y: y, width: textWidth, height: frame.height), .line))
                y = frame.maxY
            }
            if shown.count > TodoRowView.shownLines {
                y += 3
                let more = Self.text("\(shown.count - TodoRowView.shownLines) more", Self.notesFont, tertiary)
                let frame = CGRect(x: textX, y: y, width: textWidth, height: Self.lineHeight(Self.notesFont))
                texts.append(Text(string: more, frame: frame))
                targets.append((frame, .line))
                y = frame.maxY
            }
        }

        var details: [(symbol: String, words: String, color: NSColor, target: Target?)] = []
        let when = row.when(in: section)
        if let when {
            details.append((row.hasTime ? "bell.fill" : "calendar", when, row.isOverdue && !isTicked ? .systemRed : Theme.textSecondary, .when))
        }
        if let place = row.place {
            details.append(("location.fill", place.leaving ? "Leaving " + place.name : place.name, tertiary, .place))
        }
        var linkName: String?
        switch row {
        case .todo(let item):
            for field in item.todo.fields where [.priority, .repeats, .scheduled, .start].contains(field.kind) {
                details.append((field.symbol, field.label(), tertiary, nil))
            }
            // One in no note shows none; limited to a folder, the folders on the way too.
            if !item.isLoose { linkName = folder.map(item.place(under:)) ?? item.note }
        case .note:
            linkName = "Note"
        }
        if !details.isEmpty || linkName != nil {
            y += 3
            let lineHeight = Self.lineHeight(Self.metaFont)
            var x = textX
            for detail in details {
                guard let image = TodoSymbols.image(detail.symbol, size: TodosView.metaSize, scale: .small) else { continue }
                let icon = CGRect(x: x, y: y + (lineHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
                symbols.append(Symbol(image: image, frame: icon, color: detail.color))
                x = icon.maxX + 3
                let words = Self.text(detail.words, Self.metaFont, detail.color, breaking: .byTruncatingTail)
                let frame = CGRect(x: x, y: y, width: min(ceil(words.size().width), max(0, textEnd - x)), height: lineHeight)
                texts.append(Text(string: words, frame: frame))
                if let target = detail.target { targets.append((CGRect(x: icon.minX, y: y, width: frame.maxX - icon.minX, height: lineHeight), target)) }
                x = frame.maxX + 10
            }
            if let linkName, let image = TodoSymbols.image("doc.text", size: TodosView.metaSize, scale: .small) {
                let icon = CGRect(x: x, y: y + (lineHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
                let natural = ceil(Self.text(linkName, Self.metaFont, tertiary).size().width)
                let words = CGRect(x: icon.maxX + 3, y: y, width: max(0, min(natural, textEnd - icon.maxX - 3)), height: lineHeight)
                let hover = CGRect(x: icon.minX - 5, y: y - 2, width: words.maxX - icon.minX + 10, height: lineHeight + 4)
                link = Link(name: linkName, truncation: folder == nil ? .byTruncatingTail : .byTruncatingMiddle,
                            symbol: Symbol(image: image, frame: icon, color: tertiary), text: words, hover: hover)
                targets.append((hover, .note))
            }
            y += lineHeight
        }

        // Rows start and end as far from the circle or the words, whichever is higher, as SwiftUI's padding puts them.
        let top = min(0, circle.minY, info.minY)
        let shift = Self.padding - top
        circle = circle.offsetBy(dx: 0, dy: shift)
        info = info.offsetBy(dx: 0, dy: shift)
        texts = texts.map { Text(string: $0.string, frame: $0.frame.offsetBy(dx: 0, dy: shift)) }
        symbols = symbols.map { Symbol(image: $0.image, frame: $0.frame.offsetBy(dx: 0, dy: shift), color: $0.color) }
        circles = circles.map { ($0.mark, $0.frame.offsetBy(dx: 0, dy: shift)) }
        targets = targets.map { ($0.frame.offsetBy(dx: 0, dy: shift), $0.target) }
        if var moved = link {
            moved.symbol.frame = moved.symbol.frame.offsetBy(dx: 0, dy: shift)
            moved.text = moved.text.offsetBy(dx: 0, dy: shift)
            moved.hover = moved.hover.offsetBy(dx: 0, dy: shift)
            link = moved
        }
        height = ceil(y + shift + Self.padding)
        label = [row.title, when, row.place?.name, linkName].compactMap { $0 }.joined(separator: ", ")
    }

    static func text(_ string: String, _ font: NSFont, _ color: NSColor, strike: Bool = false,
                     breaking: NSLineBreakMode = .byWordWrapping) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = breaking
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// How tall `string` is wrapped at `width`, at most `lines` lines.
    static func measure(_ string: NSAttributedString, width: CGFloat, lines: Int? = nil) -> CGSize {
        let bounds = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        var height = ceil(bounds.height)
        if let lines, string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            height = min(height, ceil(lineHeight(font) * CGFloat(lines)))
        }
        return CGSize(width: ceil(bounds.width), height: height)
    }

    private static var lineHeights: [NSFont: CGFloat] = [:]

    static func lineHeight(_ font: NSFont) -> CGFloat {
        if let height = lineHeights[font] { return height }
        let height = NSAttributedString(string: "Xg", attributes: [.font: font])
            .boundingRect(with: CGSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        lineHeights[font] = height
        return height
    }
}

/// Symbols drawn in a colour of their own, made once per size.
@MainActor
enum TodoSymbols {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) -> NSImage? {
        let key = "\(name) \(size) \(weight.rawValue) \(scale.rawValue)"
        if let image = images[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale))
        images[key] = image
        return image
    }

    static func draw(_ image: NSImage, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The circle to tick, as `TodoCircle` draws it in SwiftUI, and the editor in a note.
final class TodoCircleView: NSView {
    var mark: TaskMark = .open { didSet { if mark != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(mark, in: bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func pop() {
        guard let layer else { return }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ scale: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(middle.x, middle.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(transform, -middle.x, -middle.y, 0))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [scaled(1), scaled(1.22), scaled(0.96), scaled(1)]
        animation.keyTimes = [0, 0.25, 0.7, 1]
        animation.duration = 0.43
        layer.add(animation, forKey: "pop")
    }

    static func draw(_ mark: TaskMark, in rect: CGRect) {
        let side = rect.width
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        switch mark {
        case .done, .cancelled:
            (mark == .done ? NSColor.controlAccentColor : Theme.faint).setFill()
            NSBezierPath(ovalIn: rect).fill()
            drawSymbol(mark == .done ? "checkmark" : "xmark", side * 0.5, .bold, .white, in: rect)
        case .inProgress:
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: rect.midX, y: rect.minY, width: side / 2, height: side)).setClip()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            NSGraphicsContext.restoreGraphicsState()
        default:
            Theme.faint.setStroke()
            ring.stroke()
            if let symbol = mark.symbol {
                drawSymbol(symbol, side * 0.5, .bold, Theme.textSecondary, in: rect)
            } else if case .other(let character) = mark {
                let text = TodoCellLayout.text(String(character), .systemFont(ofSize: side * 0.6, weight: .semibold), Theme.textSecondary)
                let size = text.size()
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
    }

    private static func drawSymbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, in rect: CGRect) {
        guard let image = TodoSymbols.image(name, size: size, weight: weight) else { return }
        let frame = CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        TodoSymbols.draw(image, in: frame, color: color)
    }
}

/// A group's name; while a to-do is dragged and the group has none, what dropping it there does.
final class TodosTitleCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("todosTitle")
    private static let font = NSFont.systemFont(ofSize: TodosView.sectionSize, weight: .semibold)
    private static let hintFont = NSFont.systemFont(ofSize: 13)
    private var kind = TodoSection.Kind.today
    private var isEmpty = false
    private var x: CGFloat = 0

    static func height(isEmpty: Bool) -> CGFloat {
        22 + TodoCellLayout.lineHeight(font) + 4 + (isEmpty ? 40 : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ kind: TodoSection.Kind, isEmpty: Bool, x: CGFloat) {
        self.kind = kind
        self.isEmpty = isEmpty
        self.x = x
        setAccessibilityLabel(TodoSection(kind: kind, rows: []).title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = TodoCellLayout.text(TodoSection(kind: kind, rows: []).title, Self.font, kind == .overdue ? .systemRed : Theme.text)
        title.draw(at: CGPoint(x: x, y: 22))
        guard isEmpty else { return }
        let hint = TodoCellLayout.text(TodosView.dropHint(kind), Self.hintFont, Theme.textTertiary)
        let top = 22 + TodoCellLayout.lineHeight(Self.font) + 4
        hint.draw(at: CGPoint(x: x + TodoCircle.side + 10, y: top + (40 - hint.size().height) / 2))
    }
}

/// New To-do at the end of a group, as Reminders adds a reminder on a day: quiet until pointed at.
final class NewTodoCell: NSView, TodosHoverable {
    static let identifier = NSUserInterfaceItemIdentifier("newTodo")
    static let height = 9 + TodoCellLayout.lineHeight(TodoCellLayout.titleFont) + 9
    private var x: CGFloat = 0
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ kind: TodoSection.Kind, x: CGFloat) {
        self.x = x
        setAccessibilityLabel("New To-do in \(TodoSection(kind: kind, rows: []).title)")
        needsDisplay = true
    }

    func hover(at point: NSPoint?) {
        guard (point != nil) != isHovered else { return }
        isHovered = point != nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = isHovered ? NSColor.controlAccentColor : Theme.textTertiary
        let words = TodoCellLayout.text("New To-do", TodoCellLayout.titleFont, color)
        let lineHeight = TodoCellLayout.lineHeight(TodoCellLayout.titleFont)
        words.draw(at: CGPoint(x: x + TodoCircle.side + 10, y: 9))
        if let plus = TodoSymbols.image("plus", size: TodosView.titleSize * 0.85, weight: .medium) {
            let frame = CGRect(x: x + (TodoCircle.side - plus.size.width) / 2, y: 9 + (lineHeight - plus.size.height) / 2,
                               width: plus.size.width, height: plus.size.height)
            TodoSymbols.draw(plus, in: frame, color: color)
        }
    }
}

/// A row that is SwiftUI: the page's header, or the to-do being edited.
final class TodosHostCell: NSView {
    private let x: CGFloat
    private let width: CGFloat
    private let bottom: CGFloat

    init(hosting view: NSView, x: CGFloat, width: CGFloat, bottom: CGFloat) {
        self.x = x
        self.width = width
        self.bottom = bottom
        super.init(frame: .zero)
        addSubview(view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        subviews.first?.frame = CGRect(x: x, y: 0, width: width, height: max(0, bounds.height - bottom))
    }
}

/// SwiftUI in a row, measured for the column's width; it says when what it shows grows or shrinks.
@MainActor
final class TodosHosted {
    let controller: NSHostingController<AnyView>
    var sizeChanged: (() -> Void)?
    private var observation: NSKeyValueObservation?

    init(_ view: AnyView) {
        controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        controller.safeAreaRegions = []
        observation = controller.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.sizeChanged?() }
        }
    }

    func set(_ view: AnyView) {
        controller.rootView = view
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil(controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// Where the keyboard is in the to-do being edited, for To-dos and the row being edited, which are SwiftUI apart.
@MainActor
@Observable
final class TodoFocusBox {
    var value: TodoFocus?
}

/// The to-do being edited, in its row of the table: SwiftUI's fields, with the keyboard where To-dos puts it.
struct TodoEditingRow: View {
    let workspace: Workspace
    let row: TodoRow
    let section: TodoSection.Kind
    let isTicked: Bool
    let editing: TodoEditing
    let focusBox: TodoFocusBox
    var tick: () -> Void
    var edit: (TodoList.Item, Int?) -> Void
    var endEditing: () -> Void
    var returned: () -> Void
    var delete: () -> Void
    @FocusState private var focus: TodoFocus?

    var body: some View {
        TodoRowView(workspace: workspace, row: row, section: section, isTicked: isTicked, editing: editing, focus: $focus,
                    tick: tick, edit: edit, endEditing: endEditing, returned: returned, delete: delete)
            .onAppear { focus = focusBox.value }
            .onChange(of: focus) { _, new in if focusBox.value != new { focusBox.value = new } }
            .onChange(of: focusBox.value) { _, new in if focus != new { focus = new } }
    }
}
#endif
