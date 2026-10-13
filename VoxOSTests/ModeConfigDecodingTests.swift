import Foundation
import Testing

@testable import VoxOS

/// Modes saved before a setting existed must decode to the global setting, not to a hardcoded
/// value that silently changes how they behave.
struct ModeConfigDecodingTests {

    private func encodedConfig(isTextFormattingEnabled: Bool) throws -> [String: Any] {
        let config = ModeConfig(
            name: "Notes", isAIEnhancementEnabled: false, isTextFormattingEnabled: isTextFormattingEnabled)
        let data = try JSONEncoder().encode(config)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> ModeConfig {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ModeConfig.self, from: data)
    }

    @Test func missingTextFormattingKeyFollowsGlobalSetting() throws {
        var object = try encodedConfig(isTextFormattingEnabled: false)
        object.removeValue(forKey: "isTextFormattingEnabled")

        let decoded = try decode(object)

        #expect(
            decoded.isTextFormattingEnabled
                == UserDefaults.standard.bool(forKey: DefaultsKeys.isTextFormattingEnabled))
    }

    @Test func storedTextFormattingValueIsKept() throws {
        #expect(try decode(encodedConfig(isTextFormattingEnabled: false)).isTextFormattingEnabled == false)
        #expect(try decode(encodedConfig(isTextFormattingEnabled: true)).isTextFormattingEnabled == true)
    }
}
