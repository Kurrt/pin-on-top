import Testing
@testable import PinOnTop

private let changes: [(isShown: Bool, shouldShow: Bool, fade: MirrorFade?)] = [
    (false, true, .fadeIn),
    (true, false, .fadeOut),
    (true, true, nil),
    (false, false, nil),
]

struct FadeTests {
    @Test(arguments: changes)
    func aMirrorFadesOnlyWhenItStartsOrStopsShowingNotOnEveryRefresh(isShown: Bool, shouldShow: Bool, fade: MirrorFade?) {
        #expect(Rules.mirrorFade(isShown: isShown, shouldShow: shouldShow) == fade)
    }

    @Test func fadingOutIsQuickerThanFadingInAndBothAreShort() {
        #expect(MirrorFade.fadeOut.duration < MirrorFade.fadeIn.duration)
        #expect(MirrorFade.fadeIn.duration <= 0.2)
    }
}
