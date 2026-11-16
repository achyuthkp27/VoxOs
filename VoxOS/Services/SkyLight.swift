import AppKit

/// The call of macOS's private window server framework (SkyLight) VoxOS uses, loaded at run time
/// so a macOS without it simply goes without instead of failing to launch: a window's background
/// blur radius, for Focus Blur's adjustable blur (the public visual effect view has one fixed
/// radius). Private API: any macOS update can change or remove it, so the caller has a fallback.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let setBlurRadius = symbol("SLSSetWindowBackgroundBlurRadius", as: SetBlurRadius.self)

    static var canBlur: Bool { mainConnection != nil && setBlurRadius != nil }

    /// Blurs what is behind `window` by `radius` points. False when this macOS cannot.
    @discardableResult
    static func setBackgroundBlur(_ window: NSWindow, radius: Int) -> Bool {
        guard let mainConnection, let setBlurRadius, window.windowNumber > 0 else { return false }
        return setBlurRadius(mainConnection(), UInt32(window.windowNumber), Int32(radius)) == 0
    }
}
