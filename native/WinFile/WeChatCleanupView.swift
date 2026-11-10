import AppKit
import SwiftUI

struct CleanupHubView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { heading; Spacer(minLength: 12); sectionPicker }
                VStack(alignment: .leading, spacing: 10) { heading; sectionPicker }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.6)
            if model.cleanupSection == .software {
                SoftwareCleanupView(model: model, dialog: $dialog)
            } else {
                StorageCleanupView(store: model.storageCleanup, model: model, nestedInHub: true)
            }
        }.background(InterfaceStyle.canvas)
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
            Text(L("cleanup.title", "空间清理")).font(.headline)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var sectionPicker: some View {
        Picker(L("cleanup.section", "清理范围"), selection: Binding(
            get: { model.cleanupSection }, set: { model.selectCleanupSection($0) }
        )) {
            Text(L("cleanup.general", "通用清理")).tag(CleanupSection.general)
            Text(L("software.title", "软件清理")).tag(CleanupSection.software)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 260).disabled(model.isCleaningStorage)
    }

}

struct SoftwareCleanupView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: BrowserModel
    @ObservedObject var store: StorageCleanupModel
    @Binding var dialog: DialogKind?

    init(model: BrowserModel, dialog: Binding<DialogKind?>) {
        self.model = model; self.store = model.softwareCleanup; self._dialog = dialog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker(L("software.select", "选择软件"), selection: Binding(
                    get: { store.selectedSoftwareID }, set: { model.selectCleanupSoftware($0) }
                )) {
                    ForEach(store.softwareChoices) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(width: 220)
                Spacer(minLength: 8)
                if store.selectedSoftwareID == "wechat" {
                    Button { store.refreshSoftwareChoices() } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("software.refresh", "刷新软件列表"))
                        .accessibilityLabel(L("software.refresh", "刷新软件列表"))
                        .disabled(store.busy)
                }
            }
            .disabled(model.weChatCleanup.isCleaning || store.isCleaning)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if store.selectedSoftwareID == "wechat" {
                WeChatCleanupView(model: model, dialog: $dialog)
            } else {
                StorageCleanupView(store: store, model: model, nestedInHub: true)
            }
        }
        .background(InterfaceStyle.canvas)
    }
}

struct WeChatCleanupView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var store: WeChatCleanupModel
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    @State private var showAdvancedFilters = false
    @State private var showFolderPicker = false
    @State private var usageByMonth = false
    @State private var showScanDetails = false

    init(model: BrowserModel, dialog: Binding<DialogKind?>) {
        self.model = model
        self.store = model.weChatCleanup
        self._dialog = dialog
    }

    private var operationInProgress: Bool { store.isScanning || store.isCleaning || model.isBusy || model.archiveProgress != nil || model.fileTransferProgress != nil }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 560
            VStack(alignment: .leading, spacing: compact ? 6 : 12) {
                header
                if store.result.isPartial {
                    HStack {
                        Text(L("wechat.partialScan", "当前仅显示部分扫描结果，占用统计并非全部文件；可提高上限重新扫描。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("wechat.expandScan", "提高上限重新扫描")) { store.expandScan() }
                            .disabled(!store.canExpandScan)
                    }
                }
                filters
                files.frame(minHeight: 100).modifier(InsetSurface())
                footer
            }
            .controlSize(compact ? .small : .regular)
            .padding(compact ? 10 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(InterfaceStyle.canvas)
        .onAppear { if !store.hasScanned { store.scan() } }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet(title: L("wechat.choose", "选择微信文件夹…"), onSelect: store.addFolder)
        }
        .onChange(of: store.message) { if $0 != nil { showScanDetails = true } }
        .alert(L("wechat.confirmTitle", "将所选附件移到废纸篓？"), isPresented: $store.confirmsTrash) {
            Button(L("action.moveToTrash", "移到废纸篓"), role: .destructive) { store.clean(store.pendingTrashFiles) }
            Button(L("button.cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L("wechat.confirmMessage", "将清理 %d 个文件（%@）。这些附件可能无法在微信中再次打开。可从废纸篓恢复到原位置；建议先退出微信。", store.pendingTrashFiles.count,
                   FileItem.formatSize(store.pendingTrashFiles.reduce(0) { $0 + $1.size })))
        }
    }

    private var scanDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("wechat.explain", "扫描本机微信下载的聊天附件。清理后，对应附件可能无法在微信中打开；聊天数据库不会被清理。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("wechat.usage.scope", "仅统计已扫描的本机附件，不包含聊天数据库；清理后自动更新。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("wechat.choose", "选择微信文件夹…")) { showScanDetails = false; showFolderPicker = true }
                    .disabled(operationInProgress)
                if let date = store.lastScanDate {
                    Text(L("wechat.lastScan", "最后扫描：%@", FileItem.formatDate(date)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            roots
            usageAnalysis
            if store.isScanning { Text(store.scanProgress.currentPath).font(.caption).textSelection(.enabled) }
            if !store.result.inaccessible.isEmpty { accessHint }
            if let message = store.message { Text(message).font(.caption).textSelection(.enabled) }
            if !model.statusMessage.isEmpty { Text(model.statusMessage).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usageSummary: some View {
        HStack(spacing: 12) {
            Label(L("wechat.usage.compact", "附件 %d 项 · %@", store.isScanning ? store.scanProgress.files : store.result.files.count,
                    FileItem.formatSize(store.isScanning ? store.scanProgress.bytes : store.totalSize)), systemImage: "bubble.left.and.bubble.right")
            if !store.activeFilters.isEmpty {
                Text(L("wechat.usage.filtered", "当前筛选") + "  " + L("cleanup.resultCount", "%d 项 / %@", store.matchingCount, FileItem.formatSize(store.matchingSize)))
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private var usageAnalysis: some View {
        DisclosureGroup(L("wechat.usage.analysis", "占用分布（当前筛选）")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("wechat.usage.group", "分组"), selection: $usageByMonth) {
                    Text(L("inspector.type", "类型")).tag(false)
                    Text(L("wechat.month", "月份")).tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 240)
                let buckets = store.usageBuckets(byMonth: usageByMonth)
                let total = max(1, buckets.reduce(Int64(0)) { $0 + $1.bytes })
                ForEach(buckets) { bucket in
                    Button {
                        if usageByMonth { store.month = bucket.id } else { store.kind = bucket.id }
                    } label: {
                        HStack {
                            Text(bucket.title).frame(width: 110, alignment: .leading)
                            ProgressView(value: Double(bucket.bytes), total: Double(total))
                            Text(L("wechat.usage.bucket", "%@ · %d 项", FileItem.formatSize(bucket.bytes), bucket.count))
                                .monospacedDigit().frame(width: 150, alignment: .trailing)
                        }.font(.caption)
                    }.buttonStyle(.plain).help(L("wechat.usage.filter", "点击筛选此分组"))
                }
            }.padding(.top, 6).disabled(operationInProgress)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { usageSummary; scanActions }
            VStack(alignment: .leading, spacing: 8) { usageSummary; scanActions }
        }
    }

    private var scanActions: some View {
        HStack(spacing: 8) {
            Button { showScanDetails.toggle() } label: { Image(systemName: "ellipsis.circle") }
                .help(L("wechat.scanDetails", "扫描详情与占用分布"))
                .accessibilityLabel(L("wechat.scanDetails", "扫描详情与占用分布"))
                .popover(isPresented: $showScanDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView { scanDetails }.frame(maxHeight: 500)
                        HStack { Spacer(); Button(L("button.done", "完成")) { showScanDetails = false } }
                    }.padding(16).frame(width: 540)
                }
            if operationInProgress { ProgressView().controlSize(.small) }
            if store.isScanning { Button(L("button.cancel", "取消")) { store.cancelScan() } }
            else {
                Button { store.scan() } label: {
                    Label(L("appData.rescan", "重新扫描"), systemImage: "arrow.clockwise")
                }.buttonStyle(.borderedProminent).tint(InterfaceStyle.accent).disabled(operationInProgress)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var roots: some View {
        DisclosureGroup(L("wechat.sources", "扫描位置（%d 个自动发现，%d 个手动添加）",
                          store.result.roots.filter { !store.customRoots.contains($0) }.count, store.customRoots.count)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.result.roots.filter { !store.customRoots.contains($0) }, id: \.path) { root in
                        Text(root.path).font(.caption).textSelection(.enabled)
                    }
                    ForEach(store.customRoots, id: \.path) { root in
                        HStack {
                            Text(root.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(L("settings.folders.remove", "从列表移除")) { store.removeFolder(root) }
                                .disabled(operationInProgress)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 85)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("wechat.search", "按文件名筛选"), text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)
                Button {
                    showAdvancedFilters.toggle()
                } label: {
                    Label(L("cleanup.filters", "筛选"),
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showAdvancedFilters, arrowEdge: .bottom) { advancedFilters }
                .help(L("wechat.filters.advancedHint", "按账号、月份、来源、大小和修改时间筛选"))
            }
            if !store.activeFilters.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(store.activeFilters) { filter in
                                ActiveFilterChip(title: store.filterTitle(filter)) { store.clearFilter(filter) }
                            }
                        }
                    }.scrollIndicators(.hidden).frame(height: 28)
                    Button(L("wechat.filters.reset", "重置筛选")) { store.resetFilters() }
                }.font(.caption)
            }
        }.disabled(operationInProgress)
    }

    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("cleanup.filters", "筛选")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(L("inspector.type", "类型"))
                    Picker(L("inspector.type", "类型"), selection: $store.kind) {
                        Text(L("wechat.all", "全部类型")).tag("all")
                        ForEach(WeChatFileKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.account", "账号"))
                    Picker(L("wechat.account", "账号"), selection: $store.account) {
                        Text(L("wechat.allAccounts", "全部账号")).tag("all")
                        ForEach(store.accounts, id: \.self) { account in
                            Text(account == "custom" ? L("wechat.customAccount", "其它 / 自定义位置") : account).tag(account)
                        }
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.month", "月份"))
                    Picker(L("wechat.month", "月份"), selection: $store.month) {
                        Text(L("wechat.allMonths", "全部月份")).tag("all")
                        ForEach(store.months, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.source", "来源"))
                    Picker(L("wechat.source", "来源"), selection: $store.source) {
                        Text(L("wechat.allSources", "全部来源")).tag("all")
                        Text(L("wechat.attachments", "聊天附件")).tag("attachment")
                        Text(L("wechat.caches", "缓存 / 缩略图")).tag("cache")
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.minimumSize", "最小大小"))
                    Picker(L("wechat.minimumSize", "最小大小"), selection: $store.minimumMB) {
                        Text(L("wechat.anySize", "不限大小")).tag(0)
                        Text("10 MB").tag(10)
                        Text("100 MB").tag(100)
                        Text("1 GB").tag(1024)
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.age", "修改时间"))
                    Picker(L("wechat.age", "修改时间"), selection: $store.olderThanDays) {
                        Text(L("wechat.anyTime", "不限时间")).tag(0)
                        ForEach([30, 90, 180], id: \.self) { days in
                            Text(L("wechat.days", "%d 天以前", days)).tag(days)
                        }
                    }.labelsHidden()
                }
            }
            HStack {
                Button(L("wechat.filters.reset", "重置筛选")) { store.resetFilters() }
                    .disabled(store.activeFilters.isEmpty)
                Spacer()
                Button(L("button.done", "完成")) { showAdvancedFilters = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 340).disabled(operationInProgress)
    }

    private var sortOrder: Binding<[KeyPathComparator<WeChatFile>]> {
        Binding(
            get: { [WeChatSortOrderBridge.comparator(for: store.sortState.field,
                                                    ascending: store.sortState.ascending)] },
            set: { value in
                guard let first = value.first, let field = WeChatSortOrderBridge.field(for: first) else { return }
                // 一次写入：模型内部合并为单个状态，只重算一次
                store.setSort(field: field, ascending: first.order == .forward)
            }
        )
    }

    private var accessHint: some View {
        HStack(alignment: .top) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("wechat.access", "部分目录无法读取，结果可能不完整。可授予 LeafFiles 完整磁盘访问权限后重新扫描，或手动选择微信文件夹。"))
                    .font(.caption)
                DisclosureGroup(L("wechat.unreadable", "查看无法读取的位置")) {
                    ScrollView { Text(store.result.inaccessible.joined(separator: "\n")).font(.caption2).textSelection(.enabled) }
                        .frame(maxHeight: 65)
                }
            }
            Button(L("appData.openSettings", "打开系统设置")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var files: some View {
        // 用与文件列表一致的 Table(of:) + TableRow 写法：行标识明确，差异计算更稳定。
        // 数据源只给当前页（最多 200 行），避免整表重排时的超大规模 diff。
        Table(of: WeChatFile.self, selection: $store.selection, sortOrder: sortOrder) {
            TableColumn(L("column.name", "名称"), value: \WeChatFile.name, comparator: .localizedStandard) { file in
                HStack(spacing: 5) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(file.url.lastPathComponent).lineLimit(1).help(file.url.path)
                }
            }.width(min: 140, ideal: 240)
            TableColumn(L("inspector.type", "类型"), value: \WeChatFile.typeDescription, comparator: .localizedStandard) { file in Text(file.kind.title) }.width(min: 65, ideal: 85)
            TableColumn(L("column.size", "大小"), value: \WeChatFile.size) { file in Text(FileItem.formatSize(file.size)) }.width(min: 70, ideal: 90)
            TableColumn(L("column.modified", "修改日期"), value: \WeChatFile.modified) { file in Text(FileItem.formatDate(file.modified)) }.width(min: 120, ideal: 140)
            TableColumn(L("wechat.location", "所在目录"), value: \WeChatFile.parentPath, comparator: .localizedStandard) { file in
                Button { model.openContainingFolder(of: file.url) } label: {
                    Text(FileSystemService.abbreviate(file.url.deletingLastPathComponent())).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
                .help(L("action.openContainingFolder", "打开所在文件夹") + "\n" + file.url.deletingLastPathComponent().path)
            }.width(min: 150, ideal: 240)
        } rows: {
            ForEach(store.pagedFiles) { file in
                TableRow(file)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                let _ = store.selectForContextMenu(ids)
                FileItemContextMenu(engine: model.engine, model: model, dialog: $dialog,
                                    item: store.selectedFiles.first.map { FileItem(weChatFile: $0) })
            } else {
                Button(L("appData.rescan", "重新扫描")) { store.scan() }
                Button(L("wechat.selectAll", "全选筛选结果")) { model.selectAll() }
            }
        }
        .onDeleteCommand { model.deleteSelection() }
        .background(
            TableDoubleClickInstaller { table in
                TableColumnPreferences.install(on: table, kind: "wechat")
                TableDiagnostics.installDoubleClick(on: table) { row in
                    guard !operationInProgress, let item = store.itemForActivation(at: row) else { return }
                    model.activate(item)
                }
            }.frame(width: 0, height: 0)
        )
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(-1)
        .disabled(operationInProgress)
        .overlay {
            if store.matchingCount == 0 {
                VStack(spacing: 0) {
                    InterfaceStateView(symbol: "bubble.left.and.bubble.right",
                        title: store.isScanning ? L("wechat.scanning", "正在扫描微信附件…") : L("wechat.noMatch", "没有符合筛选条件的文件。"),
                        detail: store.result.files.isEmpty && !store.isScanning ? L("wechat.empty", "未发现可清理的附件。可手动选择微信数据目录；无法读取的位置请检查访问权限。") : "",
                        loading: store.isScanning)
                    if !store.activeFilters.isEmpty && !operationInProgress {
                        Button(L("wechat.filters.reset", "重置筛选")) { store.resetFilters() }.padding(.bottom, 20)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { selectionSummary; selectAllAction; Spacer(minLength: 8); pageActions; trashAction }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { selectionSummary; selectAllAction; Spacer(); pageActions }
                    HStack { Spacer(); trashAction }
                }
            }
        }
    }

    private var selectionSummary: some View {
        Text(L("cleanup.selectionSummary", "已选 %d 项 · %@", store.selectedFiles.count, FileItem.formatSize(store.selectedSize)))
            .font(.caption.weight(.medium)).monospacedDigit().fixedSize()
    }

    @ViewBuilder
    private var pageActions: some View {
        if store.matchingCount > WeChatCleanupModel.pageSize {
            HStack(spacing: 8) {
                Button { store.previousPage() } label: { Image(systemName: "chevron.left") }
                    .help(L("wechat.pagePrev", "上一页")).disabled(!store.canGoPrevious || operationInProgress)
                Text(L("wechat.page", "第 %d / %d 页", store.page + 1, store.pageCount))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button { store.nextPage() } label: { Image(systemName: "chevron.right") }
                    .help(L("wechat.pageNext", "下一页")).disabled(!store.canGoNext || operationInProgress)
            }
        }
    }

    private var selectAllAction: some View {
        Group {
            if store.selection.isEmpty {
                Button(L("wechat.selectAll", "全选筛选结果")) { store.selection = Set(store.visibleFiles.map(\.id)) }
                    .disabled(store.visibleFiles.isEmpty)
            } else {
                Button(L("wechat.clearSelection", "清除选择")) { store.selection = [] }
            }
        }.buttonStyle(.link).disabled(operationInProgress)
    }

    private var trashAction: some View {
        Button(role: .destructive) { store.requestTrash() } label: {
            Label(L("action.moveToTrash", "移到废纸篓"), systemImage: "trash")
        }.buttonStyle(TrashActionStyle()).disabled(store.selectedFiles.isEmpty || operationInProgress)
    }
}
