import Foundation
import Testing

@testable import VoxOS

/// The launch-time snapshot check only reads sizes and mtimes; hashing is a separate step that
/// writes the integrity record, and a changed file invalidates it.
struct VoxOSRefineSnapshotTests {
    // sha256("hello")
    private let files = [
        VoxOSRefineModelDownloader.ModelFile(
            path: "weights.bin", size: 5,
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    ]

    private func makeSnapshotDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("refine-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func statusFollowsSizeThenRecord() throws {
        let dir = try makeSnapshotDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let weights = dir.appendingPathComponent("weights.bin")

        #expect(VoxOSRefineModelDownloader.snapshotStatus(at: dir, files: files) == .incomplete)

        try Data("hello".utf8).write(to: weights)
        #expect(VoxOSRefineModelDownloader.snapshotStatus(at: dir, files: files) == .needsVerification)

        try VoxOSRefineModelDownloader.verifySnapshot(at: dir, files: files)
        #expect(VoxOSRefineModelDownloader.snapshotStatus(at: dir, files: files) == .verified)
    }

    @Test func sameSizeDifferentContentFailsVerification() throws {
        let dir = try makeSnapshotDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let weights = dir.appendingPathComponent("weights.bin")

        try Data("hello".utf8).write(to: weights)
        try VoxOSRefineModelDownloader.verifySnapshot(at: dir, files: files)

        try Data("jello".utf8).write(to: weights)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: weights.path)
        #expect(VoxOSRefineModelDownloader.snapshotStatus(at: dir, files: files) == .needsVerification)
        #expect(throws: VoxOSRefineDownloadError.self) {
            try VoxOSRefineModelDownloader.verifySnapshot(at: dir, files: files)
        }
    }
}
