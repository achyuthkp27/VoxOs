import AppKit
import Foundation
import SwiftUI

/// Support requests go to the project's GitHub issues, prefilled with the template and system
/// information. They used to be mailed to the upstream project's support address, which is a
/// third party that does not handle VoxOS.
@MainActor
struct EmailSupport {
    private static let newIssueURL = "https://github.com/achyuthkp27/VoxOs/issues/new"
    private static let supportEmailSubject = "VoxOS Support Request"
    /// GitHub rejects very long URLs, so a body beyond this is cut; the full system information
    /// is on the clipboard as well.
    private static let maximumBodyLength = 6_000

    static func generateSupportEmailBody() -> String {
        let systemInfo = SystemInfoService.shared.getSystemInfoString()

        return """

            ------------------------
            ✨ **SCREEN RECORDING HIGHLY RECOMMENDED** ✨
            ▶️ Create a quick screen recording showing the issue!
            ▶️ It helps me understand and fix the problem much faster.

            📝 ISSUE DETAILS:
            - What steps did you take before the issue occurred?
            - What did you expect to happen?
            - What actually happened instead?


            ## 📋 COMMON ISSUES:
            Check out our Common Issues page before opening a new issue: https://github.com/achyuthkp27/VoxOs/issues
            ------------------------

            System Information:
            \(systemInfo)


            """
    }

    /// A new-issue URL with the title and body prefilled.
    static func generateSupportEmailURL(body: String = "") -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: supportEmailSubject),
            URLQueryItem(name: "body", value: String(body.prefix(maximumBodyLength))),
        ]
        // URLComponents leaves "+" as is, and form decoding on the server would read it as a space.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    static func openSupportEmail() {
        // Also on the clipboard, in case the browser or GitHub drops part of a long prefilled body.
        SystemInfoService.shared.copySystemInfoToClipboard()

        if let issueURL = generateSupportEmailURL(body: generateSupportEmailBody()) {
            NSWorkspace.shared.open(issueURL)
        }
    }
}
