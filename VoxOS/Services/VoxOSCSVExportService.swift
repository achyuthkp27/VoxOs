import AppKit
import Foundation
import SwiftData

class VoxOSCSVExportService {

    func exportTranscriptionsToCSV(transcriptions: [Transcription]) {
        let csvString = generateCSV(for: transcriptions)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "VoxOS-transcription.csv"

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try csvString.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Error writing CSV file: \(error)")
                }
            }
        }
    }

    private func generateCSV(for transcriptions: [Transcription]) -> String {
        var csvString =
            "Original Transcript,Enhanced Transcript,Enhancement Model,Prompt Name,Transcription Model,Mode,Enhancement Time,Transcription Time,Timestamp,Duration\n"

        for transcription in transcriptions {
            let originalText = escapeCSVString(transcription.text)
            let enhancedText = escapeCSVString(transcription.enhancedText ?? "")
            let enhancementModel = escapeCSVString(transcription.aiEnhancementModelName ?? "")
            let promptName = escapeCSVString(transcription.promptName ?? "")
            let transcriptionModel = escapeCSVString(transcription.transcriptionModelName ?? "")
            let mode = escapeCSVString(transcription.modeName ?? "")
            let enhancementTime = transcription.enhancementDuration ?? 0
            let transcriptionTime = transcription.transcriptionDuration ?? 0
            let timestamp = transcription.timestamp.ISO8601Format()
            let duration = transcription.duration

            let row =
                "\(originalText),\(enhancedText),\(enhancementModel),\(promptName),\(transcriptionModel),\(mode),\(enhancementTime),\(transcriptionTime),\(timestamp),\(duration)\n"
            csvString.append(row)
        }

        return csvString
    }

    private static let formulaTriggerCharacters: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    private func escapeCSVString(_ string: String) -> String {
        var escapedString = string.replacingOccurrences(of: "\"", with: "\"\"")

        // Neutralize spreadsheet formula/DDE injection: a cell whose first character is one
        // of these is interpreted as a formula by Excel/Numbers/Sheets when the CSV is opened.
        if let first = escapedString.first, Self.formulaTriggerCharacters.contains(first) {
            escapedString = "'" + escapedString
        }

        if escapedString.contains(",") || escapedString.contains("\n") || escapedString.contains("\"") {
            return "\"\(escapedString)\""
        }
        return escapedString
    }

}
