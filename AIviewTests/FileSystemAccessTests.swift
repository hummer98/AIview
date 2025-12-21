import XCTest
@testable import AIview

/// FileSystemAccess のユニットテスト
/// Task 1.2: ファイルシステムアクセス機能の実装
final class FileSystemAccessTests: XCTestCase {
    var sut: FileSystemAccess!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = FileSystemAccess()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - getFileAttributes Tests

    func testGetFileAttributes_returnsCorrectSize() throws {
        // Given
        let testFile = tempDirectory.appendingPathComponent("test.txt")
        let testData = Data("Hello, World!".utf8)
        try testData.write(to: testFile)

        // When
        let attributes = try sut.getFileAttributes(testFile)

        // Then
        XCTAssertEqual(attributes.size, Int64(testData.count))
    }

    func testGetFileAttributes_returnsModificationDate() throws {
        // Given
        let testFile = tempDirectory.appendingPathComponent("test.txt")
        try Data("test".utf8).write(to: testFile)

        // When
        let attributes = try sut.getFileAttributes(testFile)

        // Then
        XCTAssertNotNil(attributes.modificationDate)
        let timeInterval = attributes.modificationDate.timeIntervalSinceNow
        XCTAssertTrue(abs(timeInterval) < 5, "Modification date should be recent")
    }

    func testGetFileAttributes_throwsForNonExistentFile() {
        // Given
        let nonExistentFile = tempDirectory.appendingPathComponent("nonexistent.txt")

        // When/Then
        XCTAssertThrowsError(try sut.getFileAttributes(nonExistentFile)) { error in
            XCTAssertTrue(error is FileSystemError)
            if case FileSystemError.fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error")
            }
        }
    }

    // MARK: - checkAccess Tests

    func testCheckAccess_returnsTrueForExistingFile() throws {
        // Given
        let testFile = tempDirectory.appendingPathComponent("test.txt")
        try Data("test".utf8).write(to: testFile)

        // When
        let hasAccess = sut.checkAccess(to: testFile)

        // Then
        XCTAssertTrue(hasAccess)
    }

    func testCheckAccess_returnsFalseForNonExistentFile() {
        // Given
        let nonExistentFile = tempDirectory.appendingPathComponent("nonexistent.txt")

        // When
        let hasAccess = sut.checkAccess(to: nonExistentFile)

        // Then
        XCTAssertFalse(hasAccess)
    }

    func testCheckAccess_returnsTrueForExistingDirectory() {
        // When
        let hasAccess = sut.checkAccess(to: tempDirectory)

        // Then
        XCTAssertTrue(hasAccess)
    }

    // MARK: - moveToTrash Tests

    func testMoveToTrash_removesFileFromOriginalLocation() async throws {
        // Given
        let testFile = tempDirectory.appendingPathComponent("toDelete.txt")
        try Data("delete me".utf8).write(to: testFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))

        // When
        try await sut.moveToTrash(testFile)

        // Then
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }

    func testMoveToTrash_throwsForNonExistentFile() async {
        // Given
        let nonExistentFile = tempDirectory.appendingPathComponent("nonexistent.txt")

        // When/Then
        do {
            try await sut.moveToTrash(nonExistentFile)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is FileSystemError)
        }
    }
}
