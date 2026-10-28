import Foundation

/// The line of the song being sung, on the Music page, from LRCLIB (lrclib.net: free, keyless,
/// community lyrics with timings).
///
/// Off by default, since looking a song up tells that service its title and artist. Asked once
/// per track, only while the Music page is open, and kept for the run.
@MainActor
final class NotchLyrics: ObservableObject {
    static let shared = NotchLyrics()

    struct Line: Equatable {
        /// Seconds from the start of the track.
        let time: Double
        let text: String
    }

    static let service = URL(string: "https://lrclib.net/api/get")!

    /// The current track's timed lines; empty when it has none or none were found.
    @Published private(set) var lines: [Line] = []

    private var trackKey: String?
    private var cache: [String: [Line]] = [:]
    private var task: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchLyricsEnabled) }

    private init() {}

    func load(title: String, artist: String, duration: Double?) {
        let key = artist + "\n" + title
        guard key != trackKey else { return }
        trackKey = key
        task?.cancel()
        if let cached = cache[key] {
            lines = cached
            return
        }
        lines = []
        guard var components = URLComponents(url: Self.service, resolvingAgainstBaseURL: false) else { return }
        components.queryItems =
            [
                URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist),
            ] + (duration.map { [URLQueryItem(name: "duration", value: String(Int($0.rounded())))] } ?? [])
        guard let url = components.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // LRCLIB asks clients to say who they are.
        request.setValue("VoxOS (https://github.com/achyuthkp27/VoxOs)", forHTTPHeaderField: "User-Agent")
        task = Task { @MainActor [weak self] in
            let found: [Line]
            if let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let synced = object["syncedLyrics"] as? String
            {
                found = Self.parse(synced)
            } else {
                found = []
            }
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            self.cache[key] = found
            self.lines = found
        }
    }

    func clear() {
        task?.cancel()
        trackKey = nil
        lines = []
    }

    /// LRC: "[mm:ss.xx] words" per line; a line may carry several times.
    nonisolated static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        let stamp = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = stamp?.matches(in: raw, range: range) ?? []
            guard let last = matches.last, let end = Range(last.range, in: raw) else { continue }
            let text = raw[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                    let seconds = Range(match.range(at: 2), in: raw).flatMap({ Double(raw[$0]) })
                else { continue }
                lines.append(Line(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// The line being sung at `position`, if one has started and says something.
    nonisolated static func line(at position: Double, in lines: [Line]) -> String? {
        guard let current = lines.last(where: { $0.time <= position }), !current.text.isEmpty else { return nil }
        return current.text
    }
}
