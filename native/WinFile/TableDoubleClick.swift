// 文件列表的双击打开
//
// 为什么不用 SwiftUI 的手势：
//   - `.onTapGesture(count: 2)` 与系统双击竞争，实测抢不到；
//   - `Table` 的 `primaryAction` 在右键/选择状态变化后可能不触发。
// 因此直接在底层 `NSTableView` 上挂 `doubleAction` —— 这是 AppKit 的原生机制，最可靠。
import AppKit
import SwiftUI

/// 把自己所属的 NSTableView 交给回调（用于安装双击处理）
struct TableDoubleClickInstaller: NSViewRepresentable {
    var marqueeSelection: ((IndexSet) -> Void)? = nil
    let install: (NSTableView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.install = install
        view.marqueeSelection = marqueeSelection
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let installer = view as? InstallerView else { return }
        installer.install = install
        installer.marqueeSelection = marqueeSelection
        installer.scheduleAttach()
    }


    final class InstallerView: NSView {
        var install: ((NSTableView) -> Void)?
        var marqueeSelection: ((IndexSet) -> Void)?
        private var marquee: TableMarqueeSelection?
        private weak var installed: NSTableView?
        private var retryCount = 0
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { marquee = nil }
            retryCount = 0
            scheduleAttach()
        }

        override func layout() {
            super.layout()
            scheduleAttach()
        }

        func scheduleAttach() {
            guard window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.attach()
            }
        }

        @MainActor
        private func attach() {
            guard let window else { return }
            // SwiftUI may insert the sidebar before the file table has a frame.
            // Match the background marker's actual region rather than picking a
            // table elsewhere in the window, and retry after the next layout.
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView { tables.append(table) }
                for child in view.subviews { collect(child) }
            }
            collect(window.contentView ?? NSView())
            let anchor = convert(NSPoint.zero, to: nil)
            let candidates = tables.filter { table in
                guard let region = table.enclosingScrollView, !region.isHidden else { return false }
                return region.convert(region.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(anchor)
            }
            guard let target = candidates.max(by: { $0.bounds.width < $1.bounds.width }) else {
                if retryCount < 20 {
                    retryCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.scheduleAttach() }
                }
                return
            }
            if let marqueeSelection {
                if marquee?.table !== target { marquee = TableMarqueeSelection(table: target) }
                marquee?.onSelection = marqueeSelection
            } else { marquee = nil }
            // SwiftUI can replace a table's target/action after installation.
            // Reattach on the next layout instead of trusting the old table identity.
            if target === installed, target.target is DoubleClickProxy,
               target.doubleAction == #selector(DoubleClickProxy.handleDoubleClick(_:)) { return }
            installed = target
            install?(target)
        }
    }
}

/// A transparent overlay stays above native table rows without intercepting input.
final class MarqueeOverlayView: NSView {
    var selectionRect: NSRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let rect = selectionRect, !rect.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.fill()
        path.stroke()
    }
}

/// Dragging from the empty area below table rows selects intersected rows.
@MainActor
final class TableMarqueeSelection {
    weak var table: NSTableView?
    var onSelection: ((IndexSet) -> Void)?
    private var monitor: Any?
    private var start: NSPoint?
    private var base = IndexSet()
    private var windowPoint = NSPoint.zero
    private var dragging = false
    private var timer: Timer?
    private var publishTimer: Timer?
    private var pendingRows: IndexSet?
    private var lastPublishedRows = IndexSet()
    private let overlay = MarqueeOverlayView(frame: .zero)

    init(table: NSTableView) {
        self.table = table
        if let scroll = table.enclosingScrollView {
            overlay.frame = scroll.contentView.frame
            overlay.autoresizingMask = [.width, .height]
            scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer?.invalidate()
        publishTimer?.invalidate()
        let view = overlay
        MainActor.assumeIsolated { view.removeFromSuperview() }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let table, let scroll = table.enclosingScrollView, let window = table.window else { return event }
        if start != nil {
            if event.type == .leftMouseUp {
                windowPoint = event.locationInWindow
                update()
                finish(commit: true)
                return nil
            }
            guard event.type == .leftMouseDragged else { return event }
            windowPoint = event.locationInWindow
            update()
            return nil
        }
        guard event.type == .leftMouseDown, event.window === window, event.clickCount == 1,
              let root = window.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
              hit === table || hit.isDescendant(of: table) else { return event }
        let point = table.convert(event.locationInWindow, from: nil)
        guard table.visibleRect.contains(point), table.row(at: point) == -1 else { return event }
        start = point
        windowPoint = event.locationInWindow
        base = event.modifierFlags.intersection([.command, .shift]).isEmpty ? [] : table.selectedRowIndexes
        lastPublishedRows = table.selectedRowIndexes
        if base.isEmpty && !table.selectedRowIndexes.isEmpty { lastPublishedRows = []; onSelection?([]) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscroll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .eventTracking) }
        _ = scroll
        return nil
    }
    private func update() {
        guard let table, let start else { return }
        let point = table.convert(windowPoint, from: nil)
        if !dragging && hypot(point.x - start.x, point.y - start.y) < 3 { return }
        dragging = true
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        if let scroll = table.enclosingScrollView {
            overlay.frame = scroll.contentView.frame
            overlay.selectionRect = overlay.convert(rect, from: table)
        }
        var rows = base
        let range = table.rows(in: rect)
        if range.location != NSNotFound && range.length > 0 {
            rows.insert(integersIn: range.location..<(range.location + range.length))
        }
        guard rows != (pendingRows ?? lastPublishedRows) else { return }
        pendingRows = rows
        if publishTimer == nil {
            let next = Timer(timeInterval: 1.0 / 30.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishSelection() }
            }
            publishTimer = next
            RunLoop.main.add(next, forMode: .common)
            RunLoop.main.add(next, forMode: .eventTracking)
        }
    }
    private func publishSelection() {
        publishTimer?.invalidate(); publishTimer = nil
        guard let rows = pendingRows else { return }
        pendingRows = nil
        guard rows != lastPublishedRows else { return }
        lastPublishedRows = rows
        onSelection?(rows)
    }
    private func autoscroll() {
        guard dragging, let scroll = table?.enclosingScrollView else { return }
        if Self.scrollNearEdge(scroll, pointer: scroll.contentView.convert(windowPoint, from: nil)) {
            update()
        }
    }

    @discardableResult
    static func scrollNearEdge(_ scroll: NSScrollView, pointer: NSPoint) -> Bool {
        let clip = scroll.contentView
        let bounds = clip.bounds
        let top = min(bounds.midY, bounds.minY + clip.contentInsets.top + 28)
        let bottom = max(bounds.midY, bounds.maxY - clip.contentInsets.bottom - 28)
        let delta: CGFloat
        if pointer.y < top { delta = -12 }
        else if pointer.y > bottom { delta = 12 }
        else { return false }
        // AppKit positions the top of a table below its header using a negative clip origin.
        let constrained = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: delta))
        guard constrained.minY != bounds.minY else { return false }
        clip.scroll(to: NSPoint(x: bounds.minX, y: constrained.minY))
        scroll.reflectScrolledClipView(clip)
        return true
    }
    private func finish(commit: Bool = false) {
        if commit { publishSelection() }
        else { publishTimer?.invalidate(); publishTimer = nil; pendingRows = nil }
        timer?.invalidate(); timer = nil
        start = nil; dragging = false; overlay.selectionRect = nil
    }
}

enum TableDiagnostics {

    /// 给表格安装双击处理。
    ///
    /// 用 `doubleAction` 而非事件监听：前者由 AppKit 在识别到双击时调用，
    /// 且调用前第一次点击已完成行选中，因此可用 `selectedRow` 判定目标行。
    @MainActor
    static func installDoubleClick(on table: NSTableView, handler: @escaping (Int) -> Void) {
        let proxy = DoubleClickProxy(handler: handler)
        table.target = proxy
        table.doubleAction = #selector(DoubleClickProxy.handleDoubleClick(_:))
        // 让 proxy 随表格存活
        objc_setAssociatedObject(table, &DoubleClickProxy.key, proxy, .OBJC_ASSOCIATION_RETAIN)
        TabDiagnostics.shared.record("doubleClick.installed",
                                     detail: "表格宽度 \(Int(table.bounds.width)) 行数 \(table.numberOfRows)")
    }
}

/// doubleAction 的接收者（NSTableView 用 target/action，必须是 Objective-C 对象）
final class DoubleClickProxy: NSObject {
    static var key: UInt8 = 0
    private let handler: (Int) -> Void

    init(handler: @escaping (Int) -> Void) {
        self.handler = handler
    }

    @objc func handleDoubleClick(_ sender: NSTableView) {
        MainActor.assumeIsolated { perform(sender) }
    }

    @MainActor
    private func perform(_ table: NSTableView) {
        // clickedRow 在双击时有效；退回到 selectedRow
        var row = table.clickedRow
        if row < 0 { row = table.selectedRow }
        TabDiagnostics.shared.record("doubleClick.fired",
                                     detail: "行=\(row) 行数=\(table.numberOfRows)")
        handler(row)
    }
}
