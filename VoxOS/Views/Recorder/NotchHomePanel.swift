import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

final class NotchHomePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false
        // The idle tab's level: under Claude Code's cards and under the recorder.
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }
}

// MARK: - Manager
