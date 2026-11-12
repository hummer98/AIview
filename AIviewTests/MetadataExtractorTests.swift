import XCTest
import AppKit
import Compression
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

    // MARK: - Bounded PNG Metadata Parser Tests

    func testExtractMetadata_preservesPromptCompatibility() async throws {
        let parameters = "mountain lake, sunset\nNegative prompt: blur, noise\nSteps: 30, CFG scale: 7"
        let imageURL = try createPromptImage(name: "prompt.png", parameters: parameters)

        let metadata = try await sut.extractMetadata(from: imageURL)

        XCTAssertEqual(metadata.prompt, "mountain lake, sunset")
        XCTAssertEqual(metadata.negativePrompt, "blur, noise")
    }

    func testExtractMetadata_parsesSwarmUIJSONInsteadOfShowingRawJSON() async throws {
        let imageURL = try createPromptImage(
            name: "swarm.png",
            parameters: GenerationMetadataParserTests.swarmUIParameters
        )

        let metadata = try await sut.extractMetadata(from: imageURL)

        XCTAssertEqual(metadata.generator, .swarmUI)
        XCTAssertEqual(metadata.prompt, "A candid photorealistic photograph of a woman by the seaside.")
        XCTAssertNil(metadata.negativePrompt)
        XCTAssertTrue(metadata.generationParameters.contains(MetadataField(label: "seed", value: "1234")))
    }

    func testExtractMetadata_parsesComfyUIPromptChunk() async throws {
        let imageURL = try createTextChunkImage(
            name: "comfy.png",
            keyword: "prompt",
            text: GenerationMetadataParserTests.comfyKSamplerPrompt
        )

        let metadata = try await sut.extractMetadata(from: imageURL)

        XCTAssertEqual(metadata.generator, .comfyUI)
        XCTAssertEqual(metadata.prompt, "a red fox in snow")
        XCTAssertEqual(metadata.negativePrompt, "blurry, lowres")
    }

    func testParser_collectsComfyPromptAndSkipsWorkflow() throws {
        let url = try writePNG(chunks: [
            pngChunk(type: "tEXt", payload: Data("workflow\0{\"nodes\": []}".utf8)),
            pngChunk(type: "tEXt", payload: Data("prompt\0{\"1\": {}}".utf8)),
            pngChunk(type: "IEND", payload: Data())
        ])

        let result = try PNGMetadataParser.parse(url: url)

        XCTAssertNil(result.parameters)
        XCTAssertEqual(result.comfyPrompt, "{\"1\": {}}")
    }

    func testParser_usesLengthOfSecondParametersTextChunk() throws {
        let url = try writePNG(chunks: [
            pngChunk(type: "tEXt", payload: Data("comment\0short".utf8)),
            pngChunk(type: "tEXt", payload: Data("parameters\0second prompt\nSteps: 12".utf8)),
            pngChunk(type: "IEND", payload: Data())
        ])

        let result = try PNGMetadataParser.parse(url: url)

        XCTAssertEqual(result.parameters, "second prompt\nSteps: 12")
    }

    func testParser_skipsOversizedNonParametersTextChunkAndUsesFollowingParametersLength() throws {
        let url = tempDirectory.appendingPathComponent("large-leading-text.png")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: pngSignature)
        let largeLength = UInt32(PNGMetadataParser.maximumTextBytes + 8192)
        try handle.write(contentsOf: chunkHeader(length: largeLength, type: "tEXt"))
        try handle.write(contentsOf: Data("comment\0".utf8))
        let payloadEnd = UInt64(pngSignature.count + 8) + UInt64(largeLength)
        try handle.seek(toOffset: payloadEnd)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.write(contentsOf: pngChunk(type: "tEXt", payload: Data("parameters\0right length".utf8)))
        try handle.write(contentsOf: pngChunk(type: "IEND", payload: Data()))

        let result = try PNGMetadataParser.parse(url: url)

        XCTAssertEqual(result.parameters, "right length")
        XCTAssertLessThan(result.bytesRead, 512)
    }

    func testParser_decodesUncompressedInternationalText() throws {
        let payload = Data("parameters\0".utf8)
            + Data([0, 0])
            + Data("ja\0パラメータ\0夜空\nSteps: 20".utf8)
        let url = try writePNG(chunks: [
            pngChunk(type: "iTXt", payload: payload),
            pngChunk(type: "IEND", payload: Data())
        ])

        XCTAssertEqual(try PNGMetadataParser.parameters(from: url), "夜空\nSteps: 20")
    }

    func testParser_decodesCompressedInternationalText() throws {
        let compressed = try zlibCompressed(Data("forest path\nSteps: 18".utf8))
        let payload = Data("parameters\0".utf8)
            + Data([1, 0])
            + Data("en\0Parameters\0".utf8)
            + compressed
        let url = try writePNG(chunks: [
            pngChunk(type: "iTXt", payload: payload),
            pngChunk(type: "IEND", payload: Data())
        ])

        XCTAssertEqual(try PNGMetadataParser.parameters(from: url), "forest path\nSteps: 18")
    }

    func testParser_decodesCompressedText() throws {
        let compressed = try zlibCompressed(Data("portrait\nSteps: 24".utf8))
        let payload = Data("parameters\0".utf8) + Data([0]) + compressed
        let url = try writePNG(chunks: [
            pngChunk(type: "zTXt", payload: payload),
            pngChunk(type: "IEND", payload: Data())
        ])

        XCTAssertEqual(try PNGMetadataParser.parameters(from: url), "portrait\nSteps: 24")
    }

    func testParser_prefersUTF8AndFallsBackToLatin1() throws {
        let utf8URL = try writePNG(chunks: [
            pngChunk(type: "tEXt", payload: Data("parameters\0星空".utf8)),
            pngChunk(type: "IEND", payload: Data())
        ])
        var latin1 = Data("parameters\0caf".utf8)
        latin1.append(0xE9)
        let latin1URL = try writePNG(chunks: [
            pngChunk(type: "tEXt", payload: latin1),
            pngChunk(type: "IEND", payload: Data())
        ])

        XCTAssertEqual(try PNGMetadataParser.parameters(from: utf8URL), "星空")
        XCTAssertEqual(try PNGMetadataParser.parameters(from: latin1URL), "café")
    }

    func testParser_rejectsInvalidSignature() throws {
        let url = tempDirectory.appendingPathComponent("invalid-signature.png")
        try Data(repeating: 0, count: 32).write(to: url)

        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .invalidSignature)
        }
    }

    func testParser_rejectsTruncatedPayloadAndCRCRegion() throws {
        let payloadURL = tempDirectory.appendingPathComponent("truncated-payload.png")
        try (pngSignature + chunkHeader(length: 128, type: "tEXt") + Data("parameters\0short".utf8))
            .write(to: payloadURL)

        let crcURL = tempDirectory.appendingPathComponent("truncated-crc.png")
        try (pngSignature + chunkHeader(length: 3, type: "abcD") + Data([1, 2, 3, 0, 0]))
            .write(to: crcURL)

        for url in [payloadURL, crcURL] {
            XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
                XCTAssertEqual(error as? PNGMetadataParserError, .truncated)
            }
        }
    }

    func testParser_rejectsMissingIENDAndTruncationAfterParameters() throws {
        let missingIEND = try writePNG(
            name: "missing-iend.png",
            chunks: [pngChunk(type: "tEXt", payload: Data("parameters\0prompt".utf8))]
        )
        let truncatedAfterParameters = tempDirectory.appendingPathComponent("truncated-after-parameters.png")
        try (
            pngSignature
                + pngChunk(type: "tEXt", payload: Data("parameters\0prompt".utf8))
                + chunkHeader(length: 4, type: "abCd")
                + Data([1, 2, 3, 4, 0, 0])
        ).write(to: truncatedAfterParameters)

        for url in [missingIEND, truncatedAfterParameters] {
            XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
                XCTAssertEqual(error as? PNGMetadataParserError, .truncated)
            }
        }
    }

    func testParser_rejectsInvalidIENDAfterParametersAndInvalidChunkType() throws {
        let invalidIEND = try writePNG(name: "invalid-iend-after-parameters.png", chunks: [
            pngChunk(type: "tEXt", payload: Data("parameters\0prompt".utf8)),
            pngChunk(type: "IEND", payload: Data([0]))
        ])
        let invalidTypeURL = tempDirectory.appendingPathComponent("invalid-type.png")
        try (
            pngSignature
                + bigEndianData(0)
                + Data([0x49, 0x44, 0x21, 0x54])
                + Data(repeating: 0, count: 4)
        ).write(to: invalidTypeURL)

        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: invalidIEND)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .invalidChunkLength)
        }
        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: invalidTypeURL)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .invalidChunkType)
        }
    }

    func testParser_rejectsOversizedParametersChunkWithoutReadingIt() throws {
        let url = tempDirectory.appendingPathComponent("oversized-parameters.png")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: pngSignature)
        let length = UInt32(PNGMetadataParser.maximumTextBytes + 1)
        try handle.write(contentsOf: chunkHeader(length: length, type: "tEXt"))
        try handle.write(contentsOf: Data("parameters\0".utf8))
        let chunkEnd = UInt64(pngSignature.count + 8) + UInt64(length) + 4
        try handle.seek(toOffset: chunkEnd - 1)
        try handle.write(contentsOf: Data([0]))

        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .oversizedTextChunk)
        }
    }

    func testParser_rejectsExpandedTextOverLimit() throws {
        let expanded = Data(repeating: 0x61, count: PNGMetadataParser.maximumTextBytes + 1)
        let compressed = try zlibCompressed(expanded)
        let payload = Data("parameters\0".utf8) + Data([0]) + compressed
        let url = try writePNG(chunks: [
            pngChunk(type: "zTXt", payload: payload),
            pngChunk(type: "IEND", payload: Data())
        ])

        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .oversizedTextChunk)
        }
    }

    func testParser_rejectsInvalidTextDelimitersAndCompressionFields() throws {
        let invalidPayloads: [(String, Data, PNGMetadataParserError)] = [
            ("tEXt", Data("parameters-without-null".utf8), .invalidTextChunk),
            ("iTXt", Data("parameters\0".utf8) + Data([2, 0, 0, 0]), .invalidTextChunk),
            ("iTXt", Data("parameters\0".utf8) + Data([0, 1, 0, 0]), .unsupportedCompression),
            ("iTXt", Data("parameters\0".utf8) + Data([0, 0]) + Data("language-only".utf8), .invalidTextChunk),
            ("zTXt", Data("parameters\0".utf8) + Data([1, 1, 2, 3]), .unsupportedCompression)
        ]

        for (index, fixture) in invalidPayloads.enumerated() {
            let url = try writePNG(
                name: "invalid-text-\(index).png",
                chunks: [pngChunk(type: fixture.0, payload: fixture.1), pngChunk(type: "IEND", payload: Data())]
            )
            XCTAssertThrowsError(try PNGMetadataParser.parameters(from: url)) { error in
                XCTAssertEqual(error as? PNGMetadataParserError, fixture.2)
            }
        }
    }

    func testParser_skipsUnknownAndLargeIDATWithoutAllocatingPayload() throws {
        let url = tempDirectory.appendingPathComponent("large-sparse.png")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: pngSignature)
        let largeLength: UInt32 = 128 * 1024 * 1024
        try handle.write(contentsOf: chunkHeader(length: largeLength, type: "IDAT"))
        let payloadEnd = UInt64(pngSignature.count + 8) + UInt64(largeLength)
        try handle.seek(toOffset: payloadEnd)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.write(contentsOf: pngChunk(type: "vpAg", payload: Data(repeating: 7, count: 32)))
        try handle.write(contentsOf: pngChunk(type: "tEXt", payload: Data("parameters\0bounded".utf8)))
        try handle.write(contentsOf: pngChunk(type: "IEND", payload: Data()))

        let result = try PNGMetadataParser.parse(url: url)

        XCTAssertEqual(result.parameters, "bounded")
        XCTAssertLessThan(result.bytesRead, 512)
    }

    func testParser_rejectsChunkCountLimitAndInvalidIENDLength() throws {
        let chunks = [
            pngChunk(type: "abCd", payload: Data()),
            pngChunk(type: "efGh", payload: Data()),
            pngChunk(type: "IEND", payload: Data())
        ]
        let countURL = try writePNG(name: "too-many.png", chunks: chunks)
        let iendURL = try writePNG(name: "invalid-iend.png", chunks: [pngChunk(type: "IEND", payload: Data([0]))])

        XCTAssertThrowsError(try PNGMetadataParser.parse(url: countURL, maximumChunkCount: 2)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .tooManyChunks)
        }
        XCTAssertThrowsError(try PNGMetadataParser.parameters(from: iendURL)) { error in
            XCTAssertEqual(error as? PNGMetadataParserError, .invalidChunkLength)
        }
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

    private func createPromptImage(name: String, parameters: String) throws -> URL {
        try createTextChunkImage(name: name, keyword: "parameters", text: parameters)
    }

    private func createTextChunkImage(name: String, keyword: String, text: String) throws -> URL {
        let url = try createTestImage(name: name)
        var png = try Data(contentsOf: url)
        let iendSize = 12
        guard png.count >= iendSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        png.insert(contentsOf: pngChunk(type: "tEXt", payload: Data("\(keyword)\0\(text)".utf8)), at: png.count - iendSize)
        try png.write(to: url)
        return url
    }

    private var pngSignature: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private func writePNG(name: String = UUID().uuidString + ".png", chunks: [Data]) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        var data = pngSignature
        for chunk in chunks {
            data.append(chunk)
        }
        try data.write(to: url)
        return url
    }

    private func chunkHeader(length: UInt32, type: String) -> Data {
        var data = bigEndianData(length)
        data.append(Data(type.utf8))
        return data
    }

    private func pngChunk(type: String, payload: Data) -> Data {
        let typeData = Data(type.utf8)
        var data = bigEndianData(UInt32(payload.count))
        data.append(typeData)
        data.append(payload)
        data.append(bigEndianData(crc32(typeData + payload)))
        return data
    }

    private func bigEndianData(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func zlibCompressed(_ data: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: max(64, data.count + 1024))
        let encodedCount = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Data(output.prefix(encodedCount))
    }
}
