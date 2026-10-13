import Foundation
import Testing

@testable import VoxOS

/// The Messages reader hands private history straight to the model, so the risks are a wrong
/// timestamp, an uncapped body and a mis-decoded blob. Pure functions only; the real chat.db is
/// never opened here.
@Suite
struct AgentMessagesTests {

    /// Builds the slice of a typedstream blob the decoder cares about: junk, marker, header, length, text.
    private func blob(text: String, lengthBytes: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64]
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += lengthBytes
        bytes += Array(text.utf8)
        bytes += [0x86, 0x84, 0x02, 0x69, 0x49]  // trailing attribute run, must be ignored
        return Data(bytes)
    }

    @Test func appleDateReadsNanosecondsAndSeconds() {
        let seconds: Int64 = 700_000_000
        let nanoseconds: Int64 = seconds * 1_000_000_000 + 123_456_789
        #expect(AgentMessages.appleDate(seconds).timeIntervalSinceReferenceDate == 700_000_000)
        let fromNanos = AgentMessages.appleDate(nanoseconds).timeIntervalSinceReferenceDate
        #expect(abs(fromNanos - 700_000_000.123_456_789) < 0.001)
        #expect(AgentMessages.appleDate(0).timeIntervalSinceReferenceDate == 0)
    }

    @Test func clipTrimsAndCapsLongBodies() {
        #expect(AgentMessages.clip("  hi there\n") == "hi there")
        let short = String(repeating: "a", count: 300)
        #expect(AgentMessages.clip(short) == short)
        let long = String(repeating: "b", count: 301)
        let clipped = AgentMessages.clip(long)
        #expect(clipped.hasSuffix("…"))
        #expect(clipped.count == 301)
        #expect(clipped.dropLast() == String(repeating: "b", count: 300))
    }

    @Test func decodesSingleByteLengthBody() {
        let data = blob(text: "See you at 7?", lengthBytes: [UInt8("See you at 7?".utf8.count)])
        #expect(AgentMessages.text(fromAttributedBody: data) == "See you at 7?")
    }

    @Test func decodesTwoByteLengthBody() {
        let text = String(repeating: "x", count: 300) + " end"
        let count = text.utf8.count
        let data = blob(text: text, lengthBytes: [0x81, UInt8(count & 0xFF), UInt8(count >> 8)])
        #expect(AgentMessages.text(fromAttributedBody: data) == text)
    }

    @Test func decodesMultibyteUTF8ByByteLength() {
        let text = "café ☕"
        let data = blob(text: text, lengthBytes: [UInt8(text.utf8.count)])
        #expect(AgentMessages.text(fromAttributedBody: data) == text)
    }

    @Test func junkBlobsDecodeToNilNotGarbage() {
        #expect(AgentMessages.text(fromAttributedBody: Data()) == nil)
        #expect(AgentMessages.text(fromAttributedBody: Data("no marker here".utf8)) == nil)
        #expect(AgentMessages.text(fromAttributedBody: Data("NSString".utf8)) == nil, "marker with nothing after")
        let truncated = blob(text: "short", lengthBytes: [0x7F])
        #expect(AgentMessages.text(fromAttributedBody: truncated) == nil, "length runs past the blob")
        let zero = blob(text: "", lengthBytes: [0x00])
        #expect(AgentMessages.text(fromAttributedBody: zero) == nil, "empty body is not a message")
    }

    @Test func itemMapsIncomingRow() {
        let raw: Int64 = 700_000_000 * 1_000_000_000
        let row = AgentMessages.Row(
            text: "lunch?", attributedBody: nil, date: raw, isFromMe: false,
            handle: "+15551234567", chatDisplayName: nil, chatIdentifier: "+15551234567")
        let item = AgentMessages.item(from: row)
        #expect(item["when"] as? String == AgentMessages.format(AgentMessages.appleDate(raw)))
        #expect((item["when"] as? String)?.count == 16, "YYYY-MM-DD HH:mm")
        #expect(item["from"] as? String == "+15551234567")
        #expect(item["chat"] as? String == "+15551234567")
        #expect(item["text"] as? String == "lunch?")
    }

    @Test func itemMarksOwnMessagesAndPrefersChatDisplayName() {
        let row = AgentMessages.Row(
            text: nil, attributedBody: blob(text: "on my way", lengthBytes: [9]), date: 700_000_000, isFromMe: true,
            handle: nil, chatDisplayName: "Family", chatIdentifier: "chat123")
        let item = AgentMessages.item(from: row)
        #expect(item["from"] as? String == "me")
        #expect(item["chat"] as? String == "Family")
        #expect(item["text"] as? String == "on my way", "body falls back to the decoded blob")
    }

    @Test func itemFallsBackWhenBodyIsMissing() {
        let row = AgentMessages.Row(
            text: nil, attributedBody: Data([0x01, 0x02]), date: 700_000_000, isFromMe: false,
            handle: "a@b.com", chatDisplayName: "", chatIdentifier: nil)
        let item = AgentMessages.item(from: row)
        #expect(item["text"] as? String == AgentMessages.unsupportedBody)
        #expect(item["chat"] as? String == "a@b.com", "empty display name and no identifier fall back to the handle")
    }

    @Test func likePatternEscapesWildcards() {
        #expect(AgentMessages.likePattern(for: "Mom") == "%mom%")
        #expect(AgentMessages.likePattern(for: "50%_off") == "%50\\%\\_off%")
    }
}
