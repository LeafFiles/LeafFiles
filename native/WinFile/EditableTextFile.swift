import CoreFoundation
import Foundation
import UniformTypeIdentifiers

struct EditableTextFile {
    static let sizeLimit = 2 * 1024 * 1024
    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let url: URL
    let text: String
    private let identity: FileMoveRecord
    private let contents: Data
    private let encoding: String.Encoding
    private let bom: Data

    var encodingName: String {
        if encoding == .utf8 { return "UTF-8" }
        if encoding == .utf16LittleEndian { return "UTF-16 LE" }
        if encoding == .utf16BigEndian { return "UTF-16 BE" }
        return "GB18030"
    }

    static func supports(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .plainText) { return true }
        return ["csv", "tsv", "md", "json", "xml", "yaml", "yml", "toml", "ini", "log", "conf", "config", "sh",
                "py", "js", "ts", "swift", "cmd", "bat", "ps1", "html", "css"].contains(ext)
    }

    static func open(_ url: URL) throws -> Self {
        guard supports(url), let identity = FileMoveRecord(original: url, current: url)
        else { throw FileProcessingError.unsupportedText }
        let data = try read(url)
        guard identity.stillExists else { throw FileProcessingError.changedText }
        let boms: [(Data, String.Encoding)] = [(Data([0xEF, 0xBB, 0xBF]), .utf8),
                                               (Data([0xFF, 0xFE]), .utf16LittleEndian),
                                               (Data([0xFE, 0xFF]), .utf16BigEndian)]
        let match = boms.first { data.starts(with: $0.0) }
        let bom = match?.0 ?? Data()
        let payload = data.dropFirst(bom.count)
        let candidates: [String.Encoding] = match.map { [$0.1] } ?? [.utf8, gb18030]
        for encoding in candidates {
            guard let text = String(data: payload, encoding: encoding),
                  !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) })
            else { continue }
            return Self(url: url, text: text, identity: identity, contents: data, encoding: encoding, bom: bom)
        }
        throw FileProcessingError.unsupportedText
    }

    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FileProcessingError.unsupportedText }
        guard (values.fileSize ?? 0) <= sizeLimit else { throw FileProcessingError.largeText }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: sizeLimit + 1) ?? Data()
        guard data.count <= sizeLimit else { throw FileProcessingError.largeText }
        return data
    }

    func save(_ draft: String) throws {
        guard let encoded = draft.data(using: encoding, allowLossyConversion: false)
        else { throw FileProcessingError.encodingFailed }
        guard (bom.count + encoded.count) <= Self.sizeLimit else { throw FileProcessingError.largeText }
        var coordinationError: NSError?
        var writeResult: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            writeResult = Result {
                guard identity.stillExists, let current = try? Self.read(coordinatedURL), current == contents,
                      identity.stillExists else { throw FileProcessingError.changedText }
                try (bom + encoded).write(to: coordinatedURL, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let writeResult else { throw FileProcessingError.exportFailed }
        try writeResult.get()
    }
}
