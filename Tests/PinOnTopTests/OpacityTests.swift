import CoreGraphics
import Testing
@testable import PinOnTop

struct OpacityTests {
    @Test func theStepsStartFullyOpaqueAndGetLighter() {
        #expect(Rules.opacitySteps.first == 100)
        #expect(Rules.opacitySteps == Rules.opacitySteps.sorted(by: >))
    }

    // Choosing a step sets the panel's alpha to the step over 100, so it must read back the same.
    @Test(arguments: Rules.opacitySteps)
    func eachStepIsTickedWhenThePanelIsAtThatOpacity(percent: Int) {
        #expect(Rules.opacityStep(for: CGFloat(percent) / 100) == percent)
    }

    @Test(arguments: [(alpha: CGFloat(0.8500001), percent: 85), (alpha: CGFloat(0.699999), percent: 70)])
    func anAlphaAHairOffAStepStillMatchesIt(alpha: CGFloat, percent: Int) {
        #expect(Rules.opacityStep(for: alpha) == percent)
    }
}
