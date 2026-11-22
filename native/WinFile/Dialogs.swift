// 对话框：重命名、新建、打开方式（原生应用列表）、帮助
import AppKit
import SwiftUI

// MARK: - 重命名

struct RenameSheet: View {
    @ObservedObject private var localization = Localization.shared
    let item: FileItem
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(item: FileItem, onCommit: @escaping (String) -> Void) {
        self.item = item
        self.onCommit = onCommit
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WLocalizedString("dialog.rename.title", comment: "重命名")).font(.headline)
            TextField(WLocalizedString("dialog.name", comment: "名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 360)
            Text(WLocalizedString("dialog.rename.hint", comment: "扩展名不会被自动修改"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(WLocalizedString("button.cancel", comment: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(WLocalizedString("button.ok", comment: "好"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - 通用文本输入

struct TextInputSheet: View {
    @ObservedObject private var localization = Localization.shared
    let titleKey: String
    let defaultText: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(titleKey: String, defaultText: String, onCommit: @escaping (String) -> Void) {
        self.titleKey = titleKey
        self.defaultText = defaultText
        self.onCommit = onCommit
        _text = State(initialValue: defaultText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WLocalizedString(titleKey, comment: "对话框标题")).font(.headline)
            TextField(WLocalizedString("dialog.name", comment: "名称"), text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 340)
            HStack {
                Spacer()
                Button(WLocalizedString("button.cancel", comment: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(WLocalizedString("button.create", comment: "创建"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - 打开方式（原生应用选择列表，取代手填输入）

struct OpenWithSheet: View {
    @ObservedObject private var localization = Localization.shared
    @Environment(\.dismiss) private var dismiss
    let request: OpenWithRequest
    let onPick: (URL, Bool) -> Void
    let onSetDefault: (URL) -> Void
    private let recommended: [URL]
    private let systemDefault: URL?
    private let savedDefault: URL?
    @State private var query = ""
    @State private var selected: URL?
    @State private var remember: Bool
    @State private var showAll: Bool
    @State private var installed: [URL] = []
    @State private var loadedApplications = false
    @State private var manualApp: URL?
    @State private var applicationPath = ""
    @State private var applicationPathError = false

    init(engine: FSEngine, request: OpenWithRequest,
         onSetDefault: @escaping (URL) -> Void, onPick: @escaping (URL, Bool) -> Void) {
        self.request = request
        self.onPick = onPick
        self.onSetDefault = onSetDefault
        let item = request.item
        let saved = FileAssociations.shared.application(for: item.url)
        let system = NSWorkspace.shared.urlForApplication(toOpen: item.url)
        let suggested = engine.applications(for: item)
        savedDefault = saved?.standardizedFileURL
        systemDefault = system?.standardizedFileURL
        recommended = suggested
        _selected = State(initialValue: (saved ?? system)?.standardizedFileURL)
        _showAll = State(initialValue: suggested.isEmpty && saved == nil)
        _remember = State(initialValue: request.rememberInitially || (saved == nil && system == nil))
    }

    private var candidates: [URL] {
        var seen = Set<String>()
        return ([savedDefault, manualApp].compactMap { $0 } + recommended + (showAll ? installed : []))
            .map(\.standardizedFileURL)
            .filter { url in
                url.path != Bundle.main.bundleURL.standardizedFileURL.path && seen.insert(url.path).inserted
            }
    }

    private var filtered: [URL] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { url in
            displayName(for: url).localizedStandardContains(needle) ||
                url.deletingPathExtension().lastPathComponent.localizedStandardContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FileIconView(item: request.item, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("dialog.openWith.title", "打开方式 — %@", request.item.name)).font(.headline)
                    if let savedDefault {
                        Text(L("dialog.openWith.saved", "LeafFiles 默认：%@", displayName(for: savedDefault)))
                    } else if let systemDefault {
                        Text(L("dialog.openWith.default", "系统默认：%@", displayName(for: systemDefault)))
                    } else {
                        Text(L("dialog.openWith.noDefault", "此文件没有默认应用。请选择一个应用打开。"))
                    }
                }.foregroundStyle(.primary)
            }
            Picker(L("dialog.openWith.scope", "应用范围"), selection: $showAll) {
                Text(L("dialog.openWith.recommended", "推荐应用")).tag(false)
                Text(L("dialog.openWith.installed", "所有应用")).tag(true)
            }.pickerStyle(.segmented)

            TextField(L("dialog.openWith.search", "搜索应用…"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("openWith.search")

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.path) { app in
                        appRow(app)
                    }
                    if filtered.isEmpty {
                        if showAll && !loadedApplications { ProgressView().padding(20) }
                        else {
                            Text(L("dialog.openWith.empty", "没有匹配的应用"))
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }
                }
            }
            .frame(height: 250)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            DisclosureGroup(L("dialog.openWith.applicationPath", "输入其他应用的路径…")) {
                HStack {
                    TextField("/Applications/Example.app", text: $applicationPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L("dialog.openWith.usePath", "选用此应用")) { chooseApplicationAtPath() }
                        .disabled(applicationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 4)
                if applicationPathError {
                    Text(L("dialog.openWith.invalidApplication", "请输入一个有效的 .app 应用路径。"))
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if let ext = FileAssociations.key(for: request.item.url) {
                Toggle(L("dialog.openWith.remember", "记住 .%@ 的打开方式（仅 LeafFiles）", ext), isOn: $remember)
                    .accessibilityIdentifier("openWith.remember")
            }

            HStack {
                Spacer()
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                if FileAssociations.key(for: request.item.url) != nil {
                    Button(L("dialog.openWith.saveOnly", "仅设为默认")) {
                        guard let selected else { return }
                        onSetDefault(selected)
                        dismiss()
                    }.disabled(selected == nil)
                }
                Button(L("action.open", "打开")) {
                    guard let selected else { return }
                    onPick(selected, remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .accessibilityIdentifier("openWith.confirm")
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            let urls = await Task.detached(priority: .userInitiated) {
                FileSystemService.listApplications().map(\.url)
            }.value
            guard !Task.isCancelled else { return }
            installed = urls
            loadedApplications = true
        }
    }

    private func chooseApplicationAtPath() {
        let path = (applicationPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              url.path != Bundle.main.bundleURL.standardizedFileURL.path
        else { applicationPathError = true; return }
        applicationPathError = false
        manualApp = url
        selected = url
        query = ""
    }

    private func appRow(_ app: URL) -> some View {
        Button { selected = app } label: {
            HStack(spacing: 10) {
                AppIconView(url: app, size: 26)
                Text(displayName(for: app))
                Spacer(minLength: 0)
                if app == savedDefault {
                    Text(L("dialog.openWith.savedBadge", "LeafFiles 默认")).font(.caption2)
                } else if app == systemDefault {
                    Text(L("dialog.openWith.systemBadge", "系统默认")).font(.caption2)
                }
                if app == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(app == selected ? Color.accentColor.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.path)
        .accessibilityAddTraits(app == selected ? .isSelected : [])
    }

    private func displayName(for url: URL) -> String {
        (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

// MARK: - 应用图标

struct AppIconView: View {
    @ObservedObject private var localization = Localization.shared
    let url: URL
    var size: CGFloat = 20
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url.path) {
            let target = size * 2
            let path = url.path
            image = await Task.detached(priority: .userInitiated) {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: target, height: target)
                return ImageBox(image: icon)
            }.value.image
        }
    }
}

// MARK: - 帮助

struct HelpSheet: View {
    @ObservedObject private var localization = Localization.shared
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        [
            ("⌘C / ⌘V", WLocalizedString("help.copyPaste", comment: "复制、粘贴文件；复制时会同时写入系统剪贴板")),
            ("⌘⌥C", WLocalizedString("help.copyPath", comment: "复制所选文件的完整路径")),
            ("Return", WLocalizedString("help.rename", comment: "重命名所选项目")),
            ("⌘⌫", WLocalizedString("help.delete", comment: "移到废纸篓")),
            ("⌘⇧N", WLocalizedString("help.newFolder", comment: "新建文件夹")),
            ("⌘[ / ⌘]", WLocalizedString("help.backForward", comment: "后退 / 前进")),
            ("⌘↑", WLocalizedString("help.up", comment: "返回上一级文件夹")),
            ("⌘⇧.", WLocalizedString("help.hidden", comment: "显示或隐藏隐藏文件")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(WLocalizedString("help.title", comment: "LeafFiles 使用提示")).font(.headline)
            Text(WLocalizedString("help.intro", comment: "帮助说明"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { key, description in
                    GridRow {
                        Text(key).font(.system(.callout, design: .monospaced))
                        Text(description).font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                Button(WLocalizedString("button.ok", comment: "好")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
