import Foundation
import Testing

@testable import VoxOS

/// A .bin only counts as an installed Whisper model when it is big enough and starts with the
/// ggml magic; a truncated download or a stray file must not be listed.
struct WhisperModelFileValidationTests {
    private func write(_ bytes: [UInt8], paddedTo size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-validation-\(UUID().uuidString).bin")
        var data = Data(bytes)
        data.append(Data(count: max(0, size - bytes.count)))
        try data.write(to: url)
        return url
    }

    @Test func acceptsGgmlMagicWithPlausibleSize() throws {
        let url = try write(WhisperModelManager.ggmlFileMagic, paddedTo: 2 * 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WhisperModelManager.isPlausibleWhisperModelFile(at: url))
    }

    @Test func rejectsWrongMagic() throws {
        let url = try write([0x00, 0x01, 0x02, 0x03], paddedTo: 2 * 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!WhisperModelManager.isPlausibleWhisperModelFile(at: url))
    }

    @Test func rejectsTruncatedFile() throws {
        let url = try write(WhisperModelManager.ggmlFileMagic, paddedTo: 4_096)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!WhisperModelManager.isPlausibleWhisperModelFile(at: url))
    }

    @Test func rejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.bin")
        #expect(!WhisperModelManager.isPlausibleWhisperModelFile(at: url))
    }
}
