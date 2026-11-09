import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case secondaryRecording
    case pasteLastTranscription
    case pasteLastEnhancement
    case retryLastTranscription
    case cancelRecorder
    case openHistoryWindow
    case quickAddToDictionary
    case undoLastPaste
    case toggleMeetingNotes
    case toggleLiveTranscript
    case captureSystemAudio
    case recallSystemAudio
    case agentDoubleTap
    case dictateAndSend
    case mode(UUID)
    case recorderPanelEscape
    case recorderPanelMode(Int)

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape, .recorderPanelMode:
            return false
        default:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .secondaryRecording:
            return "secondaryRecording"
        case .pasteLastTranscription:
            return "pasteLastTranscription"
        case .pasteLastEnhancement:
            return "pasteLastEnhancement"
        case .retryLastTranscription:
            return "retryLastTranscription"
        case .cancelRecorder:
            return "cancelRecorder"
        case .openHistoryWindow:
            return "openHistoryWindow"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .undoLastPaste:
            return "undoLastPaste"
        case .toggleMeetingNotes:
            return "toggleMeetingNotes"
        case .toggleLiveTranscript:
            return "toggleLiveTranscript"
        case .captureSystemAudio:
            return "captureSystemAudio"
        case .recallSystemAudio:
            return "recallSystemAudio"
        case .agentDoubleTap:
            return "agentDoubleTap"
        case .dictateAndSend:
            return "dictateAndSend"
        case .mode(let id):
            return "mode_\(id.uuidString)"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        case .recorderPanelMode(let index):
            return "recorderPanelMode_\(index)"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .secondaryRecording:
            return String(localized: "Secondary Shortcut")
        case .pasteLastTranscription:
            return String(localized: "Paste Last Transcription")
        case .pasteLastEnhancement:
            return String(localized: "Paste Last Enhanced Transcription")
        case .retryLastTranscription:
            return String(localized: "Retry Last Transcription")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .openHistoryWindow:
            return String(localized: "Open History Window")
        case .quickAddToDictionary:
            return String(localized: "Quick Add to Dictionary")
        case .undoLastPaste:
            return String(localized: "Undo Last Paste")
        case .toggleMeetingNotes:
            return String(localized: "Start or Stop Meeting Notes")
        case .toggleLiveTranscript:
            return String(localized: "Show or Hide Live Transcript")
        case .captureSystemAudio:
            return String(localized: "Capture System Audio")
        case .recallSystemAudio:
            return String(localized: "Transcribe Recent System Audio")
        case .agentDoubleTap:
            return String(localized: "Agent (double-tap)")
        case .dictateAndSend:
            return String(localized: "Dictate and Send")
        case .mode(let id):
            if let config = ModeManager.shared.getConfiguration(with: id) {
                return String(format: String(localized: "%@ Mode"), config.name)
            }

            if let template = StarterModeCatalog.templates.first(where: { $0.id == id }) {
                return String(format: String(localized: "%@ Mode"), template.name)
            }

            return String(localized: "Mode")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        case .recorderPanelMode(let index):
            return String(format: String(localized: "Select Mode %@"), Self.displayNumber(forRecorderPanelIndex: index))
        }
    }

    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .undoLastPaste,
        .toggleMeetingNotes,
        .toggleLiveTranscript,
        .openHistoryWindow,
        .quickAddToDictionary,
        .captureSystemAudio,
        .recallSystemAudio,
    ]

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openHistoryWindow,
        .quickAddToDictionary,
    ]

    private static func displayNumber(forRecorderPanelIndex index: Int) -> String {
        index == 9 ? "10" : "\(index + 1)"
    }
}

// MARK: - Backups

extension ShortcutAction {
    /// How a backup carries this action's shortcut. The switch has no default, so a new action
    /// does not build until it is given one.
    enum BackupCoverage: Equatable {
        /// A named field of `GeneralBackup`, kept for backups made before `shortcuts`.
        case namedField
        /// `GeneralBackup.shortcuts`, by `storageName`.
        case byName
        /// With its mode, in the Modes category.
        case withItsMode
        /// Nothing to back up: a fixed gesture or a key that only works inside the recorder.
        case notRecordable
    }

    var backupCoverage: BackupCoverage {
        switch self {
        case .primaryRecording, .secondaryRecording, .pasteLastTranscription, .pasteLastEnhancement,
            .retryLastTranscription, .cancelRecorder, .openHistoryWindow, .quickAddToDictionary, .undoLastPaste:
            return .namedField
        case .captureSystemAudio, .recallSystemAudio, .toggleMeetingNotes, .toggleLiveTranscript:
            return .byName
        case .mode:
            return .withItsMode
        case .agentDoubleTap, .dictateAndSend, .recorderPanelEscape, .recorderPanelMode:
            return .notRecordable
        }
    }

    /// The actions `GeneralBackup.shortcuts` carries.
    static let backedUpByName: [ShortcutAction] = [
        .captureSystemAudio, .recallSystemAudio, .toggleMeetingNotes, .toggleLiveTranscript,
    ]
}
