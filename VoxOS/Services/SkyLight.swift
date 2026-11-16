import AppKit
import os

/// The few calls of macOS's private window server framework (SkyLight) VoxOS uses, loaded at run
/// time so a macOS without one of them simply goes without that feature instead of failing to
/// launch:
/// - a window's background blur radius, for Focus Blur's adjustable blur (the public visual
///   effect view has one fixed radius);
/// - a Space of its own at the lock screen's level, for the lock screen widgets.
/// Private API: any macOS update can change or remove them, so every caller has a fallback.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SkyLight")

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let setBlurRadius = symbol("SLSSetWindowBackgroundBlurRadius", as: SetBlurRadius.self)
    private static let spaceCreate = symbol("SLSSpaceCreate", as: SpaceCreate.self)
    private static let spaceSetLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self)
    private static let showSpaces = symbol("SLSShowSpaces", as: ShowSpaces.self)
    private static let addWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self)

    static var canBlur: Bool { mainConnection != nil && setBlurRadius != nil }

    /// Blurs what is behind `window` by `radius` points. False when this macOS cannot.
    @discardableResult
    static func setBackgroundBlur(_ window: NSWindow, radius: Int) -> Bool {
        guard let mainConnection, let setBlurRadius, window.windowNumber > 0 else { return false }
        return setBlurRadius(mainConnection(), UInt32(window.windowNumber), Int32(radius)) == 0
    }

    static var canShowOnLockScreen: Bool {
        mainConnection != nil && spaceCreate != nil && spaceSetLevel != nil && showSpaces != nil
            && addWindows != nil
    }

    /// The Space above the lock screen, made once.
    nonisolated(unsafe) private static var lockScreenSpace: UInt64?
    /// The lock screen's own level is 300-ish; a Space at 400 draws above it.
    private static let lockScreenLevel: Int32 = 400

    /// Moves `window` into a Space drawn above the lock screen. False when this macOS cannot.
    @MainActor
    @discardableResult
    static func showOnLockScreen(_ window: NSWindow) -> Bool {
        guard let mainConnection, let spaceCreate, let spaceSetLevel, let showSpaces, let addWindows,
            window.windowNumber > 0
        else { return false }
        let connection = mainConnection()
        let space: UInt64
        if let lockScreenSpace {
            space = lockScreenSpace
        } else {
            space = spaceCreate(connection, 1, nil)
            guard space != 0 else {
                logger.error("Could not make a Space for the lock screen")
                return false
            }
            _ = spaceSetLevel(connection, space, lockScreenLevel)
            _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
            lockScreenSpace = space
        }
        return addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7) == 0
    }
}
