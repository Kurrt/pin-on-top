import AppKit
import Testing
@testable import PinOnTop

struct WelcomeTests {
    @Test(arguments: [
        (hasSeenWelcome: false, screenRecording: true, accessibility: true, shows: true),
        (hasSeenWelcome: true, screenRecording: false, accessibility: true, shows: true),
        (hasSeenWelcome: true, screenRecording: true, accessibility: false, shows: true),
        (hasSeenWelcome: false, screenRecording: false, accessibility: false, shows: true),
        (hasSeenWelcome: true, screenRecording: true, accessibility: true, shows: false),
    ])
    func theWelcomeWindowOpensAtLaunchTheFirstTimeAndWhileAPermissionIsMissing(
        hasSeenWelcome: Bool, screenRecording: Bool, accessibility: Bool, shows: Bool
    ) {
        let opens = Rules.showsWelcome(
            hasSeenWelcome: hasSeenWelcome, screenRecording: screenRecording, accessibility: accessibility)
        #expect(opens == shows)
    }

    @Test(arguments: [
        (atLaunch: false, now: true, offered: true),
        (atLaunch: false, now: false, offered: false),
        (atLaunch: true, now: true, offered: false),
        (atLaunch: true, now: false, offered: false),
    ])
    func quitAndReopenIsOfferedOnlyOnceScreenRecordingIsGrantedAfterLaunch(atLaunch: Bool, now: Bool, offered: Bool) {
        #expect(Rules.needsRelaunch(screenRecordingAtLaunch: atLaunch, screenRecordingNow: now) == offered)
    }

    // The first tip says the shortcut, so the welcome window doesn't say it twice.
    @Test(arguments: [HotKey.standard.text, "⇧⌘K", "⌥F5", "⌃⌥⇧⌘Space"])
    func theFirstTipNamesTheShortcutItsGivenAndNoOtherTipDoes(shortcutText: String) {
        let tips = Tip.allCases.map { $0.text(shortcutText: shortcutText) }
        #expect(tips.first?.contains(shortcutText) == true)
        #expect(tips.dropFirst().allSatisfy { !$0.contains(shortcutText) })
    }

    @Test(arguments: [
        (tip: Tip.options, word: MenuWords.pinned),
        (tip: Tip.options, word: MenuWords.opacity),
        (tip: Tip.options, word: MenuWords.unpin),
        (tip: Tip.alwaysPin, word: MenuWords.alwaysPin),
    ])
    func theTipsNameTheOptionsWithTheWordsTheMenusUse(tip: Tip, word: String) {
        #expect(tip.text(shortcutText: HotKey.standard.text).contains(word))
    }

    @Test(arguments: Tip.allCases)
    func everyTipsSymbolIsAnSFSymbol(tip: Tip) {
        #expect(NSImage(systemSymbolName: tip.symbol, accessibilityDescription: nil) != nil)
    }
}
