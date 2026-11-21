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
    case keySounds, keySoundsBehavior, keySoundsQuietApps
    case focusBlur, focusBlurBehavior, focusBlurApps
    case prompter, prompterFollow, prompterLook
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
                "Retry Last Transcription", "Undo Last Paste", "Start or Stop Meeting Notes",
                "Show or Hide Live Transcript", "Reset to default", "Cancel Recording",
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
                "Notch Home", "Lock Screen Widgets", "Show in Full Screen", "Follow the Display in Use",
                "Hide from Screenshots & Sharing",
            ]
        case .notchPages:
            return ["Pages", "Reset"]
        case .notchMusic:
            return ["Music", "Music in the Notch", "Lyrics", "Live Music Bars", "Live Bars on Battery"]
        case .notchSound:
            return [
                "Sound Page", "Per-App Volume", "Sound Output", "Microphone Input", "Mirror",
            ]
        case .notchNotices:
            return [
                "Notices", "Volume & Brightness in the Notch", "Level Style", "Notifications", "Mic & Camera in Use",
                "Meeting Countdown",
                "Meeting Notes", "Include My Microphone", "Show Live Transcript",
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
        case .keySounds:
            return [
                "Key Sounds", "Play a Sound as You Type", "Switch", "Preview", "Volume",
                "Needs Accessibility to hear the keys", "Open Accessibility Settings",
            ]
        case .keySoundsBehavior:
            return [
                "How Keys Sound", "Sound When Keys Are Let Go", "Place Keys Left and Right",
                "Vary the Pitch of Each Press", "Quiet While the Microphone Is in Use",
            ]
        case .keySoundsQuietApps:
            return ["Quiet Apps", "Keep an App Quiet…"]
        case .focusBlur:
            return ["Focus Blur", "Blur Every Window but the One in Use", "Blur", "Tint", "Dim", "Film Grain"]
        case .focusBlurBehavior:
            return [
                "Which Windows Stay Sharp", "Keep the App's Other Windows Sharp", "Other Displays",
                "Shake the Pointer to Turn On or Off",
            ]
        case .focusBlurApps:
            return ["Never Blur Behind", "Add an App…"]
        case .prompter:
            return ["Voice Prompter", "Show Prompter", "Close Prompter", "Load from Clipboard"]
        case .prompterFollow:
            return ["Follow", "Words Read Aloud", "Steady Pace", "Pace", "Only While Speaking", "Mic Sensitivity"]
        case .prompterLook:
            return [
                "Prompter Look", "Text Size", "Lines Shown:", "Width", "Background", "Text Color",
                "Hide from Screenshots & Sharing",
            ]
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
        case .additionalShortcuts: return ["hotkey", "escape", "scratch that", "undo", "meeting", "notes"]
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
                "lock screen", "locked", "widgets", "full screen", "fullscreen", "external display", "monitor",
                "display", "screenshot", "screen sharing",
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
                "mixer", "app volume", "speakers", "headphones", "output", "microphone", "camera",
                "webcam",
            ]
        case .notchNotices:
            return [
                "volume", "brightness", "HUD", "keys", "mute", "meeting", "zoom", "join", "bluetooth", "airpods",
                "wifi", "charging", "low battery", "download", "do not disturb", "unread", "badge", "rain", "notes",
                "summary", "action items", "record call", "transcript", "HUD", "segments", "percentage",
                "notification", "banner", "charging", "charged",
            ]
        case .claudeCode: return ["hooks", "permission", "approve", "plan"]
        case .appSwitcher: return ["rcmd", "right command", "accessibility", "switch apps"]
        case .appSwitcherLetters: return ["letter", "assign", "hide app", "launch"]
        case .windowSwitcher:
            return ["windows", "tab", "thumbnails", "minimized", "Screen Recording", "snap", "half", "tile", "fill"]
        case .appsLeftAlone: return ["ignore", "games", "virtual machines", "remote desktop"]
        case .keySounds:
            return [
                "keyboard", "typing", "mechanical", "click", "clicky", "linear", "tactile", "thock", "typewriter",
                "laptop",
            ]
        case .keySoundsBehavior: return ["key up", "release", "stereo", "spatial", "pan", "pitch", "call", "mic"]
        case .keySoundsQuietApps: return ["mute", "ignore", "games", "exclude"]
        case .focusBlur: return ["focus", "distraction", "dim", "darken", "frosted", "glass", "grain", "noise"]
        case .focusBlurBehavior: return ["app windows", "monitor", "display", "screens", "shake", "gesture"]
        case .focusBlurApps: return ["ignore", "exclude", "unblurred"]
        case .prompter: return ["teleprompter", "script", "speech", "notes", "presentation", "video", "camera"]
        case .prompterFollow: return ["scroll", "speed", "wpm", "words per minute", "microphone", "auto scroll"]
        case .prompterLook: return ["font", "size", "opacity", "screen sharing", "zoom", "hide", "colour", "resize"]
        case .general: return ["dock", "login", "updates", "onboarding"]
        case .appearance: return ["interface", "dark", "light", "theme"]
        case .backup: return ["backup", "restore"]
        case .diagnostics: return ["logs"]
        }
    }
}
