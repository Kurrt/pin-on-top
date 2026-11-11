import AppKit
import Carbon.HIToolbox
import Testing
@testable import PinOnTop

private func window(id: CGWindowID, width: CGFloat = 300) -> WindowInfo {
    WindowInfo(id: id, pid: 7, appName: "Notes", title: "", bounds: CGRect(x: 0, y: 0, width: width, height: 200), layer: 0)
}

/// The letter keys' virtual key codes, which RegisterEventHotKey takes, and the character a menu
/// item's key equivalent uses for each.
private let letterKeys: [Int: String] = [
    kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
    kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
    kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
    kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
    kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
    kVK_ANSI_Z: "z",
]

/// Carbon's modifier bits and the menu's modifier flags for the same keys.
private let modifierKeys: [(carbon: Int, menu: NSEvent.ModifierFlags)] = [
    (controlKey, .control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command),
]

private let shortcuts: [(modifiers: NSEvent.ModifierFlags, key: String, text: String)] = [
    (.command, "q", "⌘Q"),
    ([.shift, .command], "k", "⇧⌘K"),
    ([.command, .shift, .option, .control], "p", "⌃⌥⇧⌘P"),
]

struct HotKeyTests {
    @Test func theHotKeyPicksTheFocusedWindowOverTheFrontmostOne() {
        let target = Rules.hotKeyTarget([window(id: 1), window(id: 2)], focusedID: 2)
        #expect(target?.id == 2)
    }

    @Test func withFocusUnknownItPicksTheFrontmostWindowOfThatApp() {
        let target = Rules.hotKeyTarget([window(id: 1), window(id: 2)], focusedID: nil)
        #expect(target?.id == 1)
    }

    @Test func aFocusedWindowTooSmallToPinFallsBackToTheFrontmostPinnableOne() {
        let candidates = Rules.pinnable([window(id: 1, width: 40), window(id: 2), window(id: 3)], excluding: 99)
        #expect(Rules.hotKeyTarget(candidates, focusedID: 1)?.id == 2)
    }

    @Test func withNoPinnableWindowItPicksNothing() {
        #expect(Rules.hotKeyTarget([], focusedID: 1) == nil)
        #expect(Rules.hotKeyTarget([], focusedID: nil) == nil)
    }

    @Test func theMenuShortcutAndTheRegisteredHotKeyUseTheSameKey() {
        #expect(letterKeys[Int(HotKey.keyCode)] == HotKey.menuKey)
    }

    @Test func theMenuShortcutAndTheRegisteredHotKeyUseTheSameModifiers() {
        let known = modifierKeys.reduce(0) { $0 | $1.carbon }
        #expect(Int(HotKey.modifiers) & ~known == 0)
        let fromCarbon = modifierKeys
            .filter { Int(HotKey.modifiers) & $0.carbon != 0 }
            .reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.menu) }
        #expect(fromCarbon == HotKey.menuModifiers)
    }

    @Test func theWelcomeWindowWritesTheShortcutAsTheDocsDo() {
        #expect(HotKey.text == "⌃⌥⌘P")
    }

    @Test(arguments: shortcuts)
    func modifiersAreWrittenInTheOrderMacOSMenusUse(modifiers: NSEvent.ModifierFlags, key: String, text: String) {
        #expect(Rules.shortcutText(modifiers: modifiers, key: key) == text)
    }

    @Test func theHotKeySignatureReadsPINT() {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: HotKey.signature >> $0) }
        #expect(String(decoding: bytes, as: UTF8.self) == "PINT")
    }
}
