import Foundation

/// A section of a settings page, and the words a search finds it by.
///
/// `labels` are text the section shows, written exactly as in the view so a test can check each
/// one is still on screen; a label with a value in it is written up to the value. `synonyms` are
/// other words people search with. Labels are also matched in the app's language.
enum SettingsSection: CaseIterable, Hashable {
    case shortcuts, additionalShortcuts, recorder, pasting, transcription, agent, mcp, systemAudio
    case notchLook, notchHome, notchPages, notchMusic, notchSound, notchNotices, claudeCode
    case appSwitcher, appSwitcherLetters, windowSwitcher, appsLeftAlone
    case general, appearance, backup, diagnostics

    var terms: [String] { labels + synonyms }

    var labels: [String] {
        switch self {
        case .shortcuts:
            return [
                "Shortcuts", "Primary Shortcut", "Secondary Shortcut", "Add Second Shortcut", "Open Keyboard Settings",
                "Stop Dictation When You Stop Talking", "Press Return After Pasting",
                "Use the fn key (hold to talk, double-tap for Agent)",
            ]
        case .additionalShortcuts:
            return [
                "Additional Shortcuts", "Paste Last Transcription (Original)", "Paste Last Transcription (Enhanced)",
                "Retry Last Transcription", "Undo Last Paste", "Reset to default", "Cancel Recording",
                "Middle-Click Recording", "Activation Delay",
            ]
        case .recorder:
            return [
                "Recorder", "Recorder Position", "Live Text Display",
                "Shows live text while recording with realtime models.", "Left-Edge History",
            ]
        case .pasting:
            return [
                "Pasting", "Match Writing Style to the App", "Keep Clipboard Content", "Restore Delay", "250ms",
                "500ms",
                "Paste Method",
            ]
        case .transcription:
            return ["Transcription", "Identify Speakers"]
        case .agent:
            return [
                "Agent", "Control Mode", "Set a Mode for an App…", "Send When You Stop Talking", "Pause Before Sending",
                "Close After Opening Something", "Allow Risky Shell Commands",
                "Main and fallback model are set in AI Models.",
                "Plugins", "Open Plugins Folder", "Permissions", "Accessibility", "Accessibility missing",
                "Screen Recording", "Screen Recording missing",
            ]
        case .mcp:
            return ["MCP Servers", "Open Config", "Import from Claude Desktop", "Reload"]
        case .systemAudio:
            return [
                "System Audio", "Capture System Audio", "Keep Recent System Audio", "Remember", "15 seconds",
                "30 seconds", "60 seconds", "2 minutes", "Transcribe Recent Audio", "Paste at Cursor",
                "Save to History",
                "Capturing system audio…",
            ]
        case .notchLook:
            return ["Look", "Notch Material", "Liquid Glass", "Solid Black", "Always-Visible Notch Tab"]
        case .notchHome:
            return [
                "Notch Home", "Show in Full Screen", "Follow the Display in Use", "Hide from Screenshots & Sharing",
            ]
        case .notchPages:
            return ["Pages", "Reset"]
        case .notchMusic:
            return ["Music", "Music in the Notch", "Lyrics", "Live Music Bars", "Live Bars on Battery"]
        case .notchSound:
            return [
                "Sound Page", "Per-App Volume", "Sound Output", "Microphone Input", "Clipboard History", "Mirror",
            ]
        case .notchNotices:
            return [
                "Notices", "Volume & Brightness in the Notch", "Mic & Camera in Use", "Meeting Countdown",
                "Device Alerts", "Downloads", "Focus", "Unread Counts", "Rain Soon",
            ]
        case .claudeCode:
            return [
                "Claude Code", "Show Claude Code in the Notch", "Allow or Deny Requests from the Notch",
                "Show When a Session Is Working", "Quiet While Its Terminal Is in Front", "Install Hooks",
            ]
        case .appSwitcher:
            return [
                "App Switcher", "Switch Apps with a Key and a Letter", "Key to Hold", "Right ⌘ Command",
                "Right ⌥ Option", "Needs Accessibility to see the keys", "Open Accessibility Settings",
            ]
        case .appSwitcherLetters:
            return [
                "Letters", "Same Letter Again", "Hides the App", "Does Nothing", "Show Letters While Holding",
                "Add App…",
            ]
        case .windowSwitcher:
            return ["Window Switcher", "Show Windows with"]
        case .appsLeftAlone:
            return ["Apps Left Alone", "Leave an App Alone…"]
        case .general:
            return [
                "General", "Hide Dock Icon", "Launch at Login", "Automatically Check for Updates", "Check for Updates",
                "Reset Onboarding",
            ]
        case .appearance:
            return ["Appearance", "Language"]
        case .backup:
            return ["Backup", "Export Settings", "Export", "Import Settings", "Import"]
        case .diagnostics:
            return ["Diagnostics", "Export Logs", "Show in Finder"]
        }
    }

    var synonyms: [String] {
        switch self {
        case .shortcuts: return ["hotkey", "fn", "dictation"]
        case .additionalShortcuts: return ["hotkey", "escape", "scratch that", "undo"]
        case .recorder: return ["edge history", "hover", "battery", "power"]
        case .pasting: return ["clipboard"]
        case .transcription:
            return ["speakers", "diarization", "meeting", "conversation", "who spoke", "speaker labels"]
        case .agent: return ["per-app", "fallback", "failover", "shell"]
        case .mcp: return ["Model Context Protocol", "tools", "integrations"]
        case .systemAudio: return ["buffer"]
        case .notchLook: return ["notch", "tab", "glass"]
        case .notchHome:
            return [
                "full screen", "fullscreen", "external display", "monitor", "display", "screenshot", "screen sharing",
                "privacy",
            ]
        case .notchPages:
            return [
                "order", "reorder", "drag", "show page", "hide page", "enable", "disable", "timer", "pomodoro",
                "shelf", "calendar",
            ]
        case .notchMusic: return ["now playing", "visualizer"]
        case .notchSound:
            return [
                "mixer", "app volume", "speakers", "headphones", "output", "microphone", "clipboard", "camera",
                "webcam",
            ]
        case .notchNotices:
            return [
                "volume", "brightness", "HUD", "keys", "mute", "meeting", "zoom", "join", "bluetooth", "airpods",
                "wifi", "charging", "low battery", "download", "do not disturb", "unread", "badge", "rain",
            ]
        case .claudeCode: return ["hooks", "permission", "approve", "plan"]
        case .appSwitcher: return ["rcmd", "right command", "accessibility", "switch apps"]
        case .appSwitcherLetters: return ["letter", "assign", "hide app", "launch"]
        case .windowSwitcher:
            return ["windows", "tab", "thumbnails", "minimized", "Screen Recording", "snap", "half", "tile", "fill"]
        case .appsLeftAlone: return ["ignore", "games", "virtual machines", "remote desktop"]
        case .general: return ["dock", "login", "updates", "onboarding"]
        case .appearance: return ["interface", "dark", "light", "theme"]
        case .backup: return ["backup", "restore"]
        case .diagnostics: return ["logs"]
        }
    }
}
