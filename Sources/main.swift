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

    /// A shortcut the way macOS menus write it, such as ⌃⌥⌘P.
    static func shortcutText(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        let glyphs: [(flag: NSEvent.ModifierFlags, glyph: String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return glyphs.filter { modifiers.contains($0.flag) }.map(\.glyph).joined() + key.uppercased()
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
        badge.toolTip = "Pinned: click to switch to this window, right-click for options"
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
    /// Called when the pin should go. `byHand` is true when it was unpinned from the right-click
    /// menu, and false when the window closed or capture stopped.
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

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let go = menu.addItem(withTitle: "Go to Window", action: #selector(goToWindow), keyEquivalent: "")
        go.target = self

        let opacityItem = menu.addItem(withTitle: "Opacity", action: nil, keyEquivalent: "")
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
        let always = menu.addItem(withTitle: "Always Pin “\(Rules.menuTitle(appName))”", action: nil, keyEquivalent: "")
        if bundleID == nil {
            always.toolTip = "This app has no bundle identifier, so Pin on Top can't remember it."
        } else {
            always.action = #selector(toggleAlwaysPin)
            always.target = self
            always.state = isAlwaysPinned?(self) == true ? .on : .off
        }

        menu.addItem(.separator())
        let unpinItem = menu.addItem(withTitle: "Unpin", action: #selector(unpin), keyEquivalent: "")
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

// MARK: - Global hot key (Ctrl-Option-Command-P)

/// The one shortcut. The registered hot key and the menu item both read it, so they can't drift.
enum HotKey {
    static let keyCode = UInt32(kVK_ANSI_P)
    static let modifiers = UInt32(cmdKey | optionKey | controlKey)
    static let menuKey = "p"
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    static let signature = OSType(0x5049_4E54) // "PINT"

    /// The shortcut as menus write it: ⌃⌥⌘P.
    static var text: String { Rules.shortcutText(modifiers: menuModifiers, key: menuKey) }
}

@MainActor var hotKeyHandler: (() -> Void)?

func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { hotKeyHandler?() } }
        return noErr
    }, 1, &spec, nil, nil)

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: HotKey.signature, id: 1)
    RegisterEventHotKey(HotKey.keyCode, HotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
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

/// What the welcome window shows, refreshed about once a second while it's open.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published private(set) var screenRecording = Permission.screenRecording.isGranted
    @Published private(set) var accessibility = Permission.accessibility.isGranted
    private let screenRecordingAtLaunch: Bool

    init(screenRecordingAtLaunch: Bool) {
        self.screenRecordingAtLaunch = screenRecordingAtLaunch
    }

    var needsRelaunch: Bool {
        Rules.needsRelaunch(screenRecordingAtLaunch: screenRecordingAtLaunch, screenRecordingNow: screenRecording)
    }

    func isGranted(_ permission: Permission) -> Bool {
        permission == .screenRecording ? screenRecording : accessibility
    }

    func refresh() {
        // Only changes are published, so the window isn't redrawn every second for nothing.
        let screenRecording = Permission.screenRecording.isGranted
        let accessibility = Permission.accessibility.isGranted
        if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
        if accessibility != self.accessibility { self.accessibility = accessibility }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let grant: (Permission) -> Void
    let relaunch: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to Pin on Top")
                    .font(.title2.weight(.semibold))
                Text(Tagline.text)
                Text("Press \(HotKey.text) to pin or unpin the window you're using.")
                    .foregroundStyle(.secondary)
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

/// Shows the welcome window, keeping its permissions up to date while it's open.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: WelcomeModel
    private let grant: (Permission) -> Void
    private let relaunch: () -> Void
    private var window: NSWindow?
    private var timer: Timer?

    init(screenRecordingAtLaunch: Bool, grant: @escaping (Permission) -> Void, relaunch: @escaping () -> Void) {
        model = WelcomeModel(screenRecordingAtLaunch: screenRecordingAtLaunch)
        self.grant = grant
        self.relaunch = relaunch
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
        let view = WelcomeView(model: model, grant: grant, relaunch: relaunch) { [weak self] in self?.window?.close() }
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

    /// Screen Recording only takes effect after a relaunch, so the welcome window compares with this.
    private var screenRecordingAtLaunch = false
    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        alwaysPin = Rules.alwaysPinRules(from: UserDefaults.standard.data(forKey: Self.alwaysPinKey))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        hotKeyHandler = { [weak self] in self?.toggleFrontmostWindow() }
        registerHotKey()

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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: Self.versionTitle))

        let frontmost = menu.addItem(withTitle: "Pin/Unpin Frontmost Window", action: #selector(menuToggleFrontmost), keyEquivalent: HotKey.menuKey)
        frontmost.keyEquivalentModifierMask = HotKey.menuModifiers
        frontmost.target = self
        frontmost.image = symbol("pin")

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Pinned"))
            for pin in pins {
                let item = menu.addItem(withTitle: pin.label, action: #selector(menuUnpin(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.tag = Int(pin.windowID)
                item.image = appIcon(pid: pin.pid)
                item.toolTip = "Click to unpin"
            }
        }

        if !alwaysPin.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Always Pin"))
            for rule in alwaysPin {
                let item = menu.addItem(withTitle: Rules.menuTitle(rule.appName), action: #selector(menuTurnOffAlwaysPin(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.representedObject = rule.bundleID
                item.image = appIcon(bundleID: rule.bundleID)
                item.toolTip = "Click to turn off Always Pin for this app"
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
        let welcomeItem = menu.addItem(withTitle: "Welcome and Permissions…", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        welcomeItem.image = symbol("gearshape")
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

    @objc private func menuUnpin(_ sender: NSMenuItem) {
        guard let pin = pins.first(where: { $0.windowID == CGWindowID(sender.tag) }) else { return }
        unpin(pin, byHand: true)
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
            grant: { [weak self] in self?.grant($0) },
            relaunch: { [weak self] in self?.relaunch() })
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
