import XCTest
import AppKit
@testable import AIview

/// MetadataExtractor のユニットテスト
/// Task 3.1: 画像メタデータ抽出機能の実装
final class MetadataExtractorTests: XCTestCase {
    var sut: MetadataExtractor!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = MetadataExtractor()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewMetadataTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - Basic Metadata Tests

    func testExtractMetadata_returnsFileName() async throws {
        // Given
        let imageURL = try createTestImage(name: "testimage.png")

        // When
        let metadata = try await sut.extractMetadata(from: imageURL)

        // Then
        XCTAssertEqual(metadata.fileName, "testimage.png")
    }

    func testExtractMetadata_returnsFileSize() async throws {
        // Given
        let imageURL = try createTestImage(name: "sized.png")

        // When
        let metadata = try await sut.extractMetadata(from: imageURL)

        // Then
        XCTAssertTrue(metadata.fileSize > 0)
    }

    func testExtractMetadata_returnsImageSize() async throws {
        // Given
        let expectedSize = NSSize(width: 200, height: 150)
        let imageURL = try createTestImage(name: "dimensions.png", size: expectedSize)

        // When
        let metadata = try await sut.extractMetadata(from: imageURL)

        // Then
        XCTAssertEqual(metadata.imageSize.width, expectedSize.width)
        XCTAssertEqual(metadata.imageSize.height, expectedSize.height)
    }

    func testExtractMetadata_throwsForNonExistentFile() async {
        // Given
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.png")

        // When/Then
        do {
            _ = try await sut.extractMetadata(from: nonExistentURL)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is MetadataError)
        }
    }

    // MARK: - Prompt Parsing Tests

    func testParsePrompt_extractsPromptFromParameters() {
        // Given
        let parameters = """
        beautiful landscape, mountains, sunset, masterpiece
        Negative prompt: ugly, blurry, bad quality
        Steps: 20, Sampler: Euler a, CFG scale: 7
        """

        // When
        let result = sut.parsePrompt(from: parameters)

        // Then
        XCTAssertEqual(result.prompt, "beautiful landscape, mountains, sunset, masterpiece")
        XCTAssertEqual(result.negativePrompt, "ugly, blurry, bad quality")
    }

    func testParsePrompt_handlesNoNegativePrompt() {
        // Given
        let parameters = """
        beautiful landscape, mountains
        Steps: 20, Sampler: Euler a
        """

        // When
        let result = sut.parsePrompt(from: parameters)

        // Then
        XCTAssertEqual(result.prompt, "beautiful landscape, mountains")
        XCTAssertNil(result.negativePrompt)
    }

    func testParsePrompt_handlesEmptyString() {
        // Given
        let parameters = ""

        // When
        let result = sut.parsePrompt(from: parameters)

        // Then
        XCTAssertNil(result.prompt)
        XCTAssertNil(result.negativePrompt)
    }

    func testParsePrompt_handlesMultilinePrompt() {
        // Given
        let parameters = """
        a girl standing in a field,
        beautiful sunset,
        masterpiece, best quality
        Negative prompt: ugly, bad anatomy,
        worst quality
        Steps: 30
        """

        // When
        let result = sut.parsePrompt(from: parameters)

        // Then
        XCTAssertTrue(result.prompt?.contains("a girl standing") == true)
        XCTAssertTrue(result.prompt?.contains("masterpiece") == true)
        XCTAssertTrue(result.negativePrompt?.contains("ugly") == true)
    }

    // MARK: - PNG tEXt Chunk Tests

    func testExtractMetadata_fromRealPNGWithPrompt() async throws {
        // Given: 実際のプロンプト入りPNGファイル
        let realPNGPath = "/Volumes/Text2Img/2025-11-08/00004-3360867990.png"
        let url = URL(fileURLWithPath: realPNGPath)

        // ファイルが存在しない場合はスキップ
        guard FileManager.default.fileExists(atPath: realPNGPath) else {
            throw XCTSkip("Test PNG file not available at \(realPNGPath)")
        }

        // When
        let metadata = try await sut.extractMetadata(from: url)

        // Then
        print("=== Metadata Debug ===")
        print("fileName: \(metadata.fileName)")
        print("fileSize: \(metadata.fileSize)")
        print("imageSize: \(metadata.imageSize)")
        print("prompt: \(metadata.prompt ?? "nil")")
        print("negativePrompt: \(metadata.negativePrompt ?? "nil")")
        print("additionalInfo: \(metadata.additionalInfo)")
        print("======================")

        XCTAssertNotNil(metadata.prompt, "プロンプトが抽出されるべき")
        XCTAssertTrue(metadata.prompt?.contains("score_9") == true || metadata.prompt?.contains("source_photo") == true,
                      "プロンプトに期待される内容が含まれるべき")
    }

    func testExtractFromPNGTextChunk_directTest() async throws {
        // Given: 実際のプロンプト入りPNGファイル
        let realPNGPath = "/Volumes/Text2Img/2025-11-08/00004-3360867990.png"
        let url = URL(fileURLWithPath: realPNGPath)

        guard FileManager.default.fileExists(atPath: realPNGPath) else {
            throw XCTSkip("Test PNG file not available")
        }

        // バイナリを直接解析してデバッグ
        let data = try Data(contentsOf: url)

        // "parameters\0" を検索
        let searchPattern = "parameters\0"
        let searchData = searchPattern.data(using: .utf8)!

        guard let range = data.range(of: searchData) else {
            XCTFail("'parameters\\0' が見つかりません")
            return
        }
        print("Found 'parameters\\0' at offset: \(range.lowerBound)")

        // tEXtを検索
        let tEXtKeyword = Data([0x74, 0x45, 0x58, 0x74])
        guard let tEXtRange = data.range(of: tEXtKeyword, options: [], in: 0..<range.lowerBound) else {
            XCTFail("'tEXt' が見つかりません")
            return
        }
        print("Found 'tEXt' at offset: \(tEXtRange.lowerBound)")

        let lengthStart = tEXtRange.lowerBound - 4
        let chunkLength = UInt32(data[lengthStart]) << 24
            | UInt32(data[lengthStart + 1]) << 16
            | UInt32(data[lengthStart + 2]) << 8
            | UInt32(data[lengthStart + 3])
        print("Chunk length: \(chunkLength)")

        let startIndex = range.upperBound
        let chunkDataEnd = tEXtRange.upperBound + Int(chunkLength)
        print("Parameter start: \(startIndex), end: \(chunkDataEnd)")

        let parameterData = data[startIndex..<chunkDataEnd]
        guard let parameters = String(data: parameterData, encoding: .utf8) else {
            XCTFail("UTF-8デコード失敗")
            return
        }
        print("Parameters (first 300 chars): \(parameters.prefix(300))")

        XCTAssertTrue(parameters.contains("score_9") || parameters.contains("source_photo"))
    }

    // MARK: - Helper Methods

    private func createTestImage(name: String, size: NSSize = NSSize(width: 100, height: 100)) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)

        // Create bitmap rep with exact pixel dimensions
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        // Fill with green color
        let context = NSGraphicsContext(bitmapImageRep: bitmapRep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.green.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Test", code: 1)
        }

        try pngData.write(to: url)
        return url
    }
}
