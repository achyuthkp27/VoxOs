import Foundation
import LLMkit
import Testing

@testable import VoxOS

/// What happens when the AI cleanup request goes wrong: at most one retry, and only after a
/// timeout the user asked to retry; each provider failure becomes the error the user is shown.
@MainActor
@Suite
struct EnhancementRetryTests {

    /// Fails with each of `failures` in turn, then answers "done".
    private final class Attempts {
        var failures: [Error]
        var count = 0
        init(_ failures: [Error]) { self.failures = failures }
        func next() throws -> String {
            count += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            return "done"
        }
    }

    @Test func aTimeoutIsRetriedOnceWhenTheUserTurnedThatOn() async throws {
        let attempts = Attempts([EnhancementError.timeout])
        var retries = 0
        let result = try await AIEnhancementService.retryingOnceOnTimeout(
            true, onRetry: { retries += 1 }, attempt: { try attempts.next() })
        #expect(result == "done")
        #expect(attempts.count == 2)
        #expect(retries == 1)
    }

    @Test func aSecondTimeoutIsNotRetried() async {
        let attempts = Attempts([EnhancementError.timeout, EnhancementError.timeout])
        await #expect(throws: EnhancementError.self) {
            try await AIEnhancementService.retryingOnceOnTimeout(true) { try attempts.next() }
        }
        #expect(attempts.count == 2)
    }

    @Test func aTimeoutIsNotRetriedWhenTheSettingIsOff() async {
        let attempts = Attempts([EnhancementError.timeout])
        await #expect(throws: EnhancementError.self) {
            try await AIEnhancementService.retryingOnceOnTimeout(false) { try attempts.next() }
        }
        #expect(attempts.count == 1)
    }

    @Test func otherFailuresAreNotRetried() async {
        let attempts = Attempts([EnhancementError.serverError])
        await #expect(throws: EnhancementError.self) {
            try await AIEnhancementService.retryingOnceOnTimeout(true) { try attempts.next() }
        }
        #expect(attempts.count == 1)
    }

    @Test func aLostConnectionIsReportedAsANetworkError() async {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        do {
            _ = try await AIEnhancementService.retryingOnceOnTimeout(true) { try Attempts([offline]).next() }
            Issue.record("expected a network error")
        } catch EnhancementError.networkError {
        } catch {
            Issue.record("expected a network error, got \(error)")
        }
    }

    // MARK: - Provider errors

    @Test func overloadAndOutageMapToTheirOwnErrors() {
        guard case .rateLimitExceeded = AIEnhancementService.mapLLMKitError(.httpError(statusCode: 429, message: ""))
        else {
            Issue.record("429 should be rate limited")
            return
        }
        guard case .serverError = AIEnhancementService.mapLLMKitError(.httpError(statusCode: 503, message: "")) else {
            Issue.record("503 should be a server error")
            return
        }
    }

    @Test func aMissingKeyMeansNotConfigured() {
        guard case .notConfigured = AIEnhancementService.mapLLMKitError(.missingAPIKey) else {
            Issue.record("a missing key should read as not configured")
            return
        }
    }

    @Test func anotherHTTPErrorKeepsItsStatusForTheUser() {
        guard
            case .customError(let message) = AIEnhancementService.mapLLMKitError(
                .httpError(statusCode: 401, message: "bad key"))
        else {
            Issue.record("401 should carry its message")
            return
        }
        #expect(message.contains("401"))
        #expect(message.contains("bad key"))
    }

    @Test func timeoutsAndEmptyRepliesMapToTheirOwnErrors() {
        guard case .timeout = AIEnhancementService.mapLLMKitError(.timeout) else {
            Issue.record("a timeout should stay a timeout")
            return
        }
        guard case .enhancementFailed = AIEnhancementService.mapLLMKitError(.noResultReturned) else {
            Issue.record("no result should read as failed")
            return
        }
    }

    // MARK: - Timeout

    @Test func theTimeoutIsSevenSecondsUntilTheUserSetsOne() {
        #expect(AIEnhancementService.timeout(storedSeconds: 0) == 7)
        #expect(AIEnhancementService.timeout(storedSeconds: -3) == 7)
        #expect(AIEnhancementService.timeout(storedSeconds: 20) == 20)
    }
}
