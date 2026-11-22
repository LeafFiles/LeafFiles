import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileProcessingRequest {
    case image(URL)
    case pdf([URL])

    var sources: [URL] {
        switch self {
        case .image(let url): return [url]
        case .pdf(let urls): return urls
        }
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

struct FileProcessingSheet: View {
    let request: FileProcessingRequest
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [URL]
    @State private var directory: URL
    @State private var name: String
    @State private var format: FileProcessingService.ImageFormat = .png
    @State private var pdfAction: FileProcessingService.PDFAction = .extract
    @State private var rotation = 90
    @State private var edge = ""
    @State private var pages = ""
    @State private var busy = false
    @State private var error: String?

    init(request: FileProcessingRequest) {
        self.request = request
        let sources = request.sources
        let first = sources[0]
        _sources = State(initialValue: sources)
        _directory = State(initialValue: first.deletingLastPathComponent())
        _name = State(initialValue: sources.count > 1 ? L("processing.pdf.mergedName", "合并文档") :
            L("processing.outputName", "%@ - 副本", first.deletingPathExtension().lastPathComponent))
        _pdfAction = State(initialValue: sources.count > 1 ? .merge : .extract)
        _rotation = State(initialValue: request.isImage ? 0 : 90)
    }

    private var outputExtension: String { request.isImage ? format.rawValue : "pdf" }
    private var output: URL? {
        try? FileProcessingService.outputURL(in: directory, name: name, extension: outputExtension)
    }

    private var edgeValue: Int? { Int(edge.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canExport: Bool {
        guard output != nil else { return false }
        if request.isImage { return edge.isEmpty || edgeValue.map { (1...8192).contains($0) } == true }
        return pdfAction != .extract || !pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isImage ? L("processing.image.title", "处理图片") :
                 (sources.count > 1 ? pdfAction.title : L("processing.pdf.title", "处理 PDF")))
                .font(.headline)
            if sources.count > 1 {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sources.indices, id: \.self) { index in
                            HStack {
                                Text("\(index + 1). \(sources[index].lastPathComponent)")
                                    .lineLimit(1).truncationMode(.middle).help(sources[index].path)
                                Spacer()
                                Button { sources.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0).accessibilityLabel(L("processing.moveUp", "上移"))
                                Button { sources.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == sources.count - 1).accessibilityLabel(L("processing.moveDown", "下移"))
                            }
                        }
                    }
                }.frame(height: 115)
            } else {
                LabeledContent(L("processing.source", "源文件")) {
                    Text(sources[0].lastPathComponent).lineLimit(1).help(sources[0].path)
                }
            }
            if request.isImage {
                Picker(L("processing.image.format", "输出格式"), selection: $format) {
                    ForEach(FileProcessingService.ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                TextField(L("processing.image.edge", "最长边像素（留空保留原尺寸）"), text: $edge)
                rotationPicker
                Text(L("processing.image.note", "保留宽高比。导出使用 sRGB，不保留 EXIF 等原始元数据；JPEG 使用白色背景。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if sources.count == 1 {
                Picker(L("processing.pdf.operation", "处理方式"), selection: $pdfAction) {
                    Text(FileProcessingService.PDFAction.extract.title).tag(FileProcessingService.PDFAction.extract)
                    Text(FileProcessingService.PDFAction.rotate.title).tag(FileProcessingService.PDFAction.rotate)
                }.pickerStyle(.segmented)
                TextField(pdfAction == .rotate ? L("processing.pdf.pagesOptional", "页码（留空旋转全部）") :
                    L("processing.pdf.pages", "页码，例如 1,3-5"), text: $pages)
                if pdfAction == .rotate { rotationPicker }
            }
            if !request.isImage {
                Text(L("processing.pdf.note", "输出 PDF 可能不保留原有签名、书签或表单。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                TextField(L("processing.filename", "输出文件名"), text: $name)
                Text(".\(outputExtension)").foregroundStyle(.secondary)
                Button(L("processing.chooseFolder", "选择输出文件夹…")) { chooseFolder() }
            }
            Text(output?.path ?? L("processing.filename.invalid", "请输入有效的输出文件名。"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .help(output?.path ?? "")
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("processing.export", "导出新文件")) { export() }.keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .padding(20).frame(width: 570).textFieldStyle(.roundedBorder)
        .disabled(busy).interactiveDismissDisabled(busy)
    }

    private var rotationPicker: some View {
        Picker(L("processing.rotation", "顺时针旋转"), selection: $rotation) {
            if request.isImage { Text("0°").tag(0) }
            ForEach([90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.begin { result in
            if result == .OK, let url = panel.url { directory = url }
        }
    }

    private func export() {
        guard let output, canExport, !busy else { return }
        let sources = sources, format = format, edge = edgeValue, rotation = rotation, action = pdfAction, pages = pages
        let image = request.isImage
        busy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if image {
                        try FileProcessingService.processImage(sources[0], to: output, format: format, longestEdge: edge, rotation: rotation)
                    } else {
                        try FileProcessingService.processPDF(sources, to: output, action: action, pages: pages, rotation: rotation)
                    }
                }.value
                NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
