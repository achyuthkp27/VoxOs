import Foundation
import Testing

@testable import VoxOS

/// This decides whether to refuse an enhancement before trying it, so the costly mistake is
/// refusing one that would have worked. Most of these check that it stays permissive.
@Suite
struct EnhancementReachabilityTests {

    @Test func onDeviceProvidersNeverNeedInternet() {
        #expect(!EnhancementReachability.requiresInternet(provider: .voxOSRefine, baseURL: nil))
        #expect(!EnhancementReachability.requiresInternet(provider: .localCLI, baseURL: nil))
    }

    @Test func hostedProvidersNeedInternet() {
        for provider in [AIProvider.openAI, .anthropic, .groq, .gemini, .mistral, .openRouter] {
            #expect(EnhancementReachability.requiresInternet(provider: provider, baseURL: nil), "\(provider)")
        }
    }

    @Test func ollamaOnLocalhostDoesNotNeedInternet() {
        #expect(
            !EnhancementReachability.requiresInternet(
                provider: .ollama, baseURL: "http://localhost:11434/api/chat"))
        #expect(
            !EnhancementReachability.requiresInternet(
                provider: .ollama, baseURL: "http://127.0.0.1:11434/api/chat"))
    }

    @Test func ollamaPointedAtAnotherMachineOnTheInternetDoesNeedIt() {
        #expect(
            EnhancementReachability.requiresInternet(
                provider: .ollama, baseURL: "https://ollama.example.com/api/chat"))
    }

    @Test func aModelOnTheLocalNetworkStillWorksWithTheInternetDown() {
        // A self-hosted model on the LAN is reachable while the WAN is down; refusing it would
        // break a working setup.
        for address in [
            "http://192.168.1.50:11434", "http://10.0.0.7:8080", "http://172.16.4.2:1234",
            "http://172.31.255.1:1234", "http://mac-studio.local:11434",
        ] {
            #expect(
                !EnhancementReachability.requiresInternet(provider: .custom, baseURL: address),
                "\(address) should count as local")
        }
    }

    @Test func addressesOutsideThePrivateRangesAreNotLocal() {
        // 172.32 is outside 172.16–172.31, and 11.x is not private at all.
        #expect(EnhancementReachability.requiresInternet(provider: .custom, baseURL: "http://172.32.0.1:80"))
        #expect(EnhancementReachability.requiresInternet(provider: .custom, baseURL: "http://11.0.0.1:80"))
    }

    @Test func anUnusableAddressIsNotReportedAsAnOutage() {
        // Missing or malformed config is the "not configured" path's problem to report; saying
        // "you are offline" would send the user to debug the wrong thing.
        #expect(!EnhancementReachability.requiresInternet(provider: .custom, baseURL: nil))
        #expect(!EnhancementReachability.requiresInternet(provider: .custom, baseURL: ""))
        #expect(!EnhancementReachability.requiresInternet(provider: .custom, baseURL: "   "))
        #expect(!EnhancementReachability.requiresInternet(provider: .custom, baseURL: "not a url at all"))
    }

    @Test func hostMatchingIgnoresCaseAndPath() {
        #expect(EnhancementReachability.isLocalAddress("http://LOCALHOST:11434/api/chat"))
        #expect(EnhancementReachability.isLocalAddress("http://Mac-Studio.LOCAL:1234/v1"))
    }
}
