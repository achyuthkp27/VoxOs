import Foundation

/// What plays after the current track, and the audio format it plays in, from MediaRemote.
///
/// macOS only answers MediaRemote's queue to processes Apple signed, so each call runs
/// `now-playing.pl` in /usr/bin/perl with this framework's own library loaded into it, and reads
/// the one line of JSON it prints. A call is a short process, made when the notch asks (its Up
/// Next list opening, the track changing while the card is open), never on a timer.
public enum NowPlayingQueue {
    public struct Item: Equatable, Sendable {
        /// MediaRemote's identifier for the item, used to play it.
        public let id: String?
        public let title: String
        public let artist: String?
        public let album: String?
        /// Seconds.
        public let duration: Double?
        public let format: AudioFormat?
    }

    /// The format a track plays in, as the player reports it.
    public enum AudioFormat: String, Equatable, Sendable {
        case lossless
        case hiResLossless
        case dolbyAtmos
        case multichannel
    }

    /// The queue, current track first, up to `length` items; nil when it could not be read (the
    /// player has none, or macOS refused).
    public static func read(length: Int = 10) async -> [Item]? {
        let output = await run("queue", environment: ["VOXOS_QUEUE_LENGTH": String(max(1, min(length, 100)))])
        return output.flatMap(parse)
    }

    /// Plays the item `offset` places into the queue (1 is next).
    @discardableResult
    public static func play(offset: Int, id: String?) async -> Bool {
        var environment = ["VOXOS_QUEUE_OFFSET": String(max(0, offset))]
        if let id { environment["VOXOS_CONTENT_ITEM_ID"] = id }
        let output = await run("play-item", environment: environment)
        let object = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return object?["sent"] as? Bool ?? false
    }

    // MARK: Parsing

    /// `{"items": [...]}` from the helper; nil for `{"error": ...}` or anything else.
    public static func parse(_ data: Data) -> [Item]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["items"] as? [[String: Any]]
        else { return nil }
        return entries.compactMap { entry in
            guard let title = entry["title"] as? String, !title.isEmpty else { return nil }
            return Item(
                id: entry["id"] as? String, title: title, artist: entry["artist"] as? String,
                album: entry["album"] as? String, duration: (entry["duration"] as? NSNumber)?.doubleValue,
                format: (entry["format"] as? [String: Any]).flatMap(format))
        }
    }

    /// The format from MediaRemote's description of it: spatial audio first, then several channels,
    /// then a lossy bit rate (no badge), then lossless, high resolution above 48 kHz.
    public static func format(_ fields: [String: Any]) -> AudioFormat? {
        if (fields["spatialized"] as? NSNumber)?.boolValue == true { return .dolbyAtmos }
        if (fields["multiChannel"] as? NSNumber)?.boolValue == true { return .multichannel }
        if ((fields["bitrate"] as? NSNumber)?.intValue ?? 0) > 0 { return nil }
        guard let rate = (fields["sampleRate"] as? NSNumber)?.doubleValue, rate > 0 else { return nil }
        return rate > 48_000 ? .hiResLossless : .lossless
    }

    // MARK: Running the helper

    private final class Locator {}

    /// The helper's output, or nil if it could not be run or took longer than `timeout`.
    private static func run(_ command: String, environment: [String: String], timeout: TimeInterval = 5) async
        -> Data?
    {
        guard let script = Bundle.module.path(forResource: "now-playing", ofType: "pl"),
            let library = Bundle(for: Locator.self).executablePath
        else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [script, library, command]
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
