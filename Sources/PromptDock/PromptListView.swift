import AppKit
import SwiftUI

struct PromptListView: NSViewRepresentable {
    let prompts: [Prompt]
    let selectedID: UUID?
    let colors: LibraryColors
    let onSelect: (UUID) -> Void
    let onMove: (_ source: UUID, _ target: UUID, _ after: Bool) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 45
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.draggingDestinationFeedbackStyle = .gap
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("prompt"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.registerForDraggedTypes([PromptDragHandle.dragType])
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityLabel("提示词顺序")
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(self, table: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var list: PromptListView
        private let cellID = NSUserInterfaceItemIdentifier("promptRow")

        init(_ list: PromptListView) { self.list = list }

        func update(_ list: PromptListView, table: NSTableView) {
            let hasNewPrompts = self.list.prompts != list.prompts
            let refreshCells = self.list.selectedID != list.selectedID || self.list.colors.dark != list.colors.dark
            self.list = list
            if hasNewPrompts {
                table.reloadData()
            } else if refreshCells {
                table.enumerateAvailableRowViews { rowView, row in
                    guard let cell = rowView.view(atColumn: 0) as? NSHostingView<PromptRow> else { return }
                    cell.rootView = self.rowView(for: row)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { list.prompts.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let root = rowView(for: row)
            if let cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSHostingView<PromptRow> {
                cell.rootView = root
                return cell
            }
            let cell = NSHostingView(rootView: root)
            cell.identifier = cellID
            return cell
        }

        private func rowView(for row: Int) -> PromptRow {
            let prompt = list.prompts[row]
            return PromptRow(
                prompt: prompt,
                selected: prompt.id == list.selectedID,
                colors: list.colors,
                handle: PromptHandleView(
                    title: prompt.title, id: prompt.id,
                    up: row > 0 ? { [weak self] in self?.moveOne(prompt.id, down: false) ?? false } : nil,
                    down: row < list.prompts.count - 1 ? { [weak self] in self?.moveOne(prompt.id, down: true) ?? false } : nil
                ),
                onSelect: { [weak self] in self?.list.onSelect(prompt.id) }
            )
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard localSourceIndex(info, in: tableView) != nil else { return [] }
            let index: Int
            if operation == .on, list.prompts.indices.contains(row) {
                let location = tableView.convert(info.draggingLocation, from: nil)
                index = row + (location.y >= tableView.rect(ofRow: row).midY ? 1 : 0)
            } else {
                index = min(max(row, 0), list.prompts.count)
            }
            tableView.setDropRow(index, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, (0...list.prompts.count).contains(row),
                  let source = localSourceIndex(info, in: tableView) else { return false }
            if row == source || row == source + 1 { return true }
            let after = row == list.prompts.count
            let target = after ? row - 1 : row
            return list.onMove(list.prompts[source].id, list.prompts[target].id, after)
        }

        private func localSourceIndex(_ info: any NSDraggingInfo, in table: NSTableView) -> Int? {
            guard let handle = info.draggingSource as? PromptDragHandle, handle.table === table,
                  let id = handle.draggingID,
                  info.draggingPasteboard.string(forType: PromptDragHandle.dragType) == id.uuidString else { return nil }
            return list.prompts.firstIndex { $0.id == id }
        }

        private func moveOne(_ id: UUID, down: Bool) -> Bool {
            guard let source = list.prompts.firstIndex(where: { $0.id == id }) else { return false }
            let target = source + (down ? 1 : -1)
            guard list.prompts.indices.contains(target) else { return false }
            return list.onMove(id, list.prompts[target].id, down)
        }
    }
}

private struct PromptRow: View {
    let prompt: Prompt
    let selected: Bool
    let colors: LibraryColors
    let handle: PromptHandleView
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: prompt.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 29, height: 29)
                        .foregroundStyle(colors.accent)
                        .background(colors.icon, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prompt.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(colors.ink)
                            .lineLimit(1)
                        if !prompt.category.isEmpty {
                            Text(prompt.category)
                                .font(.system(size: 11))
                                .foregroundStyle(colors.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: 45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            handle
                .frame(width: 25, height: 37)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(colors.secondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .padding(.trailing, 4)
        }
        .background(selected ? colors.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
        .clipped()
    }
}

private struct PromptHandleView: NSViewRepresentable {
    let title: String
    let id: UUID
    let up: (() -> Bool)?
    let down: (() -> Bool)?

    func makeNSView(context: Context) -> PromptDragHandle {
        let handle = PromptDragHandle()
        handle.setAccessibilityElement(true)
        handle.setAccessibilityRole(.handle)
        handle.toolTip = "拖动排序"
        return handle
    }

    func updateNSView(_ handle: PromptDragHandle, context: Context) {
        handle.id = id
        let label = "拖动排序：\(title)"
        handle.setAccessibilityTitle(label)
        handle.setAccessibilityLabel(label)
        var actions: [NSAccessibilityCustomAction] = []
        if let up { actions.append(NSAccessibilityCustomAction(name: "上移", handler: up)) }
        if let down { actions.append(NSAccessibilityCustomAction(name: "下移", handler: down)) }
        handle.setAccessibilityCustomActions(actions)
    }
}

private final class PromptDragHandle: NSView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("local.promptdock.mac.prompt-order")

    weak var table: NSTableView?
    var id: UUID?
    private(set) var draggingID: UUID?
    private var mouseDownLocation: NSPoint?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { mouseDownLocation = event.locationInWindow }

    override func mouseUp(with event: NSEvent) { mouseDownLocation = nil }

    override func mouseDragged(with event: NSEvent) {
        let hierarchy = sequence(first: self as NSView, next: { $0.superview })
        guard let location = mouseDownLocation, let id,
              hypot(event.locationInWindow.x - location.x, event.locationInWindow.y - location.y) >= 4,
              let row = hierarchy.first(where: { $0 is NSTableRowView }),
              let table = hierarchy.first(where: { $0 is NSTableView }) as? NSTableView,
              let imageRep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return }
        mouseDownLocation = nil

        let item = NSPasteboardItem()
        guard item.setString(id.uuidString, forType: Self.dragType) else { return }
        let draggedItem = NSDraggingItem(pasteboardWriter: item)
        row.cacheDisplay(in: row.bounds, to: imageRep)
        let image = NSImage(size: row.bounds.size)
        image.addRepresentation(imageRep)
        draggedItem.setDraggingFrame(convert(row.bounds, from: row), contents: image)
        self.table = table
        draggingID = id
        beginDraggingSession(with: [draggedItem], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingID = nil
        table = nil
    }
}
