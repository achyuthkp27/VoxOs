import SwiftUI

/// The Notch page: its look, Notch Home and its pages, music, the Sound page, notices and
/// Claude Code.
struct NotchSettingsPage: View {
    @AppStorage(DefaultsKeys.notchMasterEnabled) private var notchMaster = true
    @AppStorage(DefaultsKeys.notchMaterial) private var notchMaterialRaw = NotchDesign.Material.liquidGlass.rawValue
    @AppStorage(DefaultsKeys.notchIdleTabEnabled) private var notchIdleTabEnabled = false
    @AppStorage(DefaultsKeys.notchHomeEnabled) private var notchHomeEnabled = true
    @AppStorage(DefaultsKeys.notchDeviceAlertsEnabled) private var notchDeviceAlertsEnabled = true
    @AppStorage(DefaultsKeys.notchHomeInFullScreen) private var notchHomeInFullScreen = false
    @AppStorage(DefaultsKeys.notchPrivacyEnabled) private var notchPrivacyEnabled = true
    @AppStorage(DefaultsKeys.notchFollowsActiveDisplay) private var notchFollowsActiveDisplay = false
    @AppStorage(DefaultsKeys.notchHUDEnabled) private var notchHUDEnabled = true
    @AppStorage(DefaultsKeys.notchHiddenFromCapture) private var notchHiddenFromCapture = false
    @AppStorage(DefaultsKeys.notchDownloadsEnabled) private var notchDownloadsEnabled = true
    @AppStorage(DefaultsKeys.notchFocusEnabled) private var notchFocusEnabled = true
    @AppStorage(DefaultsKeys.notchMixerEnabled) private var notchMixerEnabled = true
    @AppStorage(DefaultsKeys.notchSoundOutputEnabled) private var notchSoundOutputEnabled = true
    @AppStorage(DefaultsKeys.notchSoundInputEnabled) private var notchSoundInputEnabled = true
    @AppStorage(DefaultsKeys.notchMirrorEnabled) private var notchMirrorEnabled = true
    @AppStorage(DefaultsKeys.notchClipboardEnabled) private var notchClipboardEnabled = false
    @AppStorage(DefaultsKeys.notchLyricsEnabled) private var notchLyricsEnabled = false
    @AppStorage(DefaultsKeys.notchRainEnabled) private var notchRainEnabled = true
    @AppStorage(DefaultsKeys.notchUnreadEnabled) private var notchUnreadEnabled = true
    @AppStorage(DefaultsKeys.notchMeetingsEnabled) private var notchMeetingsEnabled = true
    @AppStorage(DefaultsKeys.notchMusicEnabled) private var notchMusicEnabled = true
    @AppStorage(DefaultsKeys.notchMusicBarsEnabled) private var notchMusicBarsEnabled = false
    @AppStorage(DefaultsKeys.notchMusicBarsOnBattery) private var notchMusicBarsOnBattery = true
    /// Notch Home's page order and the pages that are off. Written straight to defaults, so the
    /// next hover walks the new order.
    @State private var notchPageOrder = NotchPageLayout.ordered()
    @State private var notchDisabledPages = NotchPageLayout.disabled()
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    /// Pages, Music, the Sound page and Notices belong to Notch Home and show only while it is on.
    private var layout: SettingsPageLayout {
        SettingsPageLayout(
            sections: [.notchLook, .notchHome, .notchPages, .notchMusic, .notchSound, .notchNotices, .claudeCode],
            dependents: [.notchPages, .notchMusic, .notchSound, .notchNotices], on: .notchHome,
            isOn: notchHomeEnabled)
    }

    private func shows(_ section: SettingsSection) -> Bool { layout.shows(section, for: search) }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: layout.hasMatches(for: search)) {
            if !search.isFiltering {
                Section {
                    Toggle(
                        "Notch", isOn: Binding(get: { notchMaster }, set: { MasterSwitches.setNotchEnabled($0) }))
                } footer: {
                    Text(
                        "Off, nothing shows in the notch between dictations, and Claude Code's requests stay in the terminal."
                    )
                    .settingsCaption()
                }
            }

            if shows(.notchLook) {
                Section {
                    Picker(selection: $notchMaterialRaw) {
                        ForEach(NotchDesign.Material.allCases) { material in
                            Text(material.displayName).tag(material.rawValue)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("Notch Material")
                            InfoTip(
                                "Liquid Glass: the open card, Claude Code's cards and the recorder are glass below the notch, which stays black. Solid Black: one opaque black surface. Collapsed bands are black either way, as they sit beside the hardware notch."
                            )
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle(isOn: $notchIdleTabEnabled) {
                        HStack(spacing: 2) {
                            Text("Always-Visible Notch Tab")
                            InfoTip(
                                "Off by default: the notch appears only on the shortcut. On, a slim tab stays under the notch between dictations; hover to see it, click to start recording. Only on displays with a notch."
                            )
                        }
                    }
                } header: {
                    Text("Look")
                }
            }

            if shows(.notchHome) {
                Section {
                    Toggle(isOn: $notchHomeEnabled) {
                        HStack(spacing: 2) {
                            Text("Notch Home")
                            InfoTip(
                                "Push the pointer to the top of the notch, or drag files toward it, to open Music, Calendar, Reminders, Pomodoro and Shelf. Between hovers it shows one thing at a time: a notice, the next meeting, a microphone or camera in use, a running timer, or the playing track."
                            )
                        }
                    }
                    if notchHomeEnabled {
                        Toggle(isOn: $notchHomeInFullScreen) {
                            HStack(spacing: 2) {
                                Text("Show in Full Screen")
                                InfoTip(
                                    "Off: while a full-screen app is in front (a video, a game), Notch Home and its animations step aside. Claude Code requests still show."
                                )
                            }
                        }
                        Toggle(isOn: $notchFollowsActiveDisplay) {
                            HStack(spacing: 2) {
                                Text("Follow the Display in Use")
                                InfoTip(
                                    "On: Notch Home and Claude Code's cards move to the display with the front window, as a notch drawn from that display's menu bar where it has none. Off: they stay on the display with a notch, or on the main display when no display has one."
                                )
                            }
                        }
                        Toggle(isOn: $notchHiddenFromCapture) {
                            HStack(spacing: 2) {
                                Text("Hide from Screenshots & Sharing")
                                InfoTip(
                                    "On: the notch's cards and bands are left out of screenshots, screen recordings and screen sharing, so a call never shows a Claude Code request or what is playing. Off by default, so a screenshot of the notch still shows it."
                                )
                            }
                        }
                    }
                } header: {
                    Text("Notch Home")
                }
            }

            if shows(.notchPages) {
                Section {
                    ForEach(notchPageOrder) { page in
                        notchPageRow(page)
                    }
                } header: {
                    Text("Pages")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            "Drag a page, or use the arrows, to reorder. At least one page stays on; Music only shows while a track is playing."
                        )
                        .settingsCaption()
                        Spacer(minLength: 8)
                        Button("Reset") { resetNotchPages() }
                    }
                }
            }

            if shows(.notchMusic) {
                Section {
                    Toggle("Music in the Notch", isOn: $notchMusicEnabled)
                    if notchMusicEnabled {
                        Toggle(isOn: $notchLyricsEnabled) {
                            HStack(spacing: 2) {
                                Text("Lyrics")
                                InfoTip(
                                    "The line being sung, under the artist on the Music page, from lrclib.net. Looking a song up sends its title and artist there, once per song, only while the Music page is open."
                                )
                            }
                        }
                        Toggle(isOn: $notchMusicBarsEnabled) {
                            HStack(spacing: 2) {
                                Text("Live Music Bars")
                                InfoTip(
                                    "Bars beside the notch and in the player that move with what is actually playing. They listen to the Mac's sound output while music plays, which needs the System Audio Recording permission and shows macOS's purple recording dot meanwhile. Off, the bars still move but listen to nothing. Nothing is recorded or stored. A click on the bars in the player switches this too."
                                )
                            }
                        }
                        if notchMusicBarsEnabled {
                            Toggle(isOn: $notchMusicBarsOnBattery) {
                                HStack(spacing: 2) {
                                    Text("Live Bars on Battery")
                                    InfoTip(
                                        "Off, the bars stay ambient while the Mac runs on battery and listen to nothing. In Low Power Mode they always do."
                                    )
                                }
                            }
                        }
                    }
                } header: {
                    Text("Music")
                }
            }

            if shows(.notchSound) {
                Section {
                    Toggle(isOn: $notchMixerEnabled) {
                        HStack(spacing: 2) {
                            Text("Per-App Volume")
                            InfoTip(
                                "On the Sound page: each playing app with its own volume. An app turned down is played on through a system audio tap, which needs System Audio Recording and shows macOS's purple dot until every app is back at full."
                            )
                        }
                    }
                    Toggle(isOn: $notchSoundOutputEnabled) {
                        HStack(spacing: 2) {
                            Text("Sound Output")
                            InfoTip(
                                "On the Sound page: switch the Mac's sound output between speakers, headphones and other devices."
                            )
                        }
                    }
                    Toggle(isOn: $notchSoundInputEnabled) {
                        HStack(spacing: 2) {
                            Text("Microphone Input")
                            InfoTip(
                                "On the Sound page: switch the active microphone between built-in, AirPods and external microphones."
                            )
                        }
                    }
                    Toggle(isOn: $notchClipboardEnabled) {
                        HStack(spacing: 2) {
                            Text("Clipboard History")
                            InfoTip(
                                "On the Sound page: the last few pieces of text you copied; a click copies one again. Kept in memory only, never what a password manager marks as secret. Off by default: it checks the clipboard once a second."
                            )
                        }
                    }
                    Toggle(isOn: $notchMirrorEnabled) {
                        HStack(spacing: 2) {
                            Text("Mirror")
                            InfoTip(
                                "On the Sound page: your camera as a mirror, only after a click and only while it is open."
                            )
                        }
                    }
                } header: {
                    Text("Sound Page")
                } footer: {
                    Text(
                        "What the notch’s Sound page shows."
                    )
                    .settingsCaption()
                }
            }

            if shows(.notchNotices) {
                Section {
                    Toggle(isOn: $notchHUDEnabled) {
                        HStack(spacing: 2) {
                            Text("Volume & Brightness in the Notch")
                            InfoTip(
                                "The volume and brightness keys show their level in the notch instead of macOS's pop-up, in the same steps (Option-Shift for finer ones). Needs Accessibility, which VoxOS already uses for its shortcuts. An external display's brightness, an output without a volume, and keys pressed while the notch is hidden stay with macOS."
                            )
                        }
                    }
                    Toggle(isOn: $notchPrivacyEnabled) {
                        HStack(spacing: 2) {
                            Text("Mic & Camera in Use")
                            InfoTip(
                                "While another app uses the microphone or a camera, the notch shows it, with the app's icon. A click on the microphone mutes it; the mute is undone when the call ends."
                            )
                        }
                    }
                    Toggle(isOn: $notchMeetingsEnabled) {
                        HStack(spacing: 2) {
                            Text("Meeting Countdown")
                            InfoTip(
                                "Five minutes before a meeting in your calendar, the notch counts down to it, with Join when the event has a video-call link. Needs Calendar access, which the Calendar page asks for."
                            )
                        }
                    }
                    Toggle(isOn: $notchDeviceAlertsEnabled) {
                        HStack(spacing: 2) {
                            Text("Device Alerts")
                            InfoTip(
                                "A short notice when AirPods or another Bluetooth device connects (with its battery), when the sound moves to another output, when Wi-Fi joins or drops, and when the power adapter goes in or out or the battery runs low."
                            )
                        }
                    }
                    Toggle(isOn: $notchDownloadsEnabled) {
                        HStack(spacing: 2) {
                            Text("Downloads")
                            InfoTip(
                                "A band with how far a download in the Downloads folder has got, and a notice when it is done."
                            )
                        }
                    }
                    Toggle(isOn: $notchFocusEnabled) {
                        HStack(spacing: 2) {
                            Text("Focus")
                            InfoTip("A notice with the Focus's own name and symbol when one turns on or off.")
                        }
                    }
                    Toggle(isOn: $notchUnreadEnabled) {
                        HStack(spacing: 2) {
                            Text("Unread Counts")
                            InfoTip(
                                "A notice when Mail, Messages or another app's unread badge in the Dock goes up, read from the Dock once a minute."
                            )
                        }
                    }
                    Toggle(isOn: $notchRainEnabled) {
                        HStack(spacing: 2) {
                            Text("Rain Soon")
                            InfoTip(
                                "A notice when rain is about to start where you are, from the weather checked every half hour. Only once location access has been given on the Weather page."
                            )
                        }
                    }
                } header: {
                    Text("Notices")
                } footer: {
                    Text(
                        "Short notices the notch shows between hovers."
                    )
                    .settingsCaption()
                }
            }

            if shows(.claudeCode) {
                ClaudeCodeSection()
            }
        }
    }

    // MARK: - Notch pages

    /// One page in the list: a drag handle, the switch, and arrows for a trackpad or a keyboard.
    private func notchPageRow(_ page: NotchHomePage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("Drag to reorder")
                .draggable(page.rawValue)
            Toggle(isOn: notchPageEnabled(page)) {
                Label {
                    Text(page.title)
                } icon: {
                    Image(systemName: page.symbol)
                }
            }
            .disabled(isOnlyEnabledNotchPage(page))
            Spacer(minLength: 8)
            Button {
                moveNotchPage(page, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(notchPageOrder.first == page)
            .help("Move up")
            Button {
                moveNotchPage(page, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(notchPageOrder.last == page)
            .help("Move down")
        }
        .dropDestination(for: String.self) { values, _ in
            guard let rawValue = values.first, let dragged = NotchHomePage(rawValue: rawValue) else { return false }
            moveNotchPage(dragged, onto: page)
            return true
        }
    }

    private func notchPageEnabled(_ page: NotchHomePage) -> Binding<Bool> {
        Binding(
            get: { !notchDisabledPages.contains(page) },
            set: { enabled in
                if enabled {
                    notchDisabledPages.remove(page)
                } else {
                    // The notch needs one page to open on, so the last one on cannot go off.
                    guard !isOnlyEnabledNotchPage(page) else { return }
                    notchDisabledPages.insert(page)
                }
                NotchPageLayout.save(order: notchPageOrder, disabled: notchDisabledPages)
            }
        )
    }

    private func isOnlyEnabledNotchPage(_ page: NotchHomePage) -> Bool {
        !notchDisabledPages.contains(page)
            && notchPageOrder.allSatisfy { $0 == page || notchDisabledPages.contains($0) }
    }

    private func moveNotchPage(_ page: NotchHomePage, by offset: Int) {
        setNotchPageOrder(NotchPageLayout.moving(page, by: offset, in: notchPageOrder))
    }

    private func moveNotchPage(_ dragged: NotchHomePage, onto target: NotchHomePage) {
        setNotchPageOrder(NotchPageLayout.moving(dragged, onto: target, in: notchPageOrder))
    }

    private func setNotchPageOrder(_ order: [NotchHomePage]) {
        guard order != notchPageOrder else { return }
        notchPageOrder = order
        NotchPageLayout.save(order: order, disabled: notchDisabledPages)
    }

    private func resetNotchPages() {
        NotchPageLayout.reset()
        notchPageOrder = NotchPageLayout.ordered()
        notchDisabledPages = NotchPageLayout.disabled()
    }
}
