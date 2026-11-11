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

    var label: String {
        let full = title.isEmpty ? appName : "\(appName) – \(title)"
        return full.count > 70 ? "\(full.prefix(69))…" : full
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
        let me = ProcessInfo.processInfo.processIdentifier
        return list([.optionOnScreenOnly, .excludeDesktopElements]).filter {
            $0.layer == 0 && $0.pid != me && $0.bounds.width >= 80 && $0.bounds.height >= 60
        }
    }
}

/// CoreGraphics uses a top-left origin on the primary display; AppKit uses bottom-left.
func appKitFrame(fromCG rect: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
    private(set) var label: String
    var onEnded: ((Pin) -> Void)?

    private let panel: OverlayPanel
    private let view: OverlayView
    private var stream: SCStream?
    private var streamSize = CGSize.zero
    private var pointPixelScale: CGFloat = 2
    private var axWindow: AXUIElement?
    private var hasFrame = false
    private let frameQueue = DispatchQueue(label: "pin-on-top.frames", qos: .userInteractive)

    init(window: WindowInfo) {
        windowID = window.id
        pid = window.pid
        label = window.label

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
        config.width = max(1, Int((size.width * pointPixelScale).rounded()))
        config.height = max(1, Int((size.height * pointPixelScale).rounded()))
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
            onEnded?(self)
            return
        }
        label = info.label

        let frame = appKitFrame(fromCG: info.bounds)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if info.bounds.size != streamSize, let stream {
            streamSize = info.bounds.size
            stream.updateConfiguration(configuration(for: streamSize), completionHandler: nil)
        }

        let shouldShow = hasFrame && !isTargetFocused() && !isTargetHidden()
        if shouldShow && !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !shouldShow && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func isTargetFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        // Without Accessibility we can't tell which of the app's windows is focused, so assume ours.
        guard AX.trusted, let focused = AX.focusedWindowID(pid: pid) else { return true }
        return focused == windowID
    }

    private func isTargetHidden() -> Bool {
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return true }
        guard AX.trusted, let window = resolvedAXWindow() else { return false }
        return AX.isMinimised(window)
    }

    private func resolvedAXWindow() -> AXUIElement? {
        if let axWindow, AX.windowID(of: axWindow) == windowID { return axWindow }
        axWindow = AX.window(pid: pid, id: windowID)
        return axWindow
    }

    @objc func goToWindow() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        AX.bringToFront(pid: pid, window: AX.trusted ? resolvedAXWindow() : nil)
        panel.orderOut(nil)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        panel.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func unpin() { onEnded?(self) }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let go = menu.addItem(withTitle: "Go to Window", action: #selector(goToWindow), keyEquivalent: "")
        go.target = self

        let opacityItem = menu.addItem(withTitle: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 85, 70, 50, 30] {
            let item = opacityMenu.addItem(withTitle: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int((panel.alphaValue * 100).rounded()) == percent ? .on : .off
        }
        opacityItem.submenu = opacityMenu

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
            MainActor.assumeIsolated { self.onEnded?(self) }
        }
    }
}

// MARK: - Global hot key (Ctrl-Option-Command-P)

@MainActor var hotKeyHandler: (() -> Void)?

func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { hotKeyHandler?() } }
        return noErr
    }, 1, &spec, nil, nil)

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x5049_4E54), id: 1) // "PINT"
    RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pins: [Pin] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AX.trusted {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        hotKeyHandler = { [weak self] in self?.toggleFrontmostWindow() }
        registerHotKey()

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        RunLoop.main.add(timer, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAll), name: NSWorkspace.didActivateApplicationNotification, object: nil)
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

    private func pin(_ window: WindowInfo) {
        guard !isPinned(window.id) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showPermissionAlert(
                title: "Screen Recording permission needed",
                body: "Pin on Top shows pinned windows as a live mirror, which needs Screen Recording. Turn it on for Pin on Top in System Settings, then quit and reopen the app.",
                pane: "Privacy_ScreenCapture")
            return
        }
        let pin = Pin(window: window)
        pin.onEnded = { [weak self] in self?.unpin($0) }
        pins.append(pin)
        updateIcon()
        pin.start { [weak self] error in
            guard let error else { return }
            self?.unpin(pin)
            let alert = NSAlert()
            alert.messageText = "Couldn't pin that window"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    private func unpin(_ pin: Pin) {
        guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
        pins.remove(at: index)
        pin.stop()
        updateIcon()
    }

    private func toggleFrontmostWindow() {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me else { return }
        let pid = front.processIdentifier
        let candidates = Windows.pinnable().filter { $0.pid == pid }
        let focusedID = AX.trusted ? AX.focusedWindowID(pid: pid) : nil
        guard let target = candidates.first(where: { $0.id == focusedID }) ?? candidates.first else {
            NSSound.beep()
            return
        }
        if let existing = pins.first(where: { $0.windowID == target.id }) {
            unpin(existing)
        } else {
            pin(target)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let frontmost = menu.addItem(withTitle: "Pin/Unpin Frontmost Window", action: #selector(menuToggleFrontmost), keyEquivalent: "p")
        frontmost.keyEquivalentModifierMask = [.control, .option, .command]
        frontmost.target = self

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Pinned (click to unpin)"))
            for pin in pins {
                let item = menu.addItem(withTitle: pin.label, action: #selector(menuUnpin(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.tag = Int(pin.windowID)
                item.image = appIcon(pid: pin.pid)
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
        if !CGPreflightScreenCaptureAccess() {
            let item = menu.addItem(withTitle: "Grant Screen Recording…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            item.target = self
        }
        if !AX.trusted {
            let item = menu.addItem(withTitle: "Grant Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
        }
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(withTitle: "Quit Pin on Top", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func appIcon(pid: pid_t) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func menuToggleFrontmost() { toggleFrontmostWindow() }

    @objc private func menuPin(_ sender: NSMenuItem) {
        guard let window = Windows.info(CGWindowID(sender.tag)) else { return }
        pin(window)
    }

    @objc private func menuUnpin(_ sender: NSMenuItem) {
        guard let pin = pins.first(where: { $0.windowID == CGWindowID(sender.tag) }) else { return }
        unpin(pin)
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

    @objc private func openScreenRecordingSettings() { openSettings("Privacy_ScreenCapture") }
    @objc private func openAccessibilitySettings() { openSettings("Privacy_Accessibility") }

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
