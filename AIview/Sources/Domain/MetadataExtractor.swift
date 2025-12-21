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

/// メタデータ抽出器
/// EXIF/PNG tEXt/XMPからのメタデータ抽出
/// Requirements: 5.2-5.6
actor MetadataExtractor {
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

        // PNG tEXtチャンクを検索
        if url.pathExtension.lowercased() == "png" {
            if let parameters = try? extractFromPNGTextChunk(url: url) {
                let result = parsePrompt(from: parameters)
                return (result.prompt, result.negativePrompt, additionalInfo)
            }

            // XMPにフォールバック
            if let parameters = try? extractFromXMP(url: url) {
                let result = parsePrompt(from: parameters)
                return (result.prompt, result.negativePrompt, additionalInfo)
            }
        }

        // 他の形式のメタデータ（EXIF等）
        if let exifInfo = extractEXIFInfo(from: url) {
            additionalInfo.merge(exifInfo) { _, new in new }
        }

        return (nil, nil, additionalInfo)
    }

    /// PNG tEXtチャンクからパラメータを抽出
    private func extractFromPNGTextChunk(url: URL) throws -> String? {
        let data = try Data(contentsOf: url)

        // "parameters\x00" を検索（tEXtチャンクのキーワード）
        let searchPattern = "parameters\0"
        guard let searchData = searchPattern.data(using: .utf8) else {
            return nil
        }

        guard let range = data.range(of: searchData) else {
            return nil
        }

        // tEXtチャンクの構造を解析してチャンク長を取得
        // チャンク構造: [4バイト長][4バイト種別][データ][4バイトCRC]
        // "parameters\0"の前に"tEXt"(4バイト)があり、その前に長さ(4バイト)がある
        let tEXtKeyword = Data([0x74, 0x45, 0x58, 0x74]) // "tEXt"
        guard let tEXtRange = data.range(of: tEXtKeyword, options: [], in: 0..<range.lowerBound) else {
            return nil
        }

        // チャンク長を取得（tEXtの4バイト前にビッグエンディアンで格納）
        let lengthStart = tEXtRange.lowerBound - 4
        guard lengthStart >= 0 else { return nil }

        // ビッグエンディアンで4バイトを読み取り（アライメント問題を回避）
        let chunkLength = UInt32(data[lengthStart]) << 24
            | UInt32(data[lengthStart + 1]) << 16
            | UInt32(data[lengthStart + 2]) << 8
            | UInt32(data[lengthStart + 3])

        // パラメータの開始位置
        let startIndex = range.upperBound

        // チャンクデータの終了位置を計算
        // tEXtの直後からchunkLength分がデータ
        let chunkDataEnd = tEXtRange.upperBound + Int(chunkLength)
        let endIndex = min(chunkDataEnd, data.count)

        let parameterData = data[startIndex..<endIndex]
        guard let parameters = String(data: parameterData, encoding: .utf8) else {
            return nil
        }

        Logger.metadata.debug("Found PNG tEXt parameters: \(parameters.prefix(100), privacy: .public)...")
        return parameters
    }

    /// XMPメタデータからパラメータを抽出
    private func extractFromXMP(url: URL) throws -> String? {
        let data = try Data(contentsOf: url)

        // <x:xmpmeta>...</x:xmpmeta> を検索
        guard let dataString = String(data: data, encoding: .utf8) else {
            return nil
        }

        // parameters="..." を検索
        let pattern = #"parameters=\"([^\"]*)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: dataString, options: [], range: NSRange(dataString.startIndex..., in: dataString)),
              let range = Range(match.range(at: 1), in: dataString) else {
            return nil
        }

        let parameters = String(dataString[range])
        Logger.metadata.debug("Found XMP parameters: \(parameters.prefix(100), privacy: .public)...")
        return parameters
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
