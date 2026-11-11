import CoreGraphics
import Testing
@testable import PinOnTop

/// The pinned window is window 10 of the app with pid 7. Window 11 is another of its windows,
/// and pid 99 is another app.
private func shows(
    hasFrame: Bool = true, frontmostPID: pid_t? = 99, accessibility: Bool = true,
    focusedWindowID: CGWindowID? = nil, appHidden: Bool = false, minimised: Bool = false
) -> Bool {
    Rules.mirrorShows(
        hasFrame: hasFrame, windowID: 10, pid: 7, frontmostPID: frontmostPID, accessibility: accessibility,
        focusedWindowID: focusedWindowID, appHidden: appHidden, minimised: minimised)
}

struct VisibilityTests {
    @Test func noMirrorBeforeTheFirstFrameArrives() {
        #expect(!shows(hasFrame: false))
    }

    @Test func theMirrorShowsWhileAnotherAppIsInFront() {
        #expect(shows())
    }

    @Test func theMirrorShowsWhenNoAppIsInFront() {
        #expect(shows(frontmostPID: nil))
    }

    @Test func theMirrorHidesWhileItsOwnWindowIsFocused() {
        #expect(!shows(frontmostPID: 7, focusedWindowID: 10))
    }

    @Test func theMirrorShowsWhileAnotherWindowOfTheSameAppIsFocused() {
        #expect(shows(frontmostPID: 7, focusedWindowID: 11))
    }

    @Test func withFocusUnknownTheMirrorHidesWhileItsAppIsInFront() {
        #expect(!shows(frontmostPID: 7, focusedWindowID: nil))
    }

    @Test func withoutAccessibilityTheMirrorHidesWheneverItsAppIsInFront() {
        #expect(!shows(frontmostPID: 7, accessibility: false, focusedWindowID: 11))
    }

    @Test func theMirrorHidesWhileItsAppIsHidden() {
        #expect(!shows(appHidden: true))
    }

    @Test func theMirrorHidesWhileItsWindowIsMinimised() {
        #expect(!shows(minimised: true))
    }

    // Without Accessibility the app can't tell that a window is minimised.
    @Test func withoutAccessibilityAMinimisedWindowsMirrorStaysUp() {
        #expect(shows(accessibility: false, minimised: true))
    }

    // These run every 0.15 seconds for each pin, so the Accessibility calls are only made
    // when the answer depends on them.
    @Test func focusIsOnlyAskedForWhileTheWindowsAppIsInFrontWithAccessibility() {
        var asked: [pid_t?] = []
        func focus(_ frontmost: pid_t?) -> CGWindowID? {
            asked.append(frontmost)
            return nil
        }
        for frontmost: pid_t? in [99, nil, 7] {
            _ = Rules.mirrorShows(
                hasFrame: true, windowID: 10, pid: 7, frontmostPID: frontmost, accessibility: true,
                focusedWindowID: focus(frontmost), appHidden: false, minimised: false)
        }
        _ = Rules.mirrorShows(
            hasFrame: true, windowID: 10, pid: 7, frontmostPID: 7, accessibility: false,
            focusedWindowID: focus(-1), appHidden: false, minimised: false)
        #expect(asked == [7])
    }

    @Test(arguments: [
        (hasFrame: false, frontmostPID: pid_t(99), accessibility: true, appHidden: false),
        (hasFrame: true, frontmostPID: pid_t(7), accessibility: true, appHidden: false),
        (hasFrame: true, frontmostPID: pid_t(99), accessibility: true, appHidden: true),
        (hasFrame: true, frontmostPID: pid_t(99), accessibility: false, appHidden: false),
    ])
    func minimisingIsNotAskedAboutWhenTheAnswerIsAlreadyKnown(
        hasFrame: Bool, frontmostPID: pid_t, accessibility: Bool, appHidden: Bool
    ) {
        var asked = false
        func minimised() -> Bool {
            asked = true
            return false
        }
        _ = Rules.mirrorShows(
            hasFrame: hasFrame, windowID: 10, pid: 7, frontmostPID: frontmostPID, accessibility: accessibility,
            focusedWindowID: 10, appHidden: appHidden, minimised: minimised())
        #expect(!asked)
    }
}
