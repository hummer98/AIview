import Compression
import Foundation
import ImageIO
import os

/// メタデータ抽出エラー
enum MetadataError: Error, LocalizedError {
    case fileNotFound(URL)
    case readFailed(URL)
    case invalidImage(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "ファイルが見つかりません: \(url.lastPathComponent)"
        case .readFailed(let url):
            return "ファイルの読み取りに失敗しました: \(url.lastPathComponent)"
        case .invalidImage(let url):
            return "無効な画像ファイルです: \(url.lastPathComponent)"
        }
    }
}

/// 画像メタデータ
struct ImageMetadata: Sendable {
    let fileName: String
    let fileSize: Int64
    let imageSize: CGSize
    let creationDate: Date?
    let prompt: String?
    let negativePrompt: String?
    let additionalInfo: [String: String]
}

/// プロンプトパース結果
struct PromptParseResult {
    let prompt: String?
    let negativePrompt: String?
}

/// PNG の prompt metadata を、ファイル全体をメモリへ載せずに走査する parser。
///
/// PNG chunk は `[length: 4][type: 4][payload: length][CRC: 4]` の順に並ぶ。
/// metadata と無関係な chunk は seek だけで飛ばし、text chunk も keyword の確認までは
/// 最大 80 byte しか読まない。`parameters` chunk だけを 1 MiB 上限で decode する。
enum PNGMetadataParserError: Error, Equatable {
    case invalidSignature
    case truncated
    case invalidChunkType
    case invalidChunkLength
    case tooManyChunks
    case oversizedTextChunk
    case invalidTextChunk
    case unsupportedCompression
    case decompressionFailed
}

struct PNGMetadataParseResult: Equatable {
    let parameters: String?
    let bytesRead: Int
}

struct PNGMetadataParser {
    static let maximumTextBytes = 1024 * 1024
    static let maximumChunkCount = 100_000

    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let maximumKeywordBytes = 79
    private static let textChunkTypes: Set<String> = ["tEXt", "iTXt", "zTXt"]

    static func parameters(from url: URL) throws -> String? {
        try parse(url: url).parameters
    }

    /// `bytesRead` は bounded-read test 専用の internal seam。本番 API には公開しない。
    static func parse(url: URL, maximumChunkCount: Int = Self.maximumChunkCount) throws -> PNGMetadataParseResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileLength = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var reader = PNGFileReader(handle: handle, fileLength: fileLength)

        guard try reader.readExactly(signature.count) == signature else {
            throw PNGMetadataParserError.invalidSignature
        }

        var chunkCount = 0
        var parameters: String?
        while reader.offset < fileLength {
            chunkCount += 1
            guard chunkCount <= maximumChunkCount else {
                throw PNGMetadataParserError.tooManyChunks
            }

            let header = try reader.readExactly(8)
            let chunkLength = UInt64(Self.uint32(from: header, offset: 0))
            let typeData = header.subdata(in: 4..<8)
            guard typeData.allSatisfy(Self.isASCIILetter),
                  let chunkType = String(data: typeData, encoding: .ascii) else {
                throw PNGMetadataParserError.invalidChunkType
            }

            let payloadStart = reader.offset
            let payloadEnd = try Self.checkedAdd(payloadStart, chunkLength)
            let chunkEnd = try Self.checkedAdd(payloadEnd, 4)
            guard chunkEnd <= fileLength else {
                throw PNGMetadataParserError.truncated
            }

            if chunkType == "IEND" {
                guard chunkLength == 0 else {
                    throw PNGMetadataParserError.invalidChunkLength
                }
                try reader.seek(to: chunkEnd)
                return PNGMetadataParseResult(parameters: parameters, bytesRead: reader.bytesRead)
            }

            if textChunkTypes.contains(chunkType) {
                let prefixLength = min(Int(chunkLength), maximumKeywordBytes + 1)
                guard prefixLength > 0 else {
                    throw PNGMetadataParserError.invalidTextChunk
                }
                let keywordPrefix = try reader.readExactly(prefixLength)
                guard let delimiter = keywordPrefix.firstIndex(of: 0) else {
                    throw PNGMetadataParserError.invalidTextChunk
                }

                let keywordBytes = keywordPrefix[..<delimiter]
                guard !keywordBytes.isEmpty,
                      keywordBytes.count <= maximumKeywordBytes,
                      let keyword = String(data: keywordBytes, encoding: .isoLatin1) else {
                    throw PNGMetadataParserError.invalidTextChunk
                }

                guard keyword.caseInsensitiveCompare("parameters") == .orderedSame else {
                    try reader.seek(to: chunkEnd)
                    continue
                }

                guard chunkLength <= UInt64(maximumTextBytes) else {
                    throw PNGMetadataParserError.oversizedTextChunk
                }

                let remainingLength = Int(chunkLength) - keywordPrefix.count
                let remaining = try reader.readExactly(remainingLength)
                var payload = Data(keywordPrefix)
                payload.append(remaining)
                let decodedParameters = try decodeParameters(payload: payload, type: chunkType)
                if parameters == nil {
                    parameters = decodedParameters
                }
                try reader.seek(to: chunkEnd)
                continue
            }

            // IDAT と unknown chunk は payload を allocate せず、CRC の後まで seek する。
            try reader.seek(to: chunkEnd)
        }

        // PNG は IEND で終端しなければならない。
        throw PNGMetadataParserError.truncated
    }

    private static func decodeParameters(payload: Data, type: String) throws -> String {
        guard let keywordEnd = payload.firstIndex(of: 0) else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        let contentStart = payload.index(after: keywordEnd)

        let decoded: Data
        switch type {
        case "tEXt":
            decoded = Data(payload[contentStart...])
        case "zTXt":
            guard contentStart < payload.endIndex else {
                throw PNGMetadataParserError.invalidTextChunk
            }
            guard payload[contentStart] == 0 else {
                throw PNGMetadataParserError.unsupportedCompression
            }
            let compressedStart = payload.index(after: contentStart)
            decoded = try decompress(Data(payload[compressedStart...]))
        case "iTXt":
            decoded = try decodeInternationalText(payload: payload, contentStart: contentStart)
        default:
            throw PNGMetadataParserError.invalidChunkType
        }

        guard decoded.count <= maximumTextBytes,
              let string = String(data: decoded, encoding: .utf8)
                ?? String(data: decoded, encoding: .isoLatin1) else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        return string
    }

    private static func decodeInternationalText(payload: Data, contentStart: Data.Index) throws -> Data {
        guard contentStart < payload.endIndex else {
            throw PNGMetadataParserError.invalidTextChunk
        }

        let compressionFlag = payload[contentStart]
        let methodIndex = payload.index(after: contentStart)
        guard methodIndex < payload.endIndex else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        let compressionMethod = payload[methodIndex]
        guard compressionFlag == 0 || compressionFlag == 1 else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        guard compressionMethod == 0 else {
            throw PNGMetadataParserError.unsupportedCompression
        }

        let languageStart = payload.index(after: methodIndex)
        guard let languageEnd = payload[languageStart...].firstIndex(of: 0) else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        let translatedKeywordStart = payload.index(after: languageEnd)
        guard let translatedKeywordEnd = payload[translatedKeywordStart...].firstIndex(of: 0) else {
            throw PNGMetadataParserError.invalidTextChunk
        }
        let textStart = payload.index(after: translatedKeywordEnd)
        let text = Data(payload[textStart...])

        return compressionFlag == 1 ? try decompress(text) : text
    }

    private static func decompress(_ input: Data) throws -> Data {
        guard !input.isEmpty else {
            throw PNGMetadataParserError.decompressionFailed
        }

        var output = [UInt8](repeating: 0, count: maximumTextBytes + 1)
        let decodedCount = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount > 0 else {
            throw PNGMetadataParserError.decompressionFailed
        }
        guard decodedCount <= maximumTextBytes else {
            throw PNGMetadataParserError.oversizedTextChunk
        }
        return Data(output.prefix(decodedCount))
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PNGMetadataParserError.invalidChunkLength
        }
        return result
    }

    private static func uint32(from data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}

private struct PNGFileReader {
    let handle: FileHandle
    let fileLength: UInt64
    private(set) var offset: UInt64 = 0
    private(set) var bytesRead = 0

    mutating func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw PNGMetadataParserError.invalidChunkLength
        }
        let requestedEnd = try checkedAdd(offset, UInt64(count))
        guard requestedEnd <= fileLength else {
            throw PNGMetadataParserError.truncated
        }
        guard count > 0 else { return Data() }

        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let part = try handle.read(upToCount: count - data.count) ?? Data()
            guard !part.isEmpty else {
                throw PNGMetadataParserError.truncated
            }
            data.append(part)
            offset += UInt64(part.count)
            bytesRead += part.count
        }
        assert(offset == requestedEnd)
        return data
    }

    mutating func seek(to newOffset: UInt64) throws {
        guard newOffset >= offset, newOffset <= fileLength else {
            throw PNGMetadataParserError.invalidChunkLength
        }
        try handle.seek(toOffset: newOffset)
        offset = newOffset
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PNGMetadataParserError.invalidChunkLength
        }
        return result
    }
}

/// ViewModel からメタデータ取得を差し替え可能にする actor 境界。
/// 制御可能な suspension point を持つ test double で stale completion を再現できる。
protocol MetadataExtracting: Actor {
    func extractMetadata(from url: URL) async throws -> ImageMetadata
}

/// メタデータ抽出器
/// EXIF/PNG tEXt/XMPからのメタデータ抽出
/// Requirements: 5.2-5.6
actor MetadataExtractor: MetadataExtracting {
    // MARK: - Public Methods

    /// 画像からメタデータを抽出
    /// - Parameter url: 画像ファイルのURL
    /// - Returns: ImageMetadata
    func extractMetadata(from url: URL) async throws -> ImageMetadata {
        let fileManager = FileManager.default

        // ファイルの存在確認
        guard fileManager.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }

        // ファイル属性を取得
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw MetadataError.readFailed(url)
        }

        let fileSize = (attributes[.size] as? Int64) ?? 0
        let creationDate = attributes[.creationDate] as? Date

        // 画像サイズを取得
        let imageSize = try getImageSize(from: url)

        // プロンプト情報を抽出
        let (prompt, negativePrompt, additionalInfo) = try extractPromptInfo(from: url)

        return ImageMetadata(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            imageSize: imageSize,
            creationDate: creationDate,
            prompt: prompt,
            negativePrompt: negativePrompt,
            additionalInfo: additionalInfo
        )
    }

    /// パラメータ文字列からプロンプトを解析
    /// - Parameter parameters: パラメータ文字列
    /// - Returns: PromptParseResult
    nonisolated func parsePrompt(from parameters: String) -> PromptParseResult {
        guard !parameters.isEmpty else {
            return PromptParseResult(prompt: nil, negativePrompt: nil)
        }

        var prompt: String?
        var negativePrompt: String?

        // "Negative prompt:" の位置を検索
        if let negativeRange = parameters.range(of: "Negative prompt:", options: .caseInsensitive) {
            // Negative prompt より前がプロンプト
            let promptPart = String(parameters[..<negativeRange.lowerBound])
            prompt = promptPart.trimmingCharacters(in: .whitespacesAndNewlines)

            // Negative prompt から Steps: までがネガティブプロンプト
            let afterNegative = String(parameters[negativeRange.upperBound...])
            if let stepsRange = afterNegative.range(of: "Steps:", options: .caseInsensitive) {
                negativePrompt = String(afterNegative[..<stepsRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                negativePrompt = afterNegative.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let stepsRange = parameters.range(of: "Steps:", options: .caseInsensitive) {
            // Negative promptがない場合、Steps:より前がプロンプト
            prompt = String(parameters[..<stepsRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Steps:もない場合は全体がプロンプト
            prompt = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 空文字列をnilに変換
        if prompt?.isEmpty == true { prompt = nil }
        if negativePrompt?.isEmpty == true { negativePrompt = nil }

        return PromptParseResult(prompt: prompt, negativePrompt: negativePrompt)
    }

    // MARK: - Private Methods

    /// 画像サイズを取得
    private func getImageSize(from url: URL) throws -> CGSize {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.invalidImage(url)
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw MetadataError.invalidImage(url)
        }

        return CGSize(width: width, height: height)
    }

    /// プロンプト情報を抽出
    private func extractPromptInfo(from url: URL) throws -> (prompt: String?, negativePrompt: String?, additionalInfo: [String: String]) {
        var additionalInfo: [String: String] = [:]

        // EXIF/XMP/PNG properties は、ImageIO が認識できる metadata を最優先する。
        if let parameters = extractParametersUsingImageIO(from: url) {
            let result = parsePrompt(from: parameters)
            return (result.prompt, result.negativePrompt, additionalInfo)
        }

        // Stable Diffusion の独自 `parameters` keyword が ImageIO で公開されない PNG は、
        // bounded chunk parser へフォールバックする。
        if url.pathExtension.lowercased() == "png",
           let parameters = try? PNGMetadataParser.parameters(from: url) {
            let result = parsePrompt(from: parameters)
            return (result.prompt, result.negativePrompt, additionalInfo)
        }

        // 他の形式のメタデータ（EXIF等）
        if let exifInfo = extractEXIFInfo(from: url) {
            additionalInfo.merge(exifInfo) { _, new in new }
        }

        return (nil, nil, additionalInfo)
    }

    /// ImageIO が正規化した properties / XMP tag を検索する。
    /// 戻り値は PNG fallback と同じ 1 MiB 上限を適用する。
    private func extractParametersUsingImageIO(from url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? {
            var visitedNodes = 0
            if let value = Self.parametersValue(in: properties, depth: 0, visitedNodes: &visitedNodes) {
                return value
            }
        }

        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }

        var result: String?
        let options = [kCGImageMetadataEnumerateRecursively: kCFBooleanTrue] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { _, tag in
            guard result == nil,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  name.caseInsensitiveCompare("parameters") == .orderedSame,
                  let value = CGImageMetadataTagCopyValue(tag),
                  let bounded = Self.boundedString(from: value) else {
                return result == nil
            }
            result = bounded
            return false
        }
        return result
    }

    private static func parametersValue(
        in dictionary: NSDictionary,
        depth: Int,
        visitedNodes: inout Int
    ) -> String? {
        guard depth <= 8, visitedNodes <= 1024 else { return nil }
        visitedNodes += 1

        for (rawKey, rawValue) in dictionary {
            let key = String(describing: rawKey)
            if key.caseInsensitiveCompare("parameters") == .orderedSame,
               let value = boundedString(from: rawValue) {
                return value
            }
            if let child = rawValue as? NSDictionary,
               let value = parametersValue(in: child, depth: depth + 1, visitedNodes: &visitedNodes) {
                return value
            }
        }
        return nil
    }

    private static func boundedString(from value: Any) -> String? {
        let string: String?
        if let candidate = value as? String {
            string = candidate
        } else if let data = value as? Data, data.count <= PNGMetadataParser.maximumTextBytes {
            string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        } else {
            string = nil
        }

        guard let string,
              string.utf8.count <= PNGMetadataParser.maximumTextBytes else {
            return nil
        }
        return string
    }

    /// EXIF情報を抽出
    private func extractEXIFInfo(from url: URL) -> [String: String]? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }

        var info: [String: String] = [:]

        // EXIF辞書を取得
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateTime = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                info["撮影日時"] = dateTime
            }
            if let software = exif[kCGImagePropertyExifUserComment] as? String {
                info["ソフトウェア"] = software
            }
        }

        return info.isEmpty ? nil : info
    }
}
