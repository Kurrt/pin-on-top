import CoreGraphics
import Testing
@testable import PinOnTop

/// A 1920x1080 main display. CoreGraphics measures down from its top left corner and AppKit
/// measures up from its bottom left corner.
private let mainHeight: CGFloat = 1080

private func appKit(_ rect: CGRect) -> CGRect {
    Rules.appKitFrame(fromCG: rect, primaryHeight: mainHeight)
}

struct GeometryTests {
    @Test func aWindowAtTheTopLeftOfTheMainDisplayEndsUpAtTheTopOfAppKitsMainDisplay() {
        #expect(appKit(CGRect(x: 0, y: 0, width: 800, height: 600)) == CGRect(x: 0, y: 480, width: 800, height: 600))
    }

    @Test func aWindowOnADisplayToTheRightKeepsItsX() {
        #expect(appKit(CGRect(x: 2000, y: 100, width: 800, height: 600)) == CGRect(x: 2000, y: 380, width: 800, height: 600))
    }

    @Test func aWindowOnADisplayAboveTheMainOneGetsAnAppKitYAboveTheMainDisplay() {
        let frame = appKit(CGRect(x: 100, y: -900, width: 800, height: 600))
        #expect(frame == CGRect(x: 100, y: 1380, width: 800, height: 600))
        #expect(frame.minY > mainHeight)
    }

    @Test func aWindowOnADisplayBelowTheMainOneGetsANegativeAppKitY() {
        let frame = appKit(CGRect(x: 100, y: 1200, width: 800, height: 600))
        #expect(frame == CGRect(x: 100, y: -720, width: 800, height: 600))
    }

    @Test func aWindowOnADisplayToTheLeftKeepsItsNegativeX() {
        #expect(appKit(CGRect(x: -1440, y: 50, width: 800, height: 600)) == CGRect(x: -1440, y: 430, width: 800, height: 600))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 800, height: 600),
        CGRect(x: 2000, y: 100, width: 1024, height: 768),
        CGRect(x: -1440, y: -900, width: 640, height: 480),
        CGRect(x: 12.5, y: 33.25, width: 101.5, height: 99.75),
    ])
    func convertingTwiceGivesTheOriginalRectBack(rect: CGRect) {
        #expect(appKit(appKit(rect)) == rect)
    }
}
