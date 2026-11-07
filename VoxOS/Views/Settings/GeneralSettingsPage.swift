import SwiftUI

/// The Settings page: general behavior, appearance and language, backup and diagnostics.
struct GeneralSettingsPage: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    // Used only to export and import, so not observed: the page needn't redraw on each track.
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @AppStorage(DefaultsKeys.hasCompletedOnboardingV2) private var hasCompletedOnboardingV2 = false
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private static let sections: [SettingsSection] = [.general, .appearance, .backup, .diagnostics]

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: search.matchesAny(Self.sections)) {
            if search.matches(.general) {
                Section("General") {
                    Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                    Toggle(
                        String(localized: "Launch at Login"),
                        isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { launchAtLoginManager.setEnabled($0) }
                        )
                    )
                    .disabled(launchAtLoginManager.isUpdating)

                    Toggle(
                        "Automatically Check for Updates",
                        isOn: Binding(
                            get: { updaterViewModel.checksForUpdatesWhenDashboardAppears },
                            set: { updaterViewModel.setChecksForUpdatesWhenDashboardAppears($0) }
                        ))

                    HStack {
                        Button("Check for Updates") {
                            updaterViewModel.checkForUpdates()
                        }
                        .disabled(!updaterViewModel.canCheckForUpdates)

                        Button("Reset Onboarding") {
                            showResetOnboardingAlert = true
                        }
                    }
                }
            }

            if search.matches(.appearance) {
                Section {
                    Picker("Appearance", selection: $appAppearancePreference) {
                        ForEach(AppAppearancePreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appAppearancePreference) { _, newValue in
                        newValue.apply()
                    }

                    Picker("Language", selection: $appLanguagePreference) {
                        ForEach(AppLanguagePreference.availableOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appLanguagePreference) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                        if normalizedValue != newValue {
                            appLanguagePreference = normalizedValue
                            return
                        }
                        AppLanguagePreference.apply(rawValue: normalizedValue)
                        showLanguageRestartAlert = true
                    }
                } header: {
                    Text("Appearance")
                }
            }

            if search.matches(.backup) {
                Section {
                    LabeledContent("Export Settings") {
                        Button("Export") {
                            Task {
                                await ImportExportService.shared.exportSettings(
                                    enhancementService: enhancementService,
                                    recordingShortcutManager: recordingShortcutManager,
                                    menuBarManager: menuBarManager,
                                    mediaController: mediaController,
                                    playbackController: playbackController,
                                    recorderUIManager: recorderUIManager,
                                    modelContext: modelContext
                                )
                            }
                        }
                    }

                    LabeledContent("Import Settings") {
                        Button("Import") {
                            ImportExportService.shared.importSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext,
                                transcriptionModelManager: transcriptionModelManager
                            )
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export all settings, or choose specific categories when importing a backup.")
                }
            }

            if search.matches(.diagnostics) {
                Section("Diagnostics") {
                    DiagnosticsSettingsView()
                }
            }
        }
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart VoxOS to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen VoxOS.")
        }
    }
}
