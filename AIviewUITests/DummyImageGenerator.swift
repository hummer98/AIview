import AppKit
import Foundation

/// テスト用ダミー画像生成ユーティリティ
/// 200枚の画像を高速に生成（Core Graphics使用）
/// PNG形式で大きなファイルサイズを生成し、実際のAI生成画像に近い負荷をシミュレート
enum DummyImageGenerator {

    /// ダミー画像を生成して指定フォルダに保存
    /// - Parameters:
    ///   - count: 生成する画像数
    ///   - folder: 保存先フォルダURL
    ///   - imageSize: 画像サイズ（デフォルト: 2048x2048 - 約4-6MB/枚のPNG）
    /// - Returns: 生成された画像ファイルのURL配列
    @discardableResult
    static func generateImages(
        count: Int,
        in folder: URL,
        imageSize: CGSize = CGSize(width: 2048, height: 2048)
    ) throws -> [URL] {
        let fileManager = FileManager.default

        // フォルダが存在しない場合は作成
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var generatedURLs: [URL] = []

        for index in 0..<count {
            let imageURL = folder.appendingPathComponent("test_image_\(String(format: "%04d", index)).png")

            // カラフルなグラデーション画像を生成
            let imageData = try createGradientImage(
                size: imageSize,
                index: index,
                total: count
            )

            try imageData.write(to: imageURL)
            generatedURLs.append(imageURL)
        }

        return generatedURLs
    }

    /// グラデーション + ノイズ画像を生成（PNG形式で大きなファイルサイズ）
    private static func createGradientImage(
        size: CGSize,
        index: Int,
        total: Int
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let width = Int(size.width)
        let height = Int(size.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageGenerationError.contextCreationFailed
        }

        // インデックスに基づいて色相を変化させる
        let hue = CGFloat(index) / CGFloat(total)
        let startColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
        let endColor = NSColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1.0), saturation: 0.7, brightness: 0.7, alpha: 1.0)

        // グラデーション描画
        let colors = [startColor.cgColor, endColor.cgColor] as CFArray
        let locations: [CGFloat] = [0.0, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: locations
        ) else {
            throw ImageGenerationError.gradientCreationFailed
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size.width, y: size.height),
            options: []
        )

        // ノイズを追加してPNG圧縮効率を下げる（より現実的なファイルサイズに）
        addNoise(to: context, width: width, height: height, seed: index)

        // インデックス番号をテキストとして描画（デバッグ用）
        let text = "\(index + 1)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 200, weight: .bold),
            .foregroundColor: NSColor.white
        ]

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let textSize = text.size(withAttributes: attributes)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)

        NSGraphicsContext.restoreGraphicsState()

        // CGImageに変換
        guard let cgImage = context.makeImage() else {
            throw ImageGenerationError.imageCreationFailed
        }

        // PNGデータに変換（非圧縮で大きなファイルサイズ）
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(
            using: .png,
            properties: [:]
        ) else {
            throw ImageGenerationError.pngConversionFailed
        }

        return pngData
    }

    /// ノイズを追加（PNG圧縮効率を下げるため）
    private static func addNoise(to context: CGContext, width: Int, height: Int, seed: Int) {
        // シードベースの疑似乱数生成（オーバーフロー安全な演算を使用）
        var randomState = UInt64(truncatingIfNeeded: seed &+ 1) &* 6364136223846793005 &+ 1442695040888963407

        // ノイズ用の小さな矩形を多数描画
        let noiseIntensity: CGFloat = 0.15
        let noiseStep = 8 // 8ピクセルごとにノイズポイント

        for y in stride(from: 0, to: height, by: noiseStep) {
            for x in stride(from: 0, to: width, by: noiseStep) {
                // LCG乱数生成（オーバーフロー演算子を使用）
                randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
                let randomValue = CGFloat((randomState >> 33) & 0xFF) / 255.0

                let alpha = randomValue * noiseIntensity
                context.setFillColor(red: randomValue, green: randomValue, blue: randomValue, alpha: alpha)
                context.fill(CGRect(x: x, y: y, width: noiseStep, height: noiseStep))
            }
        }
    }

    /// .aiviewキャッシュフォルダを削除
    /// - Parameter folder: 対象フォルダURL
    static func clearCache(in folder: URL) throws {
        let cacheFolder = folder.appendingPathComponent(".aiview")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: cacheFolder.path) {
            try fileManager.removeItem(at: cacheFolder)
        }
    }

    /// テストフォルダを完全に削除
    /// - Parameter folder: 削除するフォルダURL
    static func cleanupTestFolder(_ folder: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }

    enum ImageGenerationError: Error, LocalizedError {
        case contextCreationFailed
        case gradientCreationFailed
        case imageCreationFailed
        case pngConversionFailed

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed:
                return "Failed to create graphics context"
            case .gradientCreationFailed:
                return "Failed to create gradient"
            case .imageCreationFailed:
                return "Failed to create image from context"
            case .pngConversionFailed:
                return "Failed to convert image to PNG"
            }
        }
    }
}
