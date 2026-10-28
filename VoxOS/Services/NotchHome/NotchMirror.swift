import AVFoundation
import AppKit
import SwiftUI

/// The camera as a mirror in the open card. It runs only from a click on the Sound page's
/// mirror until that part, the page or the card goes away, so the green light means someone
/// asked for it; nothing is recorded. Camera access is asked for on that first click.
@MainActor
final class NotchMirror: ObservableObject {
    static let shared = NotchMirror()

    enum State: Equatable {
        case off
        case starting
        case on
        case denied
        case noCamera
    }

    @Published private(set) var state: State = .off
    nonisolated let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.mirror")
    private var configured = false

    private init() {}

    func start() {
        guard state == .off || state == .denied || state == .noCamera else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.run() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        guard state == .on || state == .starting else { return }
        state = .off
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        ActivityTrail.mark("notch mirror off")
    }

    private func run() {
        state = .starting
        let session = session
        let needsSetup = !configured
        configured = true
        queue.async { [weak self] in
            if needsSetup {
                session.beginConfiguration()
                session.sessionPreset = .medium
                if let camera = AVCaptureDevice.default(for: .video),
                    let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
                {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            let hasCamera = !session.inputs.isEmpty
            if hasCamera { session.startRunning() }
            Task { @MainActor in
                guard let self, self.state == .starting else {
                    // Stopped while starting: the page went away first.
                    if hasCamera { self?.queue.async { session.stopRunning() } }
                    return
                }
                self.state = hasCamera ? .on : .noCamera
                ActivityTrail.mark("notch mirror on")
            }
        }
    }
}

/// The camera's picture, mirrored like a mirror, filling its frame.
struct NotchMirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // A layer-hosting view: the layer first, then wantsLayer.
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
