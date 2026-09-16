import AppKit
import Foundation

/// Where dictated text is about to land, and the writing register that fits it.
/// "It writes to fit where it lands": formal in Mail, casual in Slack, lists in Notes.
struct WritingDestination: Equatable {

    enum Category: String, CaseIterable {
        case email
        case chat
        case aiChat
        case notes
        case document
        case code
        case terminal
        case other
    }

    let bundleID: String
    let appName: String
    let host: String?
    let category: Category

    static let isEnabledKey = "MatchWritingStyleToApp"

    /// On by default; a missing value means the user never turned it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    // MARK: - Classification

    private static let appCategories: [String: Category] = [
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.superhuman.electron": .email,
        "com.readdle.SparkDesktop": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.mimestream.Mimestream": .email,
        "ch.protonmail.desktop": .email,
        "it.bloop.airmail2": .email,
        // Chat
        "com.apple.MobileSMS": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "desktop.WhatsApp": .chat,
        "com.tinyspeck.slackmacgap": .chat,
        "ru.keepcoder.Telegram": .chat,
        "org.telegram.desktop": .chat,
        "com.hnc.Discord": .chat,
        "com.microsoft.teams": .chat,
        "com.microsoft.teams2": .chat,
        "com.facebook.archon": .chat,
        "com.facebook.archon.developerID": .chat,
        "org.whispersystems.signal-desktop": .chat,
        "com.apple.iChat": .chat,
        // AI assistants
        "com.openai.chat": .aiChat,
        "com.anthropic.claudefordesktop": .aiChat,
        "com.perplexity.mac": .aiChat,
        // Notes
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "notion.id": .notes,
        "net.shinyfrog.bear": .notes,
        "com.agiletortoise.Drafts-OSX": .notes,
        "com.lukilabs.lukiapp": .notes,
        "com.apple.reminders": .notes,
        // Documents
        "com.apple.iWork.Pages": .document,
        "com.microsoft.Word": .document,
        "com.apple.TextEdit": .document,
        "com.apple.iWork.Keynote": .document,
        // Code
        "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code,
        "com.apple.dt.Xcode": .code,
        "dev.zed.Zed": .code,
        "com.exafunction.windsurf": .code,
        "com.sublimetext.4": .code,
        // Terminals
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "io.alacritty": .terminal,
        "co.zeit.hyper": .terminal,
    ]

    private static let hostCategories: [(host: String, category: Category)] = [
        ("mail.google.com", .email),
        ("outlook.live.com", .email),
        ("outlook.office.com", .email),
        ("outlook.office365.com", .email),
        ("app.superhuman.com", .email),
        ("mail.proton.me", .email),
        ("mail.yahoo.com", .email),
        ("app.hey.com", .email),
        ("web.whatsapp.com", .chat),
        ("app.slack.com", .chat),
        ("web.telegram.org", .chat),
        ("discord.com", .chat),
        ("teams.microsoft.com", .chat),
        ("teams.live.com", .chat),
        ("messenger.com", .chat),
        ("chat.google.com", .chat),
        ("linkedin.com/messaging", .chat),
        ("chatgpt.com", .aiChat),
        ("claude.ai", .aiChat),
        ("gemini.google.com", .aiChat),
        ("perplexity.ai", .aiChat),
        ("notion.so", .notes),
        ("keep.google.com", .notes),
        ("docs.google.com", .document),
        ("github.com", .code),
    ]

    static func classify(bundleID: String, url: String?) -> Category {
        if let url, let fromURL = category(forURL: url) { return fromURL }
        if let category = appCategories[bundleID] { return category }
        if bundleID.hasPrefix("com.jetbrains.") { return .code }
        return .other
    }

    static func category(forURL raw: String) -> Category? {
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased() else {
            return nil
        }
        let path = components.path.lowercased()
        for entry in hostCategories {
            let parts = entry.host.split(separator: "/", maxSplits: 1).map(String.init)
            let entryHost = parts[0]
            guard host == entryHost || host.hasSuffix("." + entryHost) else { continue }
            if parts.count == 2, !path.hasPrefix("/" + parts[1]) { continue }
            return entry.category
        }
        return nil
    }

    // MARK: - Capture

    /// The frontmost app, plus the tab's URL when it is a browser. Call at recording start:
    /// the recorder panel never takes focus, so this is where the text will be pasted.
    @MainActor
    static func captureFrontmost() async -> WritingDestination? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
            bundleID != Bundle.main.bundleIdentifier
        else { return nil }

        var url: String?
        if let browser = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleID }) {
            url = try? await BrowserURLService.shared.getCurrentURL(from: browser)
        }
        let host = url.flatMap { URLComponents(string: $0.contains("://") ? $0 : "https://" + $0)?.host }
        return WritingDestination(
            bundleID: bundleID, appName: app.localizedName ?? bundleID, host: host,
            category: classify(bundleID: bundleID, url: url))
    }

    // MARK: - Prompt guidance

    var promptGuidance: String? {
        let place = host.map { "\(appName) (\($0))" } ?? appName
        let register: String
        switch category {
        case .email:
            register =
                "an email. Write complete, well-punctuated sentences, with a paragraph break where the topic changes. Keep a greeting or sign-off only if the speaker dictated one; never invent one."
        case .chat:
            register =
                "a chat message. Keep it short and conversational; contractions are fine. No greeting or sign-off unless dictated, and no trailing period after a single short sentence."
        case .aiChat:
            register =
                "a request to an AI assistant. Keep every detail of the request, structured clearly; drop pleasantries and filler."
        case .notes:
            register = "notes. Prefer short lines, and turn spoken lists into bulleted lists."
        case .document:
            register = "a document. Use complete sentences and paragraphs, and turn spoken lists into lists."
        case .code:
            register =
                "a code editor or coding assistant. Write identifiers, file names, paths and symbols in code form (camelCase, snake_case, dots and slashes) exactly as meant, with no added prose."
        case .terminal:
            register =
                "a terminal. Output only the command or text as meant, with no capitalisation of commands and no trailing period."
        case .other:
            return nil
        }
        return """
            # Destination
            The text will be pasted into \(place): \(register) The instructions above take priority if they say otherwise.
            """
    }
}

/// Deterministic touches applied just before pasting, so they work with every model —
/// including VoxOS Refine, whose fixed prompt cannot take destination instructions.
enum WritingStyleFormatter {

    static func apply(_ text: String, category: WritingDestination.Category) -> String {
        switch category {
        case .chat, .terminal:
            return droppingLoneTrailingPeriod(text)
        default:
            return text
        }
    }

    /// "sounds good." → "sounds good". Only for one short sentence on one line; an ellipsis,
    /// a multi-sentence message, or an abbreviation-looking ending ("etc.") is left alone.
    static func droppingLoneTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."), trimmed.count <= 160,
            !trimmed.contains(where: \.isNewline)
        else { return text }

        let body = trimmed.dropLast()
        // Another sentence boundary inside means this is more than one sentence.
        let innerBoundary = body.range(of: #"[.!?]\s"#, options: .regularExpression) != nil
        guard !innerBoundary else { return text }

        let lastWord = body.split(separator: " ").last.map { $0.lowercased() } ?? ""
        let abbreviations: Set<String> = [
            "etc", "vs", "e.g", "i.e", "approx", "dept", "inc", "ltd", "jr", "sr", "dr", "mr", "mrs", "ms",
        ]
        guard !abbreviations.contains(lastWord) else { return text }

        let leading = text.prefix { $0.isWhitespace || $0.isNewline }
        let trailing = String(text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leading) + String(body) + trailing
    }
}

/// The destination captured when the current recording started. Pasting only trusts it while
/// the same app is still frontmost; otherwise it falls back to classifying that app directly.
@MainActor
enum WritingDestinationStore {
    private(set) static var current: WritingDestination?

    static func set(_ destination: WritingDestination?) {
        current = destination
    }

    static func categoryForPaste() -> WritingDestination.Category {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return .other }
        if let current, current.bundleID == bundleID { return current.category }
        return WritingDestination.classify(bundleID: bundleID, url: nil)
    }
}
