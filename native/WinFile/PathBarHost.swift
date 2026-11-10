// 地址栏（面包屑 + 路径补全）
//
// 关键：本视图用 @ObservedObject **直接持有** BrowserModel。
// 这些界面原先挂在 MainView 上、通过计算属性取模型 —— 计算属性不建立观察依赖，
// 于是同一页签内导航后地址栏不会重绘，表现为"路径只有切换页签时才变"。
import AppKit
import SwiftUI

struct PathBarHost: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var editingPath: Bool
    @Binding var pathText: String
    @StateObject private var editingRegions = PathEditingRegions()
    let suggestions: [PathSuggestion]
    let onCommitPath: () -> Void
    let onTextChange: (String) -> Void
    let onAcceptSuggestion: (PathSuggestion, Bool) -> Void
    let onCancelEdit: () -> Void
    let onBeginEditing: () -> Void

    var body: some View {
        // 登记当前地址栏身份与求值次数：供自动化测试定位"哪一层没有重绘"
        WindowBridge.shared.pathBarEvaluations += 1
        WindowBridge.shared.currentAddressIdentity = addressIdentity

        return addressContent
    }

    /// 当前地址栏应表达的位置（路径或页面名）：用作视图身份，路径变化即强制重建
    var addressIdentity: String {
        if model.isCleanupView { return "page:storageCleanup" }
        if model.isHomeView { return "page:home" }
        if model.isThisPCView { return "page:thispc" }
        if model.isCategoryView { return "page:category:\(model.categoryFilter?.rawValue ?? "")" }
        if let dir = model.currentDirectory { return "path:\(dir.path)" }
        return "page:unknown"
    }

    var addressContent: some View {
        ZStack(alignment: .leading) {
            if editingPath {
                PathField(
                    text: $pathText,
                    regions: editingRegions,
                    suggestions: suggestions,
                    onSubmit: { value in
                        pathText = value
                        onCommitPath()
                    },
                    onCancel: {
                        editingPath = false
                        onCancelEdit()
                    },
                    onTextChange: { value in
                        pathText = value
                        onTextChange(value)
                    },
                    onAcceptSuggestion: { suggestion, descend in
                        onAcceptSuggestion(suggestion, descend)
                    }
                )
            } else {
                HStack(spacing: 2) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 2) {
                            ForEach(Array(crumbSegments.enumerated()), id: \.offset) { index, segment in
                                if index > 0 { crumbSeparator }
                                crumbButton(segment, isFirst: index == 0, isLast: index == crumbSegments.count - 1)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        ForEach(Array(stride(from: crumbSegments.count - 1, through: 1, by: -1)), id: \.self) { count in
                            collapsedPath(visibleCount: count)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        // If even the final folder name is too long, truncate it while
                        // keeping the overflow menu and edit button accessible.
                        collapsedPath(visibleCount: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onBeginEditing() }
                    .help(WLocalizedString("path.hint", comment: "双击可编辑路径，支持补全"))

                    if !model.isAndroidPath {
                        Button(action: onBeginEditing) {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                                .frame(width: 26, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(L("path.edit", "输入路径"))
                        .accessibilityLabel(L("path.edit", "输入路径"))
                        .accessibilityIdentifier("path.edit")
                        .layoutPriority(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .overlay(alignment: .topLeading) {
            if editingPath && !suggestions.isEmpty {
                PathSuggestionList(suggestions: suggestions) { suggestion in
                    onAcceptSuggestion(suggestion, false)
                }
                .background(PathSuggestionRegion(regions: editingRegions))
                .offset(y: 30)
                .zIndex(10)
            }
        }
    }

    private func collapsedPath(visibleCount: Int) -> some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Array(crumbSegments.enumerated()), id: \.offset) { _, segment in
                    Button { model.selectFolder(segment.url) } label: {
                        Label(segment.title, systemImage: segment.symbol)
                    }
                    .help(segment.url.path)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("path.showAll", "显示完整路径"))
            .accessibilityLabel(L("path.showAll", "显示完整路径"))
            .accessibilityIdentifier("path.showAll")
            .disabled(model.isCleanupView)
            ForEach(Array(crumbSegments.suffix(visibleCount).enumerated()), id: \.offset) { index, segment in
                crumbSeparator
                crumbButton(segment, isFirst: false, isLast: index == min(visibleCount, crumbSegments.count) - 1)
            }
        }
    }

    private var crumbSeparator: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    private func crumbButton(_ segment: Crumb, isFirst: Bool, isLast: Bool) -> some View {
        Button { model.selectFolder(segment.url) } label: {
            HStack(spacing: 4) {
                if isFirst { Image(systemName: segment.symbol) }
                Text(segment.title).lineLimit(1).truncationMode(.middle)
                    .fontWeight(isLast ? .semibold : .regular)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .disabled(model.isCleanupView)
        .buttonStyle(.borderless)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(isLast ? Color.accentColor.opacity(0.12) : .clear))
        .help(segment.url.path)
    }

    struct Crumb { let title: String; let url: URL; let symbol: String }

    var crumbSegments: [Crumb] {
        if model.isHomeView {
            return [Crumb(title: L("view.home", "主页"),
                          url: FileSystemService.realHomeDirectory(), symbol: "house.fill")]
        }
        if model.isThisPCView {
            return [Crumb(title: L("view.thisPC", "此电脑"),
                          url: URL(fileURLWithPath: "/"), symbol: "pc")]
        }
        guard let dir = model.currentDirectory else {
            return [Crumb(title: model.windowSubtitle, url: engine.browsableRoots.first ?? URL(fileURLWithPath: "/"),
                          symbol: "square.grid.2x2")]
        }
        if let (serial, _) = AndroidURL.split(dir) {
            return AndroidURL.ancestors(dir).enumerated().map { index, url in
                Crumb(title: index == 0
                      ? (AndroidDeviceRegistry.shared.device(serial: serial)?.displayName ?? L("view.androidDevice", "安卓设备"))
                      : url.lastPathComponent,
                      url: url, symbol: index == 0 ? "candybarphone" : "folder")
            }
        }
        let components = dir.pathComponents
        var result: [Crumb] = []
        var accumulated = URL(fileURLWithPath: "/")
        for (index, component) in components.enumerated() {
            if index == 0 {
                result.append(Crumb(title: WLocalizedString("place.macintoshHD", comment: "启动磁盘"),
                                    url: accumulated, symbol: "internaldrive"))
                continue
            }
            accumulated.appendPathComponent(component)
            let title: String
            if component == FileSystemService.realHomeDirectory().lastPathComponent {
                title = WLocalizedString("place.home", comment: "个人文件夹")
            } else if component == "var" || component == "private" {
                title = component
            } else {
                title = component
            }
            result.append(Crumb(title: title, url: accumulated, symbol: "folder"))
        }
        return result
    }
}
