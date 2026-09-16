import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AudioCleanupManager")

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    private let cleanupCheckInterval: TimeInterval = 86400  // Check once per day (in seconds)

    private init() {}

    /// Start the automatic cleanup schedule.
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.runAutomaticCleanupIfNeeded(modelContext: modelContext)
            }
        }
    }

    /// Run automatic cleanup once if it is due. This is safe to call on app/window appear.
    func runAutomaticCleanupIfNeeded(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
            !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
            shouldRunAutomaticCleanup()
        else {
            return
        }

        await performCleanup(modelContext: modelContext)
        UserDefaults.standard.set(Date(), forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate)
    }

    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (
        fileCount: Int, totalSize: Int64, transcriptions: [Transcription]
    ) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [])
        }

        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate && transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)

                // Calculate stats (can be done on any thread)
                var fileCount = 0
                var totalSize: Int64 = 0
                var eligibleTranscriptions: [Transcription] = []

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                        let url = URL(string: urlString),
                        FileManager.default.fileExists(atPath: url.path)
                    {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                            let fileSize = attributes[.size] as? Int64
                        {
                            totalSize += fileSize
                            fileCount += 1
                            eligibleTranscriptions.append(transcription)
                        }
                    }
                }

                return (fileCount, totalSize, eligibleTranscriptions)
            }
        } catch {
            // Returning empty here shows the user "nothing to clean up", which is
            // indistinguishable from a healthy empty result — so say so in the log.
            logger.error("Could not gather audio cleanup info: \(error, privacy: .public)")
            return (0, 0, [])
        }
    }

    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            // Execute SwiftData operations on the main thread
            try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate && transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)
                var deletedCount = 0

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                        let url = URL(string: urlString),
                        FileManager.default.fileExists(atPath: url.path)
                    {
                        do {
                            try FileManager.default.removeItem(at: url)
                            transcription.audioFileURL = nil
                            deletedCount += 1
                        } catch {
                            // Leave audioFileURL set: the file is still there.
                            logger.error(
                                "Could not delete audio file during automatic cleanup: \(error, privacy: .public)")
                        }
                    }
                }

                if deletedCount > 0 {
                    try modelContext.save()
                }
            }
        } catch {
            // Cleanup is non-critical, so this stays non-fatal — but it ran on a timer with
            // nobody watching, and swallowing it meant a permanently failing cleanup was
            // invisible while the audio directory grew.
            logger.error("Automatic audio cleanup failed: \(error, privacy: .public)")
        }
    }

    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }

    private func shouldRunAutomaticCleanup() -> Bool {
        guard
            let lastCleanupDate = UserDefaults.standard.object(
                forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) as? Date
        else {
            return true
        }

        return Date().timeIntervalSince(lastCleanupDate) >= cleanupCheckInterval
    }

    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) async -> (
        deletedCount: Int, errorCount: Int
    ) {
        // Execute SwiftData operations on the main thread. Nothing in here throws — the
        // previous `try await` wrapped it in a `catch` that returned (0, 0), which would
        // have reported a wholesale failure as "deleted nothing, nothing went wrong".
        return await MainActor.run {
            var deletedCount = 0
            var errorCount = 0

            for transcription in transcriptions {
                if let urlString = transcription.audioFileURL,
                    let url = URL(string: urlString),
                    FileManager.default.fileExists(atPath: url.path)
                {
                    do {
                        try FileManager.default.removeItem(at: url)
                        transcription.audioFileURL = nil
                        deletedCount += 1
                    } catch {
                        logger.error("Could not delete audio file: \(error, privacy: .public)")
                        errorCount += 1
                    }
                }
            }

            if deletedCount > 0 || errorCount > 0 {
                do {
                    try modelContext.save()
                } catch {
                    // The files are already gone from disk, so swallowing this left the
                    // rows still pointing at them and the user told everything was fine.
                    logger.error("Could not save after audio cleanup: \(error, privacy: .public)")
                    errorCount += 1
                }
            }

            return (deletedCount, errorCount)
        }
    }

    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
}
