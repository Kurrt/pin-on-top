import CoreGraphics
import Testing
@testable import PinOnTop

struct CaptureSizeTests {
    @Test func aRetinaWindowCapturesAtTwiceItsPointSize() {
        let size = Rules.captureSize(points: CGSize(width: 800, height: 600), scale: 2)
        #expect(size == (width: 1600, height: 1200))
    }

    @Test func aNonRetinaWindowCapturesAtItsPointSize() {
        let size = Rules.captureSize(points: CGSize(width: 800, height: 600), scale: 1)
        #expect(size == (width: 800, height: 600))
    }

    @Test(arguments: [
        (points: CGSize(width: 100.25, height: 50.2), width: 201, height: 100),
        (points: CGSize(width: 100.2, height: 50.25), width: 200, height: 101),
    ])
    func halfPixelSizesRoundToTheNearestPixel(points: CGSize, width: Int, height: Int) {
        let size = Rules.captureSize(points: points, scale: 2)
        #expect(size == (width: width, height: height))
    }

    // ScreenCaptureKit refuses a width or height of 0.
    @Test(arguments: [CGSize.zero, CGSize(width: 0.2, height: 0.2), CGSize(width: 500, height: 0)])
    func aZeroOrTinyWindowStillAsksForAtLeastOnePixelEachWay(points: CGSize) {
        let size = Rules.captureSize(points: points, scale: 1)
        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }
}
