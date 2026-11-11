import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import PinOnTop

private func window(id: CGWindowID, width: CGFloat = 300) -> WindowInfo {
    WindowInfo(id: id, pid: 7, appName: "Notes", title: "", bounds: CGRect(x: 0, y: 0, width: width, height: 200), layer: 0)
}

/// The letter keys' virtual key codes, which RegisterEventHotKey takes, and the character each
/// types, which a menu item's key equivalent uses.
private let letterKeys: [Int: String] = [
    kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
    kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
    kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
    kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
    kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
    kVK_ANSI_Z: "z",
]

/// Keys shown by what they type with no modifiers: digits and punctuation as typed, and letters
/// from other keyboard layouts upper cased.
private let typedKeys: [(code: Int, characters: String, name: String)] = [
    (kVK_ANSI_1, "1", "1"), (kVK_ANSI_0, "0", "0"), (kVK_ANSI_Keypad5, "5", "5"),
    (kVK_ANSI_Semicolon, ";", ";"), (kVK_ANSI_Slash, "/", "/"), (kVK_ANSI_LeftBracket, "[", "["),
    (kVK_ANSI_Grave, "`", "`"), (kVK_ANSI_Equal, "=", "="), (kVK_ANSI_Comma, ",", ","),
    // A French keyboard types a where a US one types q, and a Russian one types з for p.
    (kVK_ANSI_Q, "a", "A"), (kVK_ANSI_P, "з", "З"),
    // Upper case would make ß two letters, so it stays as it is.
    (kVK_ANSI_Minus, "ß", "ß"),
]

/// Keys menus show by name or symbol, and the NSEvent character a menu item's key equivalent
/// uses for each. The key press's own characters don't matter for these.
private let namedKeys: [(code: Int, name: String, equivalent: Int)] = [
    (kVK_Space, "Space", 0x20), (kVK_Return, "↩", 0x0D), (kVK_Tab, "⇥", 0x09), (kVK_Delete, "⌫", 0x08),
    (kVK_ForwardDelete, "⌦", NSDeleteFunctionKey),
    (kVK_LeftArrow, "←", NSLeftArrowFunctionKey), (kVK_RightArrow, "→", NSRightArrowFunctionKey),
    (kVK_UpArrow, "↑", NSUpArrowFunctionKey), (kVK_DownArrow, "↓", NSDownArrowFunctionKey),
    (kVK_Home, "↖", NSHomeFunctionKey), (kVK_End, "↘", NSEndFunctionKey),
    (kVK_PageUp, "⇞", NSPageUpFunctionKey), (kVK_PageDown, "⇟", NSPageDownFunctionKey),
    (kVK_F1, "F1", NSF1FunctionKey), (kVK_F2, "F2", NSF2FunctionKey), (kVK_F3, "F3", NSF3FunctionKey),
    (kVK_F4, "F4", NSF4FunctionKey), (kVK_F5, "F5", NSF5FunctionKey), (kVK_F6, "F6", NSF6FunctionKey),
    (kVK_F7, "F7", NSF7FunctionKey), (kVK_F8, "F8", NSF8FunctionKey), (kVK_F9, "F9", NSF9FunctionKey),
    (kVK_F10, "F10", NSF10FunctionKey), (kVK_F11, "F11", NSF11FunctionKey), (kVK_F12, "F12", NSF12FunctionKey),
    (kVK_F13, "F13", NSF13FunctionKey), (kVK_F14, "F14", NSF14FunctionKey), (kVK_F15, "F15", NSF15FunctionKey),
    (kVK_F16, "F16", NSF16FunctionKey), (kVK_F17, "F17", NSF17FunctionKey), (kVK_F18, "F18", NSF18FunctionKey),
    (kVK_F19, "F19", NSF19FunctionKey), (kVK_F20, "F20", NSF20FunctionKey),
]

/// Key presses with no name to show: Escape, modifier and media keys, and keys that type nothing,
/// a space, a control character, NSEvent's private characters or more than one character.
private let unnamedKeyPresses: [(code: Int, characters: String?)] = [
    (kVK_Escape, "\u{1B}"), (kVK_Command, ""), (kVK_RightShift, nil), (kVK_CapsLock, ""),
    (kVK_Function, ""), (kVK_VolumeUp, nil), (kVK_Help, "\u{F746}"), (kVK_ANSI_KeypadClear, "\u{F739}"),
    (kVK_ANSI_KeypadEnter, "\u{3}"), (kVK_ANSI_A, nil), (kVK_ANSI_A, ""), (kVK_ANSI_A, " "),
    (kVK_ANSI_A, "ab"), (128, "a"),
]

/// Carbon's modifier bits and the menu's modifier flags for the same keys.
private let modifierKeys: [(carbon: Int, menu: NSEvent.ModifierFlags)] = [
    (controlKey, .control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command),
]

private let shortcuts: [(modifiers: NSEvent.ModifierFlags, key: String, text: String)] = [
    (.command, "q", "⌘Q"),
    ([.shift, .command], "k", "⇧⌘K"),
    ([.command, .shift, .option, .control], "p", "⌃⌥⇧⌘P"),
    (.option, "F5", "⌥F5"),
    ([.control, .option, .shift, .command], "Space", "⌃⌥⇧⌘Space"),
    ([.control, .command], "↩", "⌃⌘↩"),
]

/// Key presses that make a shortcut: at least one of ⌘, ⌃ or ⌥. Caps Lock, Fn and the numeric
/// pad flag, which F-keys and arrows bring, are left out.
private let allowedPresses: [(code: Int, modifiers: NSEvent.ModifierFlags, characters: String?, carbon: Int, text: String)] = [
    (kVK_ANSI_K, .command, "k", cmdKey, "⌘K"),
    (kVK_ANSI_K, [.shift, .command], "k", shiftKey | cmdKey, "⇧⌘K"),
    (kVK_ANSI_P, [.control, .option, .command], "p", controlKey | optionKey | cmdKey, "⌃⌥⌘P"),
    (kVK_ANSI_K, [.control, .capsLock], "k", controlKey, "⌃K"),
    (kVK_ANSI_1, [.option, .shift], "1", optionKey | shiftKey, "⌥⇧1"),
    (kVK_F5, [.option, .function], "\u{F708}", optionKey, "⌥F5"),
    (kVK_Space, [.control, .shift], " ", controlKey | shiftKey, "⌃⇧Space"),
    (kVK_LeftArrow, [.control, .option, .function, .numericPad], "\u{F702}", controlKey | optionKey, "⌃⌥←"),
]

/// Key presses refused for having none of ⌘, ⌃ or ⌥, written as the window shows them.
private let refusedPresses: [(code: Int, modifiers: NSEvent.ModifierFlags, characters: String?, text: String)] = [
    (kVK_ANSI_K, [], "k", "K"),
    (kVK_ANSI_K, .shift, "k", "⇧K"),
    (kVK_ANSI_K, [.shift, .capsLock], "k", "⇧K"),
    (kVK_F5, .function, "\u{F708}", "F5"),
    (kVK_Space, .shift, " ", "⇧Space"),
]

/// Shortcuts that are stored and read back unchanged.
private let storedShortcuts = [
    Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey | cmdKey), key: "K"),
    Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey), key: "F5"),
    Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), key: "Space"),
    Shortcut(keyCode: UInt32(kVK_ANSI_Semicolon), modifiers: UInt32(controlKey | cmdKey), key: ";"),
    Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), key: "P"),
]

/// Stored data that isn't a shortcut the app can use. cmdKey is 256, shiftKey 512 and alphaLock
/// (Caps Lock) 1024; key code 40 is K, 49 Space and 53 Escape.
private let badStoredShortcuts: [String] = [
    "",
    "not JSON",
    "[]",
    #"{"keyCode": 40, "modifiers": 256}"#,
    #"{"keyCode": "40", "modifiers": 256, "key": "K"}"#,
    #"{"keyCode": 40, "modifiers": 0, "key": "K"}"#,
    #"{"keyCode": 40, "modifiers": 512, "key": "K"}"#,
    #"{"keyCode": 40, "modifiers": 1280, "key": "K"}"#,
    #"{"keyCode": -1, "modifiers": 256, "key": "K"}"#,
    #"{"keyCode": 200, "modifiers": 256, "key": "K"}"#,
    #"{"keyCode": 53, "modifiers": 256, "key": "⎋"}"#,
    #"{"keyCode": 49, "modifiers": 256, "key": "K"}"#,
    #"{"keyCode": 40, "modifiers": 256, "key": "k"}"#,
    #"{"keyCode": 40, "modifiers": 256, "key": ""}"#,
    #"{"keyCode": 40, "modifiers": 256, "key": "KK"}"#,
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

    // MARK: The default

    @Test func theDefaultShortcutIsControlOptionCommandPAsTheDocsWriteIt() {
        #expect(HotKey.standard.keyCode == UInt32(kVK_ANSI_P))
        #expect(HotKey.standard.modifierFlags == [.control, .option, .command])
        #expect(HotKey.standard.text == "⌃⌥⌘P")
    }

    @Test func theDefaultShortcutIsOneTheWindowWouldRecord() {
        let recorded = Rules.shortcut(keyCode: HotKey.standard.keyCode, modifiers: [.control, .option, .command], characters: "p")
        #expect(recorded == .success(HotKey.standard))
    }

    @Test func theHotKeySignatureReadsPINT() {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: HotKey.signature >> $0) }
        #expect(String(decoding: bytes, as: UTF8.self) == "PINT")
    }

    // MARK: Modifiers

    @Test(arguments: modifierKeys)
    func eachModifierIsTheSameKeyInCarbonsMaskAndTheMenus(carbon: Int, menu: NSEvent.ModifierFlags) {
        #expect(Rules.carbonModifiers(menu) == UInt32(carbon))
        #expect(Rules.modifierFlags(carbon: UInt32(carbon)) == menu)
    }

    @Test(arguments: [
        NSEvent.ModifierFlags(), [.command], [.shift], [.control, .option, .command], [.control, .option, .shift, .command],
    ])
    func modifiersSurviveTheTripToCarbonsMaskAndBack(flags: NSEvent.ModifierFlags) {
        #expect(Rules.modifierFlags(carbon: Rules.carbonModifiers(flags)) == flags)
    }

    @Test func capsLockFnAndTheNumericPadAreLeftOutOfCarbonsMask() {
        #expect(Rules.carbonModifiers([.command, .capsLock, .function, .numericPad, .help]) == UInt32(cmdKey))
    }

    @Test func carbonBitsForOtherKeysAreLeftOutOfTheMenusModifiers() {
        #expect(Rules.modifierFlags(carbon: UInt32(cmdKey | alphaLock | btnState)) == .command)
    }

    @Test(arguments: shortcuts)
    func modifiersAreWrittenInTheOrderMacOSMenusUse(modifiers: NSEvent.ModifierFlags, key: String, text: String) {
        #expect(Rules.shortcutText(modifiers: modifiers, key: key) == text)
    }

    // MARK: Key names and menu key equivalents

    @Test(arguments: letterKeys.sorted { $0.key < $1.key })
    func aLetterIsNamedInUpperCaseAndItsMenuKeyEquivalentIsLowerCase(code: Int, letter: String) throws {
        let name = try #require(Rules.keyName(keyCode: UInt32(code), characters: letter))
        #expect(name == letter.uppercased())
        #expect(Rules.menuKeyEquivalent(keyCode: UInt32(code), key: name) == letter)
    }

    @Test(arguments: typedKeys)
    func otherTypedKeysAreNamedByWhatTheyTypeAndThatIsTheirMenuKeyEquivalent(code: Int, characters: String, name: String) {
        #expect(Rules.keyName(keyCode: UInt32(code), characters: characters) == name)
        #expect(Rules.menuKeyEquivalent(keyCode: UInt32(code), key: name) == characters)
    }

    @Test(arguments: namedKeys)
    func namedKeysAreShownAsMenusShowThemWhateverTheyType(code: Int, name: String, equivalent: Int) throws {
        for characters in [nil, "", " ", "\u{F700}", "x"] {
            #expect(Rules.keyName(keyCode: UInt32(code), characters: characters) == name)
        }
        let scalar = try #require(Unicode.Scalar(UInt32(equivalent)))
        #expect(Rules.menuKeyEquivalent(keyCode: UInt32(code), key: name) == String(Character(scalar)))
    }

    @Test(arguments: unnamedKeyPresses)
    func keysWithNoNameToShowAreNotNamed(code: Int, characters: String?) {
        #expect(Rules.keyName(keyCode: UInt32(code), characters: characters) == nil)
    }

    @Test func aKeyAMenuCantShowHasNoKeyEquivalent() {
        #expect(Rules.menuKeyEquivalent(keyCode: UInt32(kVK_ANSI_A), key: "AB") == nil)
        #expect(Rules.menuKeyEquivalent(keyCode: UInt32(kVK_ANSI_A), key: "") == nil)
    }

    // MARK: Recording

    @Test(arguments: allowedPresses)
    func aKeyPressedWithCommandControlOrOptionBecomesTheShortcut(
        code: Int, modifiers: NSEvent.ModifierFlags, characters: String?, carbon: Int, text: String
    ) throws {
        let shortcut = try Rules.shortcut(keyCode: UInt32(code), modifiers: modifiers, characters: characters).get()
        #expect(shortcut.keyCode == UInt32(code))
        #expect(shortcut.modifiers == UInt32(carbon))
        #expect(shortcut.text == text)
    }

    @Test(arguments: refusedPresses)
    func aShortcutWithoutCommandControlOrOptionIsRefusedAndTheWindowSaysWhy(
        code: Int, modifiers: NSEvent.ModifierFlags, characters: String?, text: String
    ) {
        let recorded = Rules.shortcut(keyCode: UInt32(code), modifiers: modifiers, characters: characters)
        #expect(recorded == .failure(.needsModifier(text)))
        let message = ShortcutProblem.needsModifier(text).message
        #expect(message.contains("⌘, ⌃ or ⌥"))
        #expect(message.contains("Shift alone isn't enough"))
        #expect(message.contains(text))
    }

    @Test(arguments: unnamedKeyPresses)
    func aKeyWithNoNameIsRefusedEvenWithModifiers(code: Int, characters: String?) {
        let recorded = Rules.shortcut(keyCode: UInt32(code), modifiers: [.control, .option, .command], characters: characters)
        #expect(recorded == .failure(.unnamedKey))
    }

    @Test func aShortcutMacOSWontRegisterIsNamedInTheWindow() {
        #expect(ShortcutProblem.inUse("⇧⌘K").message.hasPrefix("Another app may already be using ⇧⌘K."))
    }

    // MARK: Storage

    @Test(arguments: storedShortcuts)
    func aStoredShortcutReadsBackTheSame(shortcut: Shortcut) throws {
        let data = try #require(Rules.shortcutData(shortcut))
        #expect(Rules.shortcut(from: data) == shortcut)
    }

    @Test func aShortcutIsStoredAsSmallJSONWithItsKeyCodeCarbonModifiersAndKeyName() {
        let json = #"{"keyCode": 40, "modifiers": 768, "key": "K"}"#
        let expected = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey | cmdKey), key: "K")
        #expect(Rules.shortcut(from: Data(json.utf8)) == expected)
    }

    @Test func theDefaultIsStoredAsNothingSoAResetRemovesTheKey() {
        #expect(Rules.shortcutData(HotKey.standard) == nil)
        #expect(Rules.shortcut(from: nil) == HotKey.standard)
    }

    @Test(arguments: badStoredShortcuts)
    func missingUnreadableOrInvalidDataFallsBackToTheDefault(json: String) {
        #expect(Rules.shortcut(from: Data(json.utf8)) == HotKey.standard)
    }
}
