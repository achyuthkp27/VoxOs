import Foundation
import Testing

@testable import VoxOSNowPlaying

@Suite struct NowPlayingQueueTests {
    @Test func readsTheHelpersAnswer() throws {
        let line = """
            {"items":[{"title":"Around the World","artist":"Someone","album":"A Single","duration":136.4,"id":"a1",\
            "format":{"sampleRate":44100,"bitDepth":24}},{"title":"Next One","duration":145},{"artist":"no title"}]}
            """
        let items = try #require(NowPlayingQueue.parse(Data(line.utf8)))
        #expect(items.count == 2, "an item with no title is left out")
        #expect(
            items[0]
                == .init(
                    id: "a1", title: "Around the World", artist: "Someone", album: "A Single",
                    duration: 136.4, format: .lossless))
        #expect(items[1].artist == nil && items[1].format == nil)
        #expect(NowPlayingQueue.parse(Data(#"{"error":"refused"}"#.utf8)) == nil)
        #expect(NowPlayingQueue.parse(Data("not json".utf8)) == nil)
    }

    @Test func namesTheFormat() {
        #expect(NowPlayingQueue.format(["sampleRate": 44100]) == .lossless)
        #expect(NowPlayingQueue.format(["sampleRate": 96000]) == .hiResLossless)
        #expect(NowPlayingQueue.format(["sampleRate": 48000, "spatialized": true]) == .dolbyAtmos)
        #expect(NowPlayingQueue.format(["sampleRate": 48000, "multiChannel": true]) == .multichannel)
        #expect(NowPlayingQueue.format(["sampleRate": 44100, "bitrate": 256000]) == nil, "lossy: no badge")
        #expect(NowPlayingQueue.format([:]) == nil)
    }
}
