import Foundation

/// A section of a settings page, and the words a search finds it by.
enum SettingsSection: CaseIterable {
    case shortcuts, additionalShortcuts, systemAudio, agent, mcp, claudeCode, pasting, transcription, recorder,
        appearance, notchLook, notchHome, notchMusic, notchSound, notchNotices, notchPages, general, appSwitcher,
        backup, diagnostics

    // Keywords come from the text each section actually shows, so a toggle is found by what
    // is written next to it rather than by the heading it happens to live under.
    var terms: [String] {
        switch self {
        case .shortcuts:
            return [
                "Primary Shortcut", "Secondary Shortcut", "Add Second Shortcut", "Open Keyboard Settings",
                "Stop Dictation When You Stop Talking", "Press Return After Pasting",
                "Use the fn key (hold to talk, double-tap for Agent)", "Shortcuts",
            ]
        case .additionalShortcuts:
            return [
                "Additional Shortcuts", "Paste Last Transcription (Original)", "Paste Last Transcription (Enhanced)",
                "Retry Last Transcription", "Reset to default", "Cancel Recording", "Middle-Click Recording",
                "Activation Delay",
            ]
        case .systemAudio:
            return [
                "Capture System Audio", "Keep Recent System Audio", "Remember", "15 seconds", "30 seconds",
                "60 seconds", "2 minutes", "Transcribe Recent Audio", "Paste at Cursor", "Save to History",
                "System Audio", "Capturing system audio…",
            ]
        case .agent:
            return [
                "Control Mode", "Set a Mode for an App", "per-app", "Send When You Stop Talking",
                "Pause Before Sending", "Allow Risky Shell Commands", "Plugins", "Open Plugins Folder", "Permissions",
                "Accessibility", "Accessibility missing", "Screen Recording", "Screen Recording missing", "Agent",
                "Close After Opening Something", "Fall Back To Other Providers", "fallback", "failover",
            ]
        case .mcp:
            return [
                "MCP Servers", "Model Context Protocol", "tools", "integrations", "Open Config",
                "Import from Claude Desktop", "Reload",
            ]
        case .claudeCode:
            return [
                "Claude Code", "Show Claude Code in the Notch", "Allow or Deny Requests from the Notch",
                "Show When a Session Is Working", "Quiet While Its Terminal Is in Front", "Install Hooks", "hooks",
                "permission", "approve", "plan",
            ]
        case .pasting:
            return [
                "Pasting", "Match Writing Style to the App", "Keep Clipboard Content", "Restore Delay", "250ms",
                "500ms", "Paste Method",
            ]
        case .transcription:
            return [
                "Transcription", "Identify Speakers", "speakers", "diarization", "meeting", "conversation", "who spoke",
                "speaker labels",
            ]
        case .recorder:
            return [
                "Recorder", "Recorder Position", "Live Text Display",
                "Shows live text while recording with realtime models.", "Left-Edge History", "Edge History", "battery",
                "hover", "power",
            ]
        case .appearance:
            return [
                "Appearance", "Language", "Interface", "dark", "light", "theme",
            ]
        case .notchLook:
            return [
                "Look", "Notch Material", "Liquid Glass", "Solid Black", "Always-Visible Notch Tab", "notch", "tab",
            ]
        case .notchHome:
            return [
                "Notch Home", "Show in Full Screen", "full screen", "fullscreen", "Follow the Display in Use",
                "external display", "monitor", "display", "Hide from Screenshots & Sharing", "screenshot",
                "screen sharing", "privacy",
            ]
        case .notchMusic:
            return [
                "Music", "Music in the Notch", "Lyrics", "Live Music Bars", "Live Bars on Battery", "now playing",
                "visualizer",
            ]
        case .notchSound:
            return [
                "Sound Page", "Per-App Volume", "mixer", "app volume", "Sound Output", "speakers", "headphones",
                "output", "Microphone Input", "microphone", "Clipboard History", "clipboard", "Mirror", "camera",
                "webcam", "keep awake", "caffeinate",
            ]
        case .notchNotices:
            return [
                "Notices", "Volume & Brightness in the Notch", "volume", "brightness", "HUD", "keys",
                "Mic & Camera in Use", "mute", "Meeting Countdown", "meeting", "zoom", "join", "Device Alerts",
                "bluetooth", "airpods", "wifi", "charging", "low battery", "Downloads", "download", "Focus",
                "do not disturb", "Unread Counts", "unread", "badge", "Rain Soon", "rain",
            ]
        case .notchPages:
            return [
                "Notch Pages", "Pages", "Page Order", "timer", "pomodoro", "shelf", "calendar", "Reorder", "order",
                "enable", "disable", "show page", "hide page", "drag",
            ]
        case .general:
            return [
                "General", "Hide Dock Icon", "Launch at Login", "Automatically Check for Updates", "Check for Updates",
                "Reset Onboarding",
            ]
        case .appSwitcher:
            return [
                "App Switcher", "Switch Apps with a Key and a Letter", "Key to Hold", "Right Command", "rcmd",
                "Accessibility", "Letters", "letter", "Same Letter Again", "Hides the App",
                "Show Letters While Holding", "Add App", "hide app", "launch", "Window Switcher", "Show Windows with",
                "Tab", "windows", "thumbnails", "Screen Recording", "Apps Left Alone", "Leave an App Alone", "games",
                "virtual machines", "remote desktop",
            ]
        case .backup:
            return [
                "Export Settings", "Export", "Import Settings", "Import", "Backup",
            ]
        case .diagnostics:
            return [
                "Diagnostics", "Export Logs", "Show in Finder",
            ]
        }
    }
}
