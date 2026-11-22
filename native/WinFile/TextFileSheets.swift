import AppKit
import SwiftUI

private struct TextFileTemplate: Codable, Identifiable {
    let id: UUID
    var title: String
    var filename: String
    var contents: String
}

struct NewTextFileSheet: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("UserTextFileTemplates") private var savedTemplates = Data()
    @State private var filename = L("default.newFileName", "未命名.txt")
    @State private var contents = ""
    @State private var templateTitle = ""
    @State private var error: String?

    private var templates: [TextFileTemplate] {
        (try? JSONDecoder().decode([TextFileTemplate].self, from: savedTemplates)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("processing.text.new", "从模板新建文件")).font(.headline)
            Menu(L("processing.template.choose", "选用模板")) {
                ForEach(["txt", "md", "csv", "json"], id: \.self) { ext in
                    Button(L("processing.template.blank", "空白 .%@", ext)) {
                        filename = L("processing.text.untitled", "未命名") + "." + ext
                        contents = ext == "json" ? "{}\n" : ""
                        templateTitle = ""
                        error = nil
                    }
                }
                if !templates.isEmpty { Divider() }
                ForEach(templates) { template in
                    Button(template.title) {
                        filename = template.filename
                        contents = template.contents
                        templateTitle = template.title
                        error = nil
                    }
                }
            }
            TextField(L("processing.filename", "输出文件名"), text: $filename)
            Text(directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(directory.path)
            TextEditor(text: $contents).font(.system(.body, design: .monospaced))
                .frame(height: 175).border(.quaternary)
                .accessibilityLabel(L("processing.text.content", "文本内容"))
            DisclosureGroup(L("processing.template.manage", "自定义模板")) {
                HStack {
                    TextField(L("processing.template.name", "模板名称"), text: $templateTitle)
                    Button(L("processing.template.save", "保存为模板")) { saveTemplate() }
                        .disabled(templateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !templates.isEmpty {
                        Menu(L("processing.template.remove", "移除模板")) {
                            ForEach(templates) { template in
                                Button(template.title) { store(templates.filter { $0.id != template.id }) }
                            }
                        }
                    }
                }.padding(.top, 6)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("processing.text.create", "创建文件")) { create() }.keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 540).textFieldStyle(.roundedBorder)
    }

    private func store(_ templates: [TextFileTemplate]) {
        do { savedTemplates = try JSONEncoder().encode(templates); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func saveTemplate() {
        let title = templateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try FileProcessingService.outputURL(in: directory, name: filename)
            guard contents.utf8.count <= 64 * 1024, templates.count < 30, title.count <= 80 else {
                error = L("processing.template.limit", "最多保存 30 个模板，每个最多 64 KB，模板名称最多 80 字。")
                return
            }
            guard !templates.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else {
                error = L("processing.template.exists", "这个模板名称已存在，请换一个名称。")
                return
            }
            store(templates + [TextFileTemplate(id: UUID(), title: title, filename: filename, contents: contents)])
        } catch { self.error = error.localizedDescription }
    }

    private func create() {
        do {
            guard contents.utf8.count <= EditableTextFile.sizeLimit else { throw FileProcessingError.largeText }
            let target = try FileProcessingService.outputURL(in: directory, name: filename)
            try FileProcessingService.writeNew(Data(contents.utf8), to: target)
            NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct TextFileEditorSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var document: EditableTextFile?
    @State private var draft = ""
    @State private var error: String?
    @State private var busy = true
    @State private var confirmingSave = false
    @State private var confirmingClose = false

    private var changed: Bool { document.map { !$0.text.utf8.elementsEqual(draft.utf8) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).help(url.path)
                Spacer()
                if let document { Text(document.encodingName).font(.caption).foregroundStyle(.secondary) }
            }
            if document != nil {
                TextEditor(text: $draft).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280).border(.quaternary)
                    .accessibilityLabel(L("processing.text.content", "文本内容"))
                    .disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("button.close", "关闭")) {
                    if changed { confirmingClose = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if document != nil {
                    Button(L("processing.text.saveCopy", "另存为 UTF-8…")) { saveCopy() }
                    Button(L("processing.text.save", "保存…")) { confirmingSave = true }
                        .keyboardShortcut("s", modifiers: .command).disabled(!changed)
                }
            }.disabled(busy)
        }
        .padding(20).frame(width: 690)
        .interactiveDismissDisabled(changed || busy)
        .task {
            do {
                let document = try await Task.detached(priority: .userInitiated) { try EditableTextFile.open(url) }.value
                self.document = document
                draft = document.text
            } catch { self.error = error.localizedDescription }
            busy = false
        }
        .alert(L("processing.text.confirmSave", "保存对原文件的修改？"), isPresented: $confirmingSave) {
            Button(L("processing.text.confirm", "保存")) { save() }
            Button(L("button.cancel", "取消"), role: .cancel) {}
        } message: { Text(url.lastPathComponent) }
        .alert(L("processing.text.discard", "放弃未保存的修改？"), isPresented: $confirmingClose) {
            Button(L("processing.text.discardConfirm", "放弃修改"), role: .destructive) { dismiss() }
            Button(L("button.cancel", "取消"), role: .cancel) {}
        }
    }

    private func save() {
        guard let document, !busy else { return }
        let text = draft
        busy = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try document.save(text) }.value
                NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.title = L("processing.text.saveCopy", "另存为 UTF-8…")
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = L("processing.outputName", "%@ - 副本", url.deletingPathExtension().lastPathComponent)
            + "." + url.pathExtension
        panel.begin { result in
            guard result == .OK, let target = panel.url else { return }
            do {
                guard draft.utf8.count <= EditableTextFile.sizeLimit else { throw FileProcessingError.largeText }
                try FileProcessingService.writeNew(Data(draft.utf8), to: target)
                NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
