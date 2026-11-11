import CoreGraphics
import Foundation
import Testing
@testable import PinOnTop

private let notes = AlwaysPinRule(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Shopping")

private func window(id: CGWindowID, title: String = "") -> WindowInfo {
    WindowInfo(id: id, pid: 7, appName: "Notes", title: title, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), layer: 0)
}

/// The window Always Pin picks from Notes' windows, front to back: 1 "Recipes", 2 untitled, 3 "Shopping".
private func pick(
    title: String = notes.windowTitle, appHasPin: Bool = false, suppressed: Bool = false, failed: Set<CGWindowID> = []
) -> CGWindowID? {
    let rule = AlwaysPinRule(bundleID: notes.bundleID, appName: notes.appName, windowTitle: title)
    let candidates = [window(id: 1, title: "Recipes"), window(id: 2), window(id: 3, title: "Shopping")]
    return Rules.autoPinTarget(
        for: rule, candidates: candidates, appHasPin: appHasPin, suppressed: suppressed, recentlyFailed: failed)?.id
}

private let recentFailures: [(failed: Set<CGWindowID>, picked: CGWindowID?)] = [
    ([3], 1),
    ([1], 3),
    ([1, 3], 2),
    ([1, 2, 3], nil),
]

private let liftingChanges: [SuppressionChange] = [.pinnedByHand(7), .alwaysPinSwitched(7), .appQuit(7)]

struct AutoPinTests {
    @Test func theWindowWithTheRememberedTitleWinsOverTheFrontmostOne() {
        #expect(pick() == 3)
    }

    @Test func withoutATitleMatchItPicksTheFrontmostWindow() {
        #expect(pick(title: "Packing") == 1)
    }

    @Test func anEmptyRememberedTitlePicksTheFrontmostWindowNotAnUntitledOne() {
        #expect(pick(title: "") == 1)
    }

    @Test func nothingIsPinnedWhileOneOfTheAppsWindowsIsPinned() {
        #expect(pick(appHasPin: true) == nil)
    }

    @Test func nothingIsPinnedWhileTheAppIsSuppressed() {
        #expect(pick(suppressed: true) == nil)
    }

    @Test func nothingIsPinnedWhenTheAppHasNoWindowsToPin() {
        #expect(Rules.autoPinTarget(for: notes, candidates: [], appHasPin: false, suppressed: false, recentlyFailed: []) == nil)
    }

    @Test(arguments: recentFailures)
    func aWindowThatFailedRecentlyIsSkippedForTheNextOne(failed: Set<CGWindowID>, picked: CGWindowID?) {
        #expect(pick(failed: failed) == picked)
    }

    @Test(arguments: [
        (age: TimeInterval(0), kept: true),
        (age: TimeInterval(4.9), kept: true),
        (age: TimeInterval(5), kept: false),
        (age: TimeInterval(60), kept: false),
    ])
    func aWindowThatFailedToPinIsLeftAloneForFiveSeconds(age: TimeInterval, kept: Bool) {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let failures: [CGWindowID: Date] = [9: now.addingTimeInterval(-age)]
        #expect(Rules.recentFailures(failures, now: now).keys.contains(9) == kept)
    }

    @Test func unpinningARememberedAppsWindowByHandSuppressesThatApp() {
        #expect(Rules.suppressed([3], after: .unpinnedByHand(7, remembered: true)) == [3, 7])
    }

    @Test func unpinningAWindowOfAnAppThatIsNotRememberedSuppressesNothing() {
        #expect(Rules.suppressed([3], after: .unpinnedByHand(7, remembered: false)) == [3])
    }

    @Test(arguments: liftingChanges)
    func pinningByHandSwitchingAlwaysPinOrQuittingLiftsOnlyThatApp(change: SuppressionChange) {
        #expect(Rules.suppressed([3, 7], after: change) == [3])
    }

    @Test(arguments: liftingChanges)
    func liftingAnAppThatIsNotSuppressedChangesNothing(change: SuppressionChange) {
        #expect(Rules.suppressed([3], after: change) == [3])
    }
}
