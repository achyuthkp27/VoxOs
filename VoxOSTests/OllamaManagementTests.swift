import Foundation
import Testing

@testable import VoxOS

struct OllamaManagementTests {

    // MARK: - Base URL

    @Test func emptyAddressFallsBackToDefault() {
        #expect(OllamaManagement.normalizedBaseURL("  ")?.absoluteString == "http://localhost:11434")
    }

    @Test func missingSchemeGetsHTTP() {
        #expect(OllamaManagement.normalizedBaseURL("localhost:11434")?.absoluteString == "http://localhost:11434")
    }

    @Test func trailingSlashesAreRemoved() {
        #expect(
            OllamaManagement.normalizedBaseURL("http://10.0.0.5:11434//")?.absoluteString == "http://10.0.0.5:11434")
    }

    @Test func nonHTTPSchemeIsRejected() {
        #expect(OllamaManagement.normalizedBaseURL("ftp://localhost:11434") == nil)
    }

    // MARK: - Cloud detection

    @Test func cloudTagsAreDetected() {
        #expect(OllamaManagement.isCloudModel(name: "gemma4:cloud"))
        #expect(OllamaManagement.isCloudModel(name: "gpt-oss:120b-cloud"))
        #expect(OllamaManagement.isCloudModel(name: "custom:latest", remoteHost: "https://ollama.com"))
    }

    @Test func localTagsAreNotCloud() {
        #expect(!OllamaManagement.isCloudModel(name: "qwen3.5:latest"))
        #expect(!OllamaManagement.isCloudModel(name: "cloudy"))
        #expect(!OllamaManagement.isCloudModel(name: "llama3.2", remoteHost: ""))
    }

    // MARK: - /api/tags

    @Test func tagsParseSizesAndCloudFlag() throws {
        let json = """
            {"models":[
              {"name":"gemma4:cloud","size":312,"remote_host":"https://ollama.com",
               "details":{"parameter_size":"32.7B"}},
              {"name":"qwen3.5:latest","size":6594474711,
               "details":{"format":"gguf","parameter_size":"9.7B"}}
            ]}
            """
        let models = try OllamaManagement.parseTags(Data(json.utf8))
        #expect(models.count == 2)
        #expect(models[0].isCloud)
        #expect(models[1].name == "qwen3.5:latest")
        #expect(models[1].sizeBytes == 6_594_474_711)
        #expect(models[1].parameterSize == "9.7B")
        #expect(!models[1].isCloud)
    }

    @Test func tagsWithoutOptionalFieldsStillParse() throws {
        let models = try OllamaManagement.parseTags(Data(#"{"models":[{"name":"tiny"}]}"#.utf8))
        #expect(models == [OllamaInstalledModel(name: "tiny", sizeBytes: 0, parameterSize: nil, isCloud: false)])
    }

    // MARK: - /api/pull stream

    @Test func pullLineWithCountsGivesFraction() throws {
        let line = #"{"status":"pulling 6a0746a1ec1a","digest":"sha256:6a07","total":200,"completed":50}"#
        let progress = try #require(OllamaManagement.parsePullLine(line))
        #expect(progress.status == "pulling 6a0746a1ec1a")
        #expect(progress.fraction == 0.25)
    }

    @Test func pullLineWithoutCountsHasNoFraction() throws {
        let progress = try #require(OllamaManagement.parsePullLine(#"{"status":"pulling manifest"}"#))
        #expect(progress.fraction == nil)
        #expect(!progress.isSuccess)
    }

    @Test func zeroTotalHasNoFraction() throws {
        let progress = try #require(OllamaManagement.parsePullLine(#"{"status":"x","total":0,"completed":0}"#))
        #expect(progress.fraction == nil)
    }

    @Test func successAndErrorLines() throws {
        #expect(try #require(OllamaManagement.parsePullLine(#"{"status":"success"}"#)).isSuccess)
        let failure = try #require(
            OllamaManagement.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#))
        #expect(failure.error == "pull model manifest: file does not exist")
    }

    @Test func blankOrGarbageLinesAreIgnored() {
        #expect(OllamaManagement.parsePullLine("") == nil)
        #expect(OllamaManagement.parsePullLine("not json") == nil)
    }

    // MARK: - Misc

    @Test func versionParses() {
        #expect(OllamaManagement.parseVersion(Data(#"{"version":"0.35.1"}"#.utf8)) == "0.35.1")
        #expect(OllamaManagement.parseVersion(Data("{}".utf8)) == nil)
    }

    @Test func modelNameValidation() {
        #expect(OllamaManagement.normalizedModelName("  qwen3:8b \n") == "qwen3:8b")
        #expect(OllamaManagement.normalizedModelName("   ") == nil)
        #expect(OllamaManagement.normalizedModelName("llama 3") == nil)
    }
}
