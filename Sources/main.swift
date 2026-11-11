// Pin on Top: keeps chosen windows floating above everything else.
//
// macOS doesn't let one app change another app's window level, so a pinned
// window is shown as a live ScreenCaptureKit mirror in a floating panel that
// sits exactly over the real window. While you're working in the real window
// the mirror hides; when you switch to anything else it reappears on top.
// Clicking the mirror takes you back to the real window.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
@preconcurrency import IOSurface
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Window lookup (CoreGraphics)

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let layer: Int

    var label: String {
        Rules.menuTitle(title.isEmpty ? appName : "\(appName) – \(title)")
    }
}

// In an extension so the struct keeps its memberwise init, which the tests use.
extension WindowInfo {
    init?(_ dict: [String: Any]) {
        guard let number = dict[kCGWindowNumber as String] as? Int,
              let pid = dict[kCGWindowOwnerPID as String] as? Int,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        self.id = CGWindowID(number)
        self.pid = pid_t(pid)
        self.appName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"
        self.title = dict[kCGWindowName as String] as? String ?? ""
        self.bounds = bounds
        self.layer = dict[kCGWindowLayer as String] as? Int ?? 0
    }
}

enum Windows {
    static func list(_ options: CGWindowListOption, relativeTo id: CGWindowID = kCGNullWindowID) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] else { return [] }
        return raw.compactMap(WindowInfo.init)
    }

    static func info(_ id: CGWindowID) -> WindowInfo? {
        list(.optionIncludingWindow, relativeTo: id).first
    }

    /// Normal app windows currently on screen, front to back.
    static func pinnable() -> [WindowInfo] {
        Rules.pinnable(list([.optionOnScreenOnly, .excludeDesktopElements]), excluding: ProcessInfo.processInfo.processIdentifier)
    }
}

func appKitFrame(fromCG rect: CGRect) -> NSRect {
    // The first screen is the one with the menu bar, where CoreGraphics puts its origin.
    Rules.appKitFrame(fromCG: rect, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
}

// MARK: - Rules

/// The app's decisions, as pure functions. The AppKit, Accessibility and ScreenCaptureKit code
/// gathers the inputs and calls these, so the tests can run them without a display or permissions.
enum Rules {
    /// Normal app windows: layer 0, not ours, and at least 80x60 points. Keeps the order given.
    static func pinnable(_ windows: [WindowInfo], excluding me: pid_t) -> [WindowInfo] {
        windows.filter { $0.layer == 0 && $0.pid != me && $0.bounds.width >= 80 && $0.bounds.height >= 60 }
    }

    /// CoreGraphics uses a top-left origin on the primary display; AppKit uses bottom-left.
    static func appKitFrame(fromCG rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pixel size to capture a window at. ScreenCaptureKit refuses 0, so it's at least 1x1.
    static func captureSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((points.width * scale).rounded())), max(1, Int((points.height * scale).rounded())))
    }

    /// Whether a pinned window's mirror shows: once it has a frame, while the window is neither
    /// focused nor hidden. The values that cost an Accessibility call are only read when needed.
    static func mirrorShows(
        hasFrame: Bool, windowID: CGWindowID, pid: pid_t, frontmostPID: pid_t?, accessibility: Bool,
        focusedWindowID: @autoclosure () -> CGWindowID?, appHidden: @autoclosure () -> Bool,
        minimised: @autoclosure () -> Bool
    ) -> Bool {
        guard hasFrame else { return false }
        // Without Accessibility we can't tell which of the app's windows is focused, so assume ours.
        let focused = frontmostPID == pid && (!accessibility || (focusedWindowID().map { $0 == windowID } ?? true))
        if focused || appHidden() { return false }
        return !(accessibility && minimised())
    }

    /// The window the shortcut pins or unpins: the focused one, else the frontmost, else none.
    static func hotKeyTarget(_ candidates: [WindowInfo], focusedID: CGWindowID?) -> WindowInfo? {
        candidates.first { $0.id == focusedID } ?? candidates.first
    }

    /// The opacity choices in a pinned window's right-click menu, in percent.
    static let opacitySteps = [100, 85, 70, 50, 30]

    /// The opacity step an alpha value matches, in percent.
    static func opacityStep(for alpha: CGFloat) -> Int {
        Int((alpha * 100).rounded())
    }

    // MARK: Always Pin

    /// The remembered apps as stored. Bad or missing data means none, and a bundle ID that's
    /// stored twice keeps its first record.
    static func alwaysPinRules(from data: Data?) -> [AlwaysPinRule] {
        guard let data, let rules = try? JSONDecoder().decode([AlwaysPinRule].self, from: data) else { return [] }
        var seen = Set<String>()
        return rules.filter { seen.insert($0.bundleID).inserted }
    }

    /// The remembered apps, ready to store.
    static func alwaysPinData(_ rules: [AlwaysPinRule]) -> Data? {
        try? JSONEncoder().encode(rules)
    }

    /// Remembers an app. If it's already remembered, its record is replaced where it is.
    static func adding(_ rule: AlwaysPinRule, to rules: [AlwaysPinRule]) -> [AlwaysPinRule] {
        guard rules.contains(where: { $0.bundleID == rule.bundleID }) else { return rules + [rule] }
        return rules.map { $0.bundleID == rule.bundleID ? rule : $0 }
    }

    static func removing(bundleID: String, from rules: [AlwaysPinRule]) -> [AlwaysPinRule] {
        rules.filter { $0.bundleID != bundleID }
    }

    /// Remembers the title of the window just pinned for an app. Other apps are left alone.
    static func updatingTitle(_ title: String, bundleID: String, in rules: [AlwaysPinRule]) -> [AlwaysPinRule] {
        rules.map { $0.bundleID == bundleID ? AlwaysPinRule(bundleID: bundleID, appName: $0.appName, windowTitle: title) : $0 }
    }

    /// The window to pin for a remembered app: the one with the remembered title, else the frontmost.
    /// `candidates` are the app's pinnable windows, front to back. Nothing while the app has a pinned
    /// window (it may be minimised or on another Space, so it's not always a candidate) or is
    /// suppressed. Windows that failed to pin recently are skipped.
    static func autoPinTarget(
        for rule: AlwaysPinRule, candidates: [WindowInfo], appHasPin: Bool, suppressed: Bool,
        recentlyFailed: Set<CGWindowID>
    ) -> WindowInfo? {
        guard !appHasPin, !suppressed else { return nil }
        let available = candidates.filter { !recentlyFailed.contains($0.id) }
        // An empty title would match any untitled window, so only a real title counts.
        return available.first { !rule.windowTitle.isEmpty && $0.title == rule.windowTitle } ?? available.first
    }

    /// How long a window that failed to pin automatically is left alone, in seconds.
    static let autoPinRetryDelay: TimeInterval = 5

    /// The failed automatic pins still too recent to retry, by window ID.
    static func recentFailures(_ failures: [CGWindowID: Date], now: Date) -> [CGWindowID: Date] {
        failures.filter { now.timeIntervalSince($0.value) < autoPinRetryDelay }
    }

    /// The processes Always Pin leaves alone after a change. Unpinning a remembered app's window by
    /// hand leaves that app alone until it quits, one of its windows is pinned by hand, or Always Pin
    /// is turned off or on for it.
    static func suppressed(_ pids: Set<pid_t>, after change: SuppressionChange) -> Set<pid_t> {
        switch change {
        case let .unpinnedByHand(pid, remembered):
            return remembered ? pids.union([pid]) : pids
        case let .pinnedByHand(pid), let .alwaysPinSwitched(pid), let .appQuit(pid):
            return pids.subtracting([pid])
        }
    }

    // MARK: Menu

    /// A title as the menus show it: over 70 characters, it's cut to 69 and an ellipsis, between
    /// whole characters.
    static func menuTitle(_ text: String) -> String {
        text.count > 70 ? "\(text.prefix(69))…" : text
    }

    /// A shortcut the way macOS menus write it, such as ⌃⌥⌘P or ⌥F5.
    static func shortcutText(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        let glyphs: [(flag: NSEvent.ModifierFlags, glyph: String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return glyphs.filter { modifiers.contains($0.flag) }.map(\.glyph).joined() + displayed(key)
    }

    /// A key as menus write it: one character upper cased, as long as it stays one character (ß
    /// doesn't become SS), and a name such as Space or F5 as it is.
    private static func displayed(_ key: String) -> String {
        let upper = key.uppercased()
        return key.count == 1 && upper.count == 1 ? upper : key
    }

    // MARK: Shortcut

    /// The modifier keys a shortcut can use, as menus and Carbon's hot keys each write them.
    private static let shortcutModifiers: [(flag: NSEvent.ModifierFlags, carbon: UInt32)] = [
        (.control, UInt32(controlKey)), (.option, UInt32(optionKey)), (.shift, UInt32(shiftKey)), (.command, UInt32(cmdKey)),
    ]

    /// A key press's modifiers in Carbon's mask, which RegisterEventHotKey takes. Caps Lock, Fn and
    /// the like are left out.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        shortcutModifiers.filter { flags.contains($0.flag) }.reduce(0) { $0 | $1.carbon }
    }

    /// Carbon's mask as the modifier flags a menu item takes. Bits for other keys are left out.
    static func modifierFlags(carbon: UInt32) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(shortcutModifiers.filter { carbon & $0.carbon != 0 }.map(\.flag))
    }

    /// The keys menus show by name or symbol rather than by what they type, by virtual key code,
    /// with the character a menu item's key equivalent uses for each.
    private static let namedKeys: [Int: (name: String, equivalent: Int)] = {
        let named: [Int: (name: String, equivalent: Int)] = [
            kVK_Space: ("Space", 0x20), kVK_Return: ("↩", NSCarriageReturnCharacter), kVK_Tab: ("⇥", NSTabCharacter),
            kVK_Delete: ("⌫", NSBackspaceCharacter), kVK_ForwardDelete: ("⌦", NSDeleteFunctionKey),
            kVK_LeftArrow: ("←", NSLeftArrowFunctionKey), kVK_RightArrow: ("→", NSRightArrowFunctionKey),
            kVK_UpArrow: ("↑", NSUpArrowFunctionKey), kVK_DownArrow: ("↓", NSDownArrowFunctionKey),
            kVK_Home: ("↖", NSHomeFunctionKey), kVK_End: ("↘", NSEndFunctionKey),
            kVK_PageUp: ("⇞", NSPageUpFunctionKey), kVK_PageDown: ("⇟", NSPageDownFunctionKey),
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        // NSEvent's F-key characters run in order from F1.
        return functionKeys.enumerated().reduce(into: named) { keys, fKey in
            keys[fKey.element] = ("F\(fKey.offset + 1)", NSF1FunctionKey + fKey.offset)
        }
    }()

    /// Keys that can't be in a shortcut: Escape cancels recording one, and the rest type nothing.
    private static let unusableKeys: Set<Int> = [
        kVK_Escape, kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function, kVK_Help, kVK_ANSI_KeypadClear,
        kVK_VolumeUp, kVK_VolumeDown, kVK_Mute, kVK_JIS_Eisu, kVK_JIS_Kana,
    ]

    /// A key's name as menus show it: Space, ↩, F5 and the like by name, and any other key by the
    /// character it types with no modifiers (`characters`), letters upper cased. Nil for a key that
    /// can't be named, such as Escape or a volume key.
    static func keyName(keyCode: UInt32, characters: String?) -> String? {
        let code = Int(keyCode)
        if let named = namedKeys[code] { return named.name }
        guard code < 128, !unusableKeys.contains(code), let characters, characters.count == 1,
              let character = characters.first, isPrintable(character)
        else { return nil }
        return displayed(characters)
    }

    /// Whether a character can be shown: not a space, a control character or one of NSEvent's
    /// private characters for keys such as Help.
    private static func isPrintable(_ character: Character) -> Bool {
        let hidden: [Unicode.GeneralCategory] = [.control, .format, .privateUse, .surrogate, .unassigned]
        return !character.isWhitespace && character.unicodeScalars.allSatisfy { !hidden.contains($0.properties.generalCategory) }
    }

    /// The key equivalent a menu item shows for a shortcut's key: the character it types, lower
    /// cased (upper case would add Shift), or NSEvent's character for a named key such as F5 or
    /// an arrow. Nil for a key a menu can't show, so the item shows none.
    static func menuKeyEquivalent(keyCode: UInt32, key: String) -> String? {
        if let named = namedKeys[Int(keyCode)] {
            return Unicode.Scalar(UInt32(named.equivalent)).map { String(Character($0)) }
        }
        return key.count == 1 ? key.lowercased() : nil
    }

    /// The shortcut a key press makes, or why it can't be one. It needs a key with a name and at
    /// least one of ⌘, ⌃ or ⌥, or pressing it in any app would pin a window; Shift alone isn't
    /// enough. `characters` are what the key types with no modifiers.
    static func shortcut(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, characters: String?) -> Result<Shortcut, ShortcutProblem> {
        guard let key = keyName(keyCode: keyCode, characters: characters) else { return .failure(.unnamedKey) }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: carbonModifiers(modifiers), key: key)
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .failure(.needsModifier(shortcut.text))
        }
        return .success(shortcut)
    }

    /// The shortcut as stored. Missing, unreadable or invalid data (no ⌘, ⌃ or ⌥, a key it can't
    /// name, or values it doesn't know) means the default, ⌃⌥⌘P.
    static func shortcut(from data: Data?) -> Shortcut {
        // Making it again from its parts catches every invalid value: modifier bits for other keys
        // don't survive the trip, and nor does a key that isn't its key code's name.
        guard let data, let stored = try? JSONDecoder().decode(Shortcut.self, from: data),
              case let .success(remade) = shortcut(
                  keyCode: stored.keyCode, modifiers: modifierFlags(carbon: stored.modifiers), characters: stored.key),
              remade == stored
        else { return HotKey.standard }
        return stored
    }

    /// The shortcut, ready to store as small JSON. Nil for the default, which is stored as nothing,
    /// so a reset leaves no key behind.
    static func shortcutData(_ shortcut: Shortcut) -> Data? {
        shortcut == HotKey.standard ? nil : try? JSONEncoder().encode(shortcut)
    }

    // MARK: Fades

    /// How a mirror changes on a refresh: it fades only when it starts or stops showing, never
    /// on a tick where it stays as it is.
    static func mirrorFade(isShown: Bool, shouldShow: Bool) -> MirrorFade? {
        guard isShown != shouldShow else { return nil }
        return shouldShow ? .fadeIn : .fadeOut
    }

    // MARK: Welcome

    /// The welcome window opens at launch the first time, and again while a permission is missing.
    static func showsWelcome(hasSeenWelcome: Bool, screenRecording: Bool, accessibility: Bool) -> Bool {
        !hasSeenWelcome || !screenRecording || !accessibility
    }

    /// Screen Recording only works after the app reopens, so once it's granted after launch the
    /// welcome window offers to quit and reopen.
    static func needsRelaunch(screenRecordingAtLaunch: Bool, screenRecordingNow: Bool) -> Bool {
        !screenRecordingAtLaunch && screenRecordingNow
    }
}

/// A remembered app, as stored: Always Pin keeps one of its windows pinned. It's found again by
/// bundle ID, with its name for the menu and the title of the window pinned last.
struct AlwaysPinRule: Codable, Equatable, Sendable {
    let bundleID: String
    let appName: String
    let windowTitle: String
}

/// A shortcut, as registered with macOS and stored: the key's virtual key code, the modifiers in
/// Carbon's mask, and the key's name as menus show it. The name is kept because it depends on the
/// keyboard layout, so it can't be worked out from the key code later.
struct Shortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    /// The modifiers as a menu item takes them.
    var modifierFlags: NSEvent.ModifierFlags { Rules.modifierFlags(carbon: modifiers) }

    /// As menus write it, such as ⌃⌥⌘P.
    var text: String { Rules.shortcutText(modifiers: modifierFlags, key: key) }
}

/// Why a shortcut can't be used. The Change Shortcut window says so, and the old one stays.
enum ShortcutProblem: Error, Equatable, Sendable {
    /// A key with no name to show, such as a volume key.
    case unnamedKey
    /// No ⌘, ⌃ or ⌥. Holds the shortcut as menus write it.
    case needsModifier(String)
    /// macOS wouldn't register it. Holds the shortcut as menus write it.
    case inUse(String)

    var message: String {
        switch self {
        case .unnamedKey:
            "That key can't be part of a shortcut. Try a letter, a digit or an F-key."
        case let .needsModifier(text):
            "A shortcut needs ⌘, ⌃ or ⌥ (Shift alone isn't enough), or pressing \(text) in any app would pin a window."
        case let .inUse(text):
            "Another app may already be using \(text). Try a different shortcut."
        }
    }
}

/// What changes the processes Always Pin leaves alone.
enum SuppressionChange: Equatable, Sendable {
    case unpinnedByHand(pid_t, remembered: Bool)
    case pinnedByHand(pid_t)
    case alwaysPinSwitched(pid_t)
    case appQuit(pid_t)
}

/// A mirror starting or stopping showing.
enum MirrorFade: Equatable, Sendable {
    case fadeIn, fadeOut

    /// In seconds. Fading out is quicker, so the real window isn't kept waiting.
    var duration: TimeInterval { self == .fadeIn ? 0.15 : 0.1 }
}

/// What the menus call a pinned window's options, and the menu bar menu's headers for pinned
/// windows and Always Pin. The welcome tips and the pin badge's tooltip name them too, so they
/// can't drift.
enum MenuWords {
    static let pinned = "Pinned"
    static let opacity = "Opacity"
    static let alwaysPin = "Always Pin"
    static let unpin = "Unpin"

    /// The pin badge's tooltip.
    static let badgeToolTip = "Pinned: click to switch to this window, right-click for \(opacity), \(alwaysPin) and \(unpin)"
}

// MARK: - Accessibility helpers

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func app(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first { windowID(of: $0) == id }
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: the type ID check above guarantees this is an AXUIElement.
        return windowID(of: unsafeBitCast(value, to: AXUIElement.self))
    }

    static func isMinimised(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func bringToFront(pid: pid_t, window: AXUIElement?) {
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let window else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

// MARK: - Overlay

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayView: NSView {
    weak var pin: Pin?
    let contentLayer = CALayer()
    private let badge = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        contentLayer.frame = bounds
        contentLayer.contentsGravity = .resize
        contentLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(contentLayer)

        badge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        badge.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 11
        badge.frame = NSRect(x: bounds.maxX - 34, y: bounds.maxY - 34, width: 22, height: 22)
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        badge.isHidden = true
        badge.toolTip = MenuWords.badgeToolTip
        addSubview(badge)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { badge.isHidden = false }
    override func mouseExited(with event: NSEvent) { badge.isHidden = true }
    override func mouseDown(with event: NSEvent) { pin?.goToWindow() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pin?.contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - Pin

enum PinError: LocalizedError {
    case windowNotFound
    var errorDescription: String? { "That window couldn't be found. It may have closed." }
}

@MainActor
final class Pin: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let pid: pid_t
    /// Nil for apps without one, which Always Pin can't remember.
    let bundleID: String?
    let appName: String
    private(set) var label: String
    private(set) var title: String
    /// Called when the pin should go. `byHand` is true when it was unpinned from its menu (by
    /// right-clicking, or under Pinned in the menu bar menu), and false when the window closed or
    /// capture stopped.
    var onEnded: ((Pin, _ byHand: Bool) -> Void)?
    /// Always Pin for this window's app: whether it's on, and switching it.
    var isAlwaysPinned: ((Pin) -> Bool)?
    var onToggleAlwaysPin: ((Pin) -> Void)?

    private let panel: OverlayPanel
    private let view: OverlayView
    private var stream: SCStream?
    private var streamSize = CGSize.zero
    private var pointPixelScale: CGFloat = 2
    private var axWindow: AXUIElement?
    private var hasFrame = false
    /// Whether the mirror is meant to show. The panel stays on screen while it fades out.
    private var isShown = false
    /// The opacity chosen from the right-click menu, which a fade-in ends at. It's kept here
    /// because the panel's own alpha is part way through a fade at times.
    private var opacity: CGFloat = 1
    /// Counts fades, so a fade that was replaced doesn't finish the one that replaced it.
    private var fades = 0
    private let frameQueue = DispatchQueue(label: "pin-on-top.frames", qos: .userInteractive)

    init(window: WindowInfo) {
        windowID = window.id
        pid = window.pid
        let app = NSRunningApplication(processIdentifier: window.pid)
        bundleID = app?.bundleIdentifier
        appName = app?.localizedName ?? window.appName
        label = window.label
        title = window.title

        let frame = appKitFrame(fromCG: window.bounds)
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = view
        view.pin = self
    }

    func start(completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let scWindow = content?.windows.first(where: { $0.windowID == self.windowID }) else {
                        completion(error ?? PinError.windowNotFound)
                        return
                    }
                    self.startStream(for: scWindow, completion: completion)
                }
            }
        }
    }

    private func startStream(for scWindow: SCWindow, completion: @escaping (Error?) -> Void) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        pointPixelScale = CGFloat(filter.pointPixelScale)
        streamSize = scWindow.frame.size
        let stream = SCStream(filter: filter, configuration: configuration(for: streamSize), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            completion(error)
            return
        }
        self.stream = stream
        stream.startCapture { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil { self.refresh() }
                    completion(error)
                }
            }
        }
    }

    private func configuration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let pixels = Rules.captureSize(points: size, scale: pointPixelScale)
        config.width = pixels.width
        config.height = pixels.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        return config
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// Called often: keeps the mirror over the real window and decides whether it should show.
    func refresh() {
        guard let info = Windows.info(windowID) else {
            onEnded?(self, false)
            return
        }
        label = info.label
        title = info.title

        let frame = appKitFrame(fromCG: info.bounds)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if info.bounds.size != streamSize, let stream {
            streamSize = info.bounds.size
            stream.updateConfiguration(configuration(for: streamSize), completionHandler: nil)
        }

        let shouldShow = Rules.mirrorShows(
            hasFrame: hasFrame, windowID: windowID, pid: pid,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            accessibility: AX.trusted,
            focusedWindowID: AX.focusedWindowID(pid: pid),
            appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden == true,
            minimised: resolvedAXWindow().map(AX.isMinimised) ?? false)
        if let fade = Rules.mirrorFade(isShown: isShown, shouldShow: shouldShow) { apply(fade) }
    }

    private func apply(_ fade: MirrorFade) {
        isShown = fade == .fadeIn
        if isShown && !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        animateAlpha(to: isShown ? opacity : 0, over: fade.duration)
    }

    /// Fades the mirror to an alpha, replacing a fade still running. Once the newest fade ends with
    /// the mirror hidden, it comes off the screen.
    private func animateAlpha(to alpha: CGFloat, over duration: TimeInterval) {
        fades += 1
        let fade = fades
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, fade == self.fades, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Hides the mirror straight away, so a fade doesn't leave a ghost over the real window.
    private func hideNow() {
        isShown = false
        animateAlpha(to: 0, over: 0)
        panel.orderOut(nil)
    }

    private func resolvedAXWindow() -> AXUIElement? {
        if let axWindow, AX.windowID(of: axWindow) == windowID { return axWindow }
        axWindow = AX.window(pid: pid, id: windowID)
        return axWindow
    }

    @objc func goToWindow() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        AX.bringToFront(pid: pid, window: AX.trusted ? resolvedAXWindow() : nil)
        hideNow()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        opacity = CGFloat(sender.tag) / 100
        if isShown { animateAlpha(to: opacity, over: MirrorFade.fadeIn.duration) }
    }

    @objc private func unpin() { onEnded?(self, true) }

    @objc private func toggleAlwaysPin() { onToggleAlwaysPin?(self) }

    /// The window's options. Right-clicking it and its item under Pinned in the menu bar menu both
    /// open this menu, so the two can't drift. Its items target the pin, so it works from either.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let go = menu.addItem(withTitle: "Go to Window", action: #selector(goToWindow), keyEquivalent: "")
        go.target = self

        let opacityItem = menu.addItem(withTitle: MenuWords.opacity, action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let current = Rules.opacityStep(for: opacity)
        for percent in Rules.opacitySteps {
            let item = opacityMenu.addItem(withTitle: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = current == percent ? .on : .off
        }
        opacityItem.submenu = opacityMenu

        // Without a bundle ID the app can't be found again after it restarts, so the item stays
        // disabled (it has no action).
        let always = menu.addItem(withTitle: "\(MenuWords.alwaysPin) “\(Rules.menuTitle(appName))”", action: nil, keyEquivalent: "")
        if bundleID == nil {
            always.toolTip = "This app has no bundle identifier, so Pin on Top can't remember it."
        } else {
            always.action = #selector(toggleAlwaysPin)
            always.target = self
            always.state = isAlwaysPinned?(self) == true ? .on : .off
        }

        menu.addItem(.separator())
        let unpinItem = menu.addItem(withTitle: MenuWords.unpin, action: #selector(unpin), keyEquivalent: "")
        unpinItem.target = self
        return menu
    }

    // MARK: SCStreamOutput / SCStreamDelegate (called off the main thread)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.view.contentLayer.contents = surface
                CATransaction.commit()
                if !self.hasFrame {
                    self.hasFrame = true
                    self.refresh()
                    self.panel.invalidateShadow()
                }
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onEnded?(self, false) }
        }
    }
}

// MARK: - Global hot key

/// The shortcut's fixed parts. The one in use can be changed: the app keeps it, and the hot key,
/// the menu item, the welcome tips and the Change Shortcut window all read that one, so they
/// can't drift.
enum HotKey {
    /// ⌃⌥⌘P: the shortcut until it's changed, and again after a reset.
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey), key: "P")
    static let signature = OSType(0x5049_4E54) // "PINT"
}

@MainActor var hotKeyHandler: (() -> Void)?

/// Passes the hot key's presses to `hotKeyHandler`. Installed once, at launch: changing the
/// shortcut registers a different hot key with the same handler.
func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { hotKeyHandler?() } }
        return noErr
    }, 1, &spec, nil, nil)
}

/// Registers a shortcut with macOS as the hot key. Nil when macOS won't, for example because
/// another app already has it.
func registerHotKey(_ shortcut: Shortcut) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: HotKey.signature, id: 1)
    let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    return status == noErr ? ref : nil
}

// MARK: - Welcome window

/// What the app does, in one line. The welcome window and the About panel both read it, so they
/// can't drift.
enum Tagline {
    static let text = "Keeps any window floating above everything else."
}

/// The two permissions the app asks for.
enum Permission: CaseIterable {
    case screenRecording, accessibility

    var name: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    /// Why it's needed, in a few words.
    var reason: String {
        switch self {
        case .screenRecording: "Shows the live mirror of each pinned window."
        case .accessibility: "Finds the focused window and brings it forward."
        }
    }

    /// Its pane in System Settings > Privacy & Security.
    var pane: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AX.trusted
        }
    }
}

/// The welcome window's tips, one row each. The first names the shortcut, so they're built from
/// its current text.
enum Tip: CaseIterable, Sendable {
    case pin, goTo, options, alwaysPin

    /// An SF Symbol for the row.
    var symbol: String {
        switch self {
        case .pin: "pin"
        case .goTo: "cursorarrow.click"
        case .options: "contextualmenu.and.cursorarrow"
        case .alwaysPin: "arrow.clockwise"
        }
    }

    /// The tip, in a sentence or two that fit two lines of the welcome window.
    func text(shortcutText: String) -> String {
        switch self {
        case .pin:
            "Press \(shortcutText) to pin or unpin a window, or pick one in the menu bar menu."
        case .goTo:
            "Click a pinned window to go to it. It floats again when you switch away."
        case .options:
            "Right-click a pinned window, or find it under \(MenuWords.pinned) in the menu bar menu, and choose \(MenuWords.opacity) or \(MenuWords.unpin)."
        case .alwaysPin:
            "\(MenuWords.alwaysPin), in the same menu, keeps one of an app's windows pinned after the app restarts."
        }
    }
}

/// What the welcome window shows, refreshed about once a second while it's open.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published private(set) var screenRecording: Bool
    @Published private(set) var accessibility: Bool
    /// The shortcut in use, as the tips write it.
    @Published private(set) var shortcutText: String
    private let screenRecordingAtLaunch: Bool
    private let currentShortcut: () -> Shortcut
    private let permissionIsGranted: (Permission) -> Bool

    /// `isGranted` says whether a permission is granted. It asks macOS, except in the README's
    /// screenshots, which show both granted whatever the Mac drawing them has.
    init(
        screenRecordingAtLaunch: Bool, currentShortcut: @escaping () -> Shortcut,
        isGranted: @escaping (Permission) -> Bool = { $0.isGranted }
    ) {
        self.screenRecordingAtLaunch = screenRecordingAtLaunch
        self.currentShortcut = currentShortcut
        permissionIsGranted = isGranted
        screenRecording = isGranted(.screenRecording)
        accessibility = isGranted(.accessibility)
        shortcutText = currentShortcut().text
    }

    var needsRelaunch: Bool {
        Rules.needsRelaunch(screenRecordingAtLaunch: screenRecordingAtLaunch, screenRecordingNow: screenRecording)
    }

    func isGranted(_ permission: Permission) -> Bool {
        permission == .screenRecording ? screenRecording : accessibility
    }

    func refresh() {
        // Only changes are published, so the window isn't redrawn every second for nothing.
        let screenRecording = permissionIsGranted(.screenRecording)
        let accessibility = permissionIsGranted(.accessibility)
        let shortcutText = currentShortcut().text
        if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if shortcutText != self.shortcutText { self.shortcutText = shortcutText }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    /// The app's icon. It's passed in rather than read from `NSApp` here, so the README's
    /// screenshots can draw this view without the app running.
    let icon: NSImage
    let grant: (Permission) -> Void
    let relaunch: () -> Void
    let showChangeShortcut: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to Pin on Top")
                    .font(.title2.weight(.semibold))
                Text(Tagline.text)
            }
            .multilineTextAlignment(.center)

            GroupBox {
                VStack(spacing: 10) {
                    ForEach(Permission.allCases, id: \.self) { permission in
                        if permission != Permission.allCases.first { Divider() }
                        PermissionRow(permission: permission, granted: model.isGranted(permission), grant: grant)
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(spacing: 10) {
                    ForEach(Tip.allCases, id: \.self) { tip in
                        if tip != Tip.allCases.first { Divider() }
                        TipRow(tip: tip, shortcutText: model.shortcutText, showChangeShortcut: showChangeShortcut)
                    }
                }
                .padding(6)
            }

            if model.needsRelaunch {
                Text("Screen Recording starts working once Pin on Top reopens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top) {
                Spacer()
                if model.needsRelaunch {
                    Button("Done", action: done)
                    Button("Quit and Reopen", action: relaunch)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// One permission: what it's for, then a green tick once it's granted or a button to grant it.
private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    let grant: (Permission) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.name)
                    .fontWeight(.semibold)
                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            if granted {
                Label {
                    Text("Granted")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Button("Grant…") { grant(permission) }
            }
        }
    }
}

/// One tip: its symbol beside a sentence or two, which wrap rather than cut off. The shortcut's
/// tip has a button to change it.
private struct TipRow: View {
    let tip: Tip
    let shortcutText: String
    let showChangeShortcut: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: tip.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(tip.text(shortcutText: shortcutText))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if tip == .pin {
                Button("Change…", action: showChangeShortcut)
            }
        }
    }
}

/// Shows the welcome window, keeping its permissions and shortcut up to date while it's open.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: WelcomeModel
    private let grant: (Permission) -> Void
    private let relaunch: () -> Void
    private let showChangeShortcut: () -> Void
    private var window: NSWindow?
    private var timer: Timer?

    /// `currentShortcut` gives the shortcut in use, and `showChangeShortcut` opens the Change
    /// Shortcut window.
    init(
        screenRecordingAtLaunch: Bool, currentShortcut: @escaping () -> Shortcut, grant: @escaping (Permission) -> Void,
        relaunch: @escaping () -> Void, showChangeShortcut: @escaping () -> Void
    ) {
        model = WelcomeModel(screenRecordingAtLaunch: screenRecordingAtLaunch, currentShortcut: currentShortcut)
        self.grant = grant
        self.relaunch = relaunch
        self.showChangeShortcut = showChangeShortcut
    }

    /// Shows a change, such as a new shortcut, now rather than at the next tick.
    func refresh() {
        model.refresh()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        // It's a menu bar app, so it has to come forward or the window opens behind the current app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(
            model: model, icon: NSApp.applicationIconImage, grant: grant, relaunch: relaunch,
            showChangeShortcut: showChangeShortcut
        ) { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Pin on Top"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Change Shortcut window

/// What the Change Shortcut window shows.
@MainActor
final class ShortcutModel: ObservableObject {
    /// The shortcut in use.
    @Published var shortcut: Shortcut
    @Published var isRecording = false
    /// Why the last shortcut tried couldn't be used, until another is tried.
    @Published var problem: ShortcutProblem?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }
}

struct ShortcutView: View {
    @ObservedObject var model: ShortcutModel
    let record: () -> Void
    let cancel: () -> Void
    let reset: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                Group {
                    if model.isRecording {
                        Text("Press the new shortcut")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.shortcut.text)
                    }
                }
                .font(.title2)
                .frame(maxWidth: .infinity)
                .padding(6)
            }
            Text(model.isRecording
                ? "Hold ⌘, ⌃ or ⌥ and press a key. Press Escape to cancel."
                : "Press it in any app to pin or unpin the window you're using.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let problem = model.problem {
                Label {
                    Text(problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .font(.callout)
            }
            HStack(alignment: .top) {
                if model.isRecording {
                    Button("Cancel", action: cancel)
                } else {
                    Button("Record New Shortcut", action: record)
                }
                Button("Reset to \(HotKey.standard.text)", action: reset)
                    .disabled(model.shortcut == HotKey.standard)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Shows the Change Shortcut window and records a new shortcut in it. While it records, the hot
/// key is suspended, so pressing the current shortcut records it instead of pinning a window.
@MainActor
final class ShortcutWindowController: NSObject, NSWindowDelegate {
    private let model: ShortcutModel
    private let currentShortcut: () -> Shortcut
    private let change: (Shortcut) -> Bool
    private let suspend: () -> Void
    private let resume: () -> Void
    private var window: NSWindow?
    private var monitor: Any?

    /// `currentShortcut` gives the shortcut in use. `change` makes another one the shortcut and
    /// says whether macOS took it; when it didn't, the old one is still working. `suspend` and
    /// `resume` stop and restart the hot key around recording.
    init(
        currentShortcut: @escaping () -> Shortcut, change: @escaping (Shortcut) -> Bool,
        suspend: @escaping () -> Void, resume: @escaping () -> Void
    ) {
        model = ShortcutModel(shortcut: currentShortcut())
        self.currentShortcut = currentShortcut
        self.change = change
        self.suspend = suspend
        self.resume = resume
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.shortcut = currentShortcut()
        // It's a menu bar app, so it has to come forward to take the key presses.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = ShortcutView(
            model: model,
            record: { [weak self] in self?.startRecording() },
            cancel: { [weak self] in self?.stopRecording() },
            reset: { [weak self] in self?.apply(HotKey.standard) },
            done: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "Change Shortcut"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func startRecording() {
        guard monitor == nil else { return }
        suspend()
        model.problem = nil
        model.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let characters = event.characters(byApplyingModifiers: [])
            MainActor.assumeIsolated { self?.recordKeyPress(keyCode: keyCode, modifiers: modifiers, characters: characters) }
            // The key press is the new shortcut, so nothing else gets it.
            return nil
        }
    }

    /// A key press while recording. Modifier keys alone don't send one, so recording keeps
    /// waiting until a key is pressed with them.
    private func recordKeyPress(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        guard Int(keyCode) != kVK_Escape else {
            stopRecording()
            return
        }
        switch Rules.shortcut(keyCode: UInt32(keyCode), modifiers: modifiers, characters: characters) {
        case let .success(shortcut):
            apply(shortcut)
        case let .failure(problem):
            // Say why, and keep recording.
            model.problem = problem
        }
    }

    /// Makes a shortcut the one in use, ending any recording. If macOS won't take it, the old one
    /// keeps working and the window says why.
    private func apply(_ shortcut: Shortcut) {
        endRecording()
        if change(shortcut) {
            model.shortcut = shortcut
            model.problem = nil
        } else {
            model.problem = .inUse(shortcut.text)
        }
    }

    /// Cancels recording, restoring the hot key.
    private func stopRecording() {
        guard endRecording() else { return }
        model.problem = nil
        resume()
    }

    /// Stops listening for key presses, and says whether it was recording.
    @discardableResult
    private func endRecording() -> Bool {
        guard let monitor else { return false }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        model.isRecording = false
        return true
    }

    // Switching to another app ends recording too, so the hot key isn't left suspended.
    func windowDidResignKey(_ notification: Notification) {
        stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        model.problem = nil
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pins: [Pin] = []

    /// Always Pin's remembered apps, the processes it leaves alone after an unpin by hand, and when
    /// automatic pins last failed, by window ID.
    private var alwaysPin: [AlwaysPinRule] = []
    private var suppressed: Set<pid_t> = []
    private var autoPinFailures: [CGWindowID: Date] = [:]
    private static let alwaysPinKey = "alwaysPin"
    private static let hasSeenWelcomeKey = "hasSeenWelcome"
    private static let shortcutKey = "shortcut"

    /// The shortcut in use, and its hot key while it's registered (it isn't while a new shortcut
    /// is being recorded, or if macOS wouldn't register it).
    private var shortcut = HotKey.standard
    private var hotKey: EventHotKeyRef?

    /// Screen Recording only takes effect after a relaunch, so the welcome window compares with this.
    private var screenRecordingAtLaunch = false
    private var welcome: WelcomeWindowController?
    private var shortcutWindow: ShortcutWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        alwaysPin = Rules.alwaysPinRules(from: UserDefaults.standard.data(forKey: Self.alwaysPinKey))
        shortcut = Rules.shortcut(from: UserDefaults.standard.data(forKey: Self.shortcutKey))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        hotKeyHandler = { [weak self] in self?.toggleFrontmostWindow() }
        installHotKeyHandler()
        hotKey = registerHotKey(shortcut)

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        RunLoop.main.add(timer, forMode: .common)

        // Always Pin checks about once a second, which is plenty to catch an app's windows.
        let autoPinTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoPin() }
        }
        RunLoop.main.add(autoPinTimer, forMode: .common)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(refreshAll), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // The welcome window asks for missing permissions, so the launch doesn't prompt by itself.
        screenRecordingAtLaunch = Permission.screenRecording.isGranted
        let showsWelcome = Rules.showsWelcome(
            hasSeenWelcome: UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey),
            screenRecording: screenRecordingAtLaunch, accessibility: Permission.accessibility.isGranted)
        if showsWelcome { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pins.forEach { $0.stop() }
    }

    @objc private func refreshAll() {
        pins.forEach { $0.refresh() }
    }

    private func updateIcon() {
        let name = pins.isEmpty ? "pin" : "pin.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Pin on Top")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: Pinning

    private func isPinned(_ id: CGWindowID) -> Bool { pins.contains { $0.windowID == id } }

    /// Pins a window. `byHand` is false for Always Pin's automatic pins, which fail quietly.
    private func pin(_ window: WindowInfo, byHand: Bool) {
        guard !isPinned(window.id) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            guard byHand else { return }
            CGRequestScreenCaptureAccess()
            showPermissionAlert(
                title: "Screen Recording permission needed",
                body: "Pin on Top shows pinned windows as a live mirror, which needs Screen Recording. Turn it on for Pin on Top in System Settings, then quit and reopen the app.",
                pane: Permission.screenRecording.pane)
            return
        }
        if byHand { suppressed = Rules.suppressed(suppressed, after: .pinnedByHand(window.pid)) }
        let pin = Pin(window: window)
        pin.onEnded = { [weak self] in self?.unpin($0, byHand: $1) }
        pin.isAlwaysPinned = { [weak self] in self?.isAlwaysPinned($0) ?? false }
        pin.onToggleAlwaysPin = { [weak self] in self?.toggleAlwaysPin(for: $0) }
        pins.append(pin)
        updateIcon()
        pin.start { [weak self] error in
            guard let error else {
                self?.rememberTitle(of: pin)
                return
            }
            self?.unpin(pin, byHand: false)
            guard byHand else {
                self?.autoPinFailures[window.id] = Date()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Couldn't pin that window"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Unpins a window. `byHand` is false when the window closed or capture stopped by itself.
    private func unpin(_ pin: Pin, byHand: Bool) {
        guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
        pins.remove(at: index)
        pin.stop()
        updateIcon()
        if byHand {
            suppressed = Rules.suppressed(suppressed, after: .unpinnedByHand(pin.pid, remembered: isAlwaysPinned(pin)))
        }
    }

    private func toggleFrontmostWindow() {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me else { return }
        let pid = front.processIdentifier
        let candidates = Windows.pinnable().filter { $0.pid == pid }
        let focusedID = AX.trusted ? AX.focusedWindowID(pid: pid) : nil
        guard let target = Rules.hotKeyTarget(candidates, focusedID: focusedID) else {
            NSSound.beep()
            return
        }
        if let existing = pins.first(where: { $0.windowID == target.id }) {
            unpin(existing, byHand: true)
        } else {
            pin(target, byHand: true)
        }
    }

    // MARK: Always Pin

    /// Pins a window of each remembered app that's running with none pinned. Without Screen
    /// Recording it does nothing, quietly: the permission prompts belong to pinning by hand.
    private func autoPin() {
        guard !alwaysPin.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        autoPinFailures = Rules.recentFailures(autoPinFailures, now: Date())
        let failed = Set(autoPinFailures.keys)
        // One window list per check, shared by every remembered app.
        let windows = Windows.pinnable()
        for rule in alwaysPin {
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: rule.bundleID).map(\.processIdentifier))
            let target = Rules.autoPinTarget(
                for: rule, candidates: windows.filter { pids.contains($0.pid) },
                appHasPin: pins.contains { $0.bundleID == rule.bundleID },
                suppressed: !suppressed.isDisjoint(with: pids), recentlyFailed: failed)
            if let target { pin(target, byHand: false) }
        }
    }

    /// An app's windows appear a moment after it opens, so check soon. The regular check covers the rest.
    @objc private func appLaunched() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.autoPin() }
        }
    }

    @objc private func appQuit(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        suppressed = Rules.suppressed(suppressed, after: .appQuit(app.processIdentifier))
    }

    private func isAlwaysPinned(_ pin: Pin) -> Bool {
        alwaysPin.contains { $0.bundleID == pin.bundleID }
    }

    private func toggleAlwaysPin(for pin: Pin) {
        guard let bundleID = pin.bundleID else { return }
        if isAlwaysPinned(pin) {
            turnOffAlwaysPin(bundleID)
        } else {
            liftSuppression(of: bundleID)
            let rule = AlwaysPinRule(bundleID: bundleID, appName: pin.appName, windowTitle: pin.title)
            saveAlwaysPin(Rules.adding(rule, to: alwaysPin))
        }
    }

    /// Forgets an app. Its pinned windows stay pinned.
    private func turnOffAlwaysPin(_ bundleID: String) {
        liftSuppression(of: bundleID)
        saveAlwaysPin(Rules.removing(bundleID: bundleID, from: alwaysPin))
    }

    private func liftSuppression(of bundleID: String) {
        suppressed = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .reduce(suppressed) { Rules.suppressed($0, after: .alwaysPinSwitched($1.processIdentifier)) }
    }

    /// Keeps the title of the window just pinned, so the same window is found after a restart.
    private func rememberTitle(of pin: Pin) {
        guard let bundleID = pin.bundleID else { return }
        let updated = Rules.updatingTitle(pin.title, bundleID: bundleID, in: alwaysPin)
        if updated != alwaysPin { saveAlwaysPin(updated) }
    }

    private func saveAlwaysPin(_ rules: [AlwaysPinRule]) {
        alwaysPin = rules
        UserDefaults.standard.set(Rules.alwaysPinData(rules), forKey: Self.alwaysPinKey)
    }

    // MARK: Shortcut

    @objc private func showChangeShortcut() {
        let controller = shortcutWindow ?? ShortcutWindowController(
            currentShortcut: { [weak self] in self?.shortcut ?? HotKey.standard },
            change: { [weak self] in self?.changeShortcut(to: $0) ?? false },
            suspend: { [weak self] in self?.suspendShortcut() },
            resume: { [weak self] in self?.resumeShortcut() })
        shortcutWindow = controller
        controller.show()
    }

    /// Unregisters the hot key while a new shortcut is recorded, so pressing the current one
    /// records it instead of pinning a window.
    private func suspendShortcut() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    /// Registers the shortcut in use again, unless it's registered already.
    private func resumeShortcut() {
        guard hotKey == nil else { return }
        hotKey = registerHotKey(shortcut)
    }

    /// Makes a shortcut the one in use, now and after the app reopens, and returns true. If macOS
    /// won't register it, the old one keeps working and this returns false.
    private func changeShortcut(to new: Shortcut) -> Bool {
        suspendShortcut()
        guard let registered = registerHotKey(new) else {
            resumeShortcut()
            return false
        }
        hotKey = registered
        shortcut = new
        // Nil, for the default, removes the key.
        UserDefaults.standard.set(Rules.shortcutData(new), forKey: Self.shortcutKey)
        // The menu reads the shortcut each time it opens. The welcome tips are told now.
        welcome?.refresh()
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: Self.versionTitle))

        // A key a menu can't show leaves the item with no key equivalent.
        let frontmost = menu.addItem(
            withTitle: "Pin/Unpin Frontmost Window", action: #selector(menuToggleFrontmost),
            keyEquivalent: Rules.menuKeyEquivalent(keyCode: shortcut.keyCode, key: shortcut.key) ?? "")
        frontmost.keyEquivalentModifierMask = shortcut.modifierFlags
        frontmost.target = self
        frontmost.image = symbol("pin")

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: MenuWords.pinned))
            for pin in pins {
                // It opens the window's right-click menu, so it has no action of its own.
                let item = menu.addItem(withTitle: pin.label, action: nil, keyEquivalent: "")
                item.state = .on
                item.image = appIcon(pid: pin.pid)
                item.submenu = pin.contextMenu()
            }
        }

        if !alwaysPin.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: MenuWords.alwaysPin))
            for rule in alwaysPin {
                let item = menu.addItem(withTitle: Rules.menuTitle(rule.appName), action: #selector(menuTurnOffAlwaysPin(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.representedObject = rule.bundleID
                item.image = appIcon(bundleID: rule.bundleID)
                item.toolTip = "Click to turn off \(MenuWords.alwaysPin) for this app"
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Pin a Window"))
        let windows = Windows.pinnable().filter { !isPinned($0.id) }
        if windows.isEmpty {
            menu.addItem(withTitle: "No windows found", action: nil, keyEquivalent: "").isEnabled = false
        }
        for window in windows {
            let item = menu.addItem(withTitle: window.label, action: #selector(menuPin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(window.id)
            item.image = appIcon(pid: window.pid)
        }

        menu.addItem(.separator())
        for (index, permission) in Permission.allCases.enumerated() where !permission.isGranted {
            let item = menu.addItem(withTitle: "Grant \(permission.name)…", action: #selector(menuGrant(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = symbol("exclamationmark.triangle")
        }
        let welcomeItem = menu.addItem(withTitle: "Welcome and Tips…", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        welcomeItem.image = symbol("gearshape")
        let shortcutItem = menu.addItem(withTitle: "Change Shortcut…", action: #selector(showChangeShortcut), keyEquivalent: "")
        shortcutItem.target = self
        shortcutItem.image = symbol("keyboard")
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Pin on Top", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = symbol("info.circle")
        let quit = menu.addItem(withTitle: "Quit Pin on Top", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("power")
    }

    /// The menu's header, such as "Pin on Top 1.0.0", with the version build.sh writes.
    private static var versionTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Pin on Top"
        }
        return "Pin on Top \(version)"
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func appIcon(pid: pid_t) -> NSImage? {
        menuIcon(NSRunningApplication(processIdentifier: pid)?.icon)
    }

    /// A remembered app's icon: from the running app, or else from wherever the app is installed.
    private func appIcon(bundleID: String) -> NSImage? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return menuIcon(running.icon)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return menuIcon(url.map { NSWorkspace.shared.icon(forFile: $0.path) })
    }

    private func menuIcon(_ image: NSImage?) -> NSImage? {
        guard let icon = image?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func menuToggleFrontmost() { toggleFrontmostWindow() }

    @objc private func menuPin(_ sender: NSMenuItem) {
        guard let window = Windows.info(CGWindowID(sender.tag)) else { return }
        pin(window, byHand: true)
    }

    @objc private func menuTurnOffAlwaysPin(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        turnOffAlwaysPin(bundleID)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMoving Pin on Top to your Applications folder usually fixes this."
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func menuGrant(_ sender: NSMenuItem) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        grant(Permission.allCases[sender.tag])
    }

    // MARK: Welcome and About

    @objc private func showWelcome() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenWelcomeKey)
        let controller = welcome ?? WelcomeWindowController(
            screenRecordingAtLaunch: screenRecordingAtLaunch,
            currentShortcut: { [weak self] in self?.shortcut ?? HotKey.standard },
            grant: { [weak self] in self?.grant($0) },
            relaunch: { [weak self] in self?.relaunch() },
            showChangeShortcut: { [weak self] in self?.showChangeShortcut() })
        welcome = controller
        controller.show()
    }

    /// Asks macOS for a permission, then opens its System Settings pane to turn it on.
    private func grant(_ permission: Permission) {
        switch permission {
        case .screenRecording: CGRequestScreenCaptureAccess()
        case .accessibility: AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        openSettings(permission.pane)
    }

    /// Opens a new copy of the app and quits this one, so a new Screen Recording grant takes effect.
    private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try open.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't reopen Pin on Top"
            alert.informativeText = "\(error.localizedDescription)\n\nQuit Pin on Top from the menu bar, then open it again."
            NSApp.activate()
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
    }

    /// The About panel's credits: what the app does and a link to its project page.
    private static var aboutCredits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ]
        let credits = NSMutableAttributedString(string: "\(Tagline.text)\n", attributes: style)
        if let page = URL(string: "https://github.com/Kurrt/pin-on-top") {
            credits.append(NSAttributedString(string: "github.com/Kurrt/pin-on-top", attributes: style.merging([.link: page]) { $1 }))
        }
        return credits
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showPermissionAlert(title: String, body: String, pane: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openSettings(pane) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
