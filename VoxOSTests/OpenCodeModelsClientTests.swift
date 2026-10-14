import Foundation
import Testing

@testable import VoxOS

/// OpenCode's list comes from OpenCode; what VoxOS decides is only which entries it can use.
@Suite
struct OpenCodeModelsClientTests {

    @Test func readsOpenAIStyleAndBareLists() {
        let wrapped = Data(#"{"object":"list","data":[{"id":"kimi-k3"},{"id":"big-pickle"}]}"#.utf8)
        #expect(OpenCodeModelsClient.modelIDs(from: wrapped) == ["kimi-k3", "big-pickle"])
        let bare = Data(#"[{"id":"glm-5.3"}]"#.utf8)
        #expect(OpenCodeModelsClient.modelIDs(from: bare) == ["glm-5.3"])
        #expect(OpenCodeModelsClient.modelIDs(from: Data("nope".utf8)) == nil)
    }

    @Test func modelsOnOtherRequestFormatsAreLeftOut() {
        let models = OpenCodeModelsClient.chatModels(from: [
            "claude-haiku-5-5", "gpt-6-luna", "gemini-3.8-flash", "grok-4.7", "muse-spark-1.3", "jev-1.13-free",
            "deepseek-v4-flash", "kimi-k3",
        ])
        #expect(models == ["deepseek-v4-flash", "kimi-k3"])
    }

    @Test func freeModelsComeFirst() {
        let models = OpenCodeModelsClient.chatModels(from: [
            "kimi-k3", "nemotron-3.5-lightning-free", "big-pickle", "deepseek-v4-flash",
        ])
        #expect(models == ["big-pickle", "nemotron-3.5-lightning-free", "deepseek-v4-flash", "kimi-k3"])
    }
}
