import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum FileProcessingError: LocalizedError {
    case invalidImage, largeImage, invalidPDF, lockedPDF, invalidPages, exportFailed
    case unsupportedText, largeText, changedText, encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return L("processing.image.invalid", "无法读取此图片，或图片包含多帧。")
        case .largeImage: return L("processing.image.large", "图片尺寸超过处理上限（8192 像素边长或 4000 万像素）。")
        case .invalidPDF: return L("processing.pdf.invalid", "无法读取 PDF 页面。")
        case .lockedPDF: return L("processing.pdf.locked", "请先使用 PDF 应用解除文档保护。")
        case .invalidPages: return L("processing.pdf.invalidPages", "请输入有效的页码，例如 1,3-5。")
        case .exportFailed: return L("processing.export.failed", "无法生成输出文件。")
        case .unsupportedText: return L("processing.text.unsupported", "无法以支持的编码读取此纯文本文件。")
        case .largeText: return L("processing.text.large", "内置编辑器只能编辑 2 MB 以内的文件。")
        case .changedText: return L("processing.text.changed", "磁盘上的原文件已更改或被替换。可以将当前内容另存为新文件。")
        case .encodingFailed: return L("processing.text.encodingFailed", "当前编码无法保存部分字符。请另存为 UTF-8 文件。")
        }
    }
}

enum FileProcessingService {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpg, tiff
        var id: Self { self }
        var type: UTType {
            switch self {
            case .png: return .png
            case .jpg: return .jpeg
            case .tiff: return .tiff
            }
        }
    }

    enum PDFAction: String, CaseIterable, Identifiable {
        case merge, extract, rotate
        var id: Self { self }
        var title: String {
            switch self {
            case .merge: return L("processing.pdf.merge", "合并 PDF")
            case .extract: return L("processing.pdf.extract", "提取页面")
            case .rotate: return L("processing.pdf.rotate", "旋转页面")
            }
        }
    }

    static func outputURL(in directory: URL, name: String, extension ext: String = "") throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = ext.isEmpty ? name : name + "." + ext
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0"), filename.utf8.count <= 255 else { throw FSError.invalidName }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Stage beside the output so it only becomes visible once writing succeeds.
    static func writeNew(_ data: Data, to target: URL) throws {
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent().appendingPathComponent(".LeafFiles-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let stage = folder.appendingPathComponent("output")
        try data.write(to: stage, options: .withoutOverwriting)
        try manager.moveItem(at: stage, to: target)
    }

    static func processImage(_ source: URL, to target: URL, format: ImageFormat, longestEdge: Int?, rotation: Int) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw FileProcessingError.invalidImage }

        let edge = longestEdge ?? max(width, height)
        let scale = Double(edge) / Double(max(width, height))
        guard (1...8192).contains(edge), Double(width) * Double(height) * scale * scale <= 40_000_000
        else { throw FileProcessingError.largeImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: edge]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
        else { throw FileProcessingError.invalidImage }
        let orientation: Int32
        switch rotation {
        case 90: orientation = 6
        case 180: orientation = 3
        case 270: orientation = 8
        default: orientation = 1
        }
        var image = CIImage(cgImage: decoded).oriented(forExifOrientation: orientation)
        let extent = image.extent
        let factor = CGFloat(edge) / max(extent.width, extent.height)
        let dimensions = CGRect(x: 0, y: 0, width: max(1, (extent.width * factor).rounded()),
                                height: max(1, (extent.height * factor).rounded()))
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: dimensions.width / extent.width, y: dimensions.height / extent.height))
        if format == .jpg {
            image = image.composited(over: CIImage(color: .white).cropped(to: dimensions))
        }
        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(image, from: dimensions, format: .RGBA8, colorSpace: colorSpace)
        else { throw FileProcessingError.exportFailed }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil)
        else { throw FileProcessingError.exportFailed }
        let optionsOut: [CFString: Any] = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(output, rendered, optionsOut as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw FileProcessingError.exportFailed }
        try writeNew(data as Data, to: target)
    }

    static func pageIndices(_ input: String, count: Int) throws -> [Int] {
        let parts = input.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false)
        var indices = [Int]()
        var seen = Set<Int>()
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                  let end = Int(bounds[bounds.count - 1].trimmingCharacters(in: .whitespaces)),
                  start >= 1, start <= end, end <= count else { throw FileProcessingError.invalidPages }
            for index in (start - 1)..<end where seen.insert(index).inserted { indices.append(index) }
        }
        guard !indices.isEmpty else { throw FileProcessingError.invalidPages }
        return indices
    }

    static func processPDF(_ sources: [URL], to target: URL, action: PDFAction, pages: String, rotation: Int) throws {
        guard action == .merge ? sources.count > 1 : sources.count == 1 else { throw FileProcessingError.invalidPDF }
        let documents = try sources.map { url -> PDFDocument in
            guard let document = PDFDocument(url: url) else { throw FileProcessingError.invalidPDF }
            guard !document.isEncrypted else { throw FileProcessingError.lockedPDF }
            guard document.pageCount > 0 else { throw FileProcessingError.invalidPDF }
            return document
        }
        let destination: PDFDocument
        if action == .rotate, let document = documents.first {
            destination = document
            let indices = pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Array(0..<document.pageCount) :
                try pageIndices(pages, count: document.pageCount)
            for index in indices {
                guard let page = document.page(at: index) else { throw FileProcessingError.invalidPDF }
                page.rotation = (page.rotation + rotation) % 360
            }
        } else {
            destination = PDFDocument()
            for document in documents {
                let indices = action == .extract ? try pageIndices(pages, count: document.pageCount) : Array(0..<document.pageCount)
                for index in indices {
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { throw FileProcessingError.invalidPDF }
                    destination.insert(page, at: destination.pageCount)
                }
            }
        }
        guard let data = destination.dataRepresentation() else { throw FileProcessingError.exportFailed }
        try writeNew(data, to: target)
    }
}
