import CoreGraphics
import Foundation
import Testing
@testable import PinOnTop

/// One entry shaped the way CGWindowListCopyWindowInfo gives it: NSNumber values and the
/// bounds as a dictionary, so the casts in WindowInfo are tested for real.
private func entry(
    number: Int? = 42, pid: Int? = 7, owner: String? = "Notes", title: String? = nil,
    bounds: CGRect? = CGRect(x: 10, y: 20, width: 300, height: 200), layer: Int? = 0
) -> [String: Any] {
    var dict: [String: Any] = [:]
    if let number { dict[kCGWindowNumber as String] = NSNumber(value: number) }
    if let pid { dict[kCGWindowOwnerPID as String] = NSNumber(value: pid) }
    if let owner { dict[kCGWindowOwnerName as String] = owner }
    if let title { dict[kCGWindowName as String] = title }
    if let bounds { dict[kCGWindowBounds as String] = bounds.dictionaryRepresentation }
    if let layer { dict[kCGWindowLayer as String] = NSNumber(value: layer) }
    return dict
}

private func window(id: CGWindowID, pid: pid_t = 7, width: CGFloat = 300, height: CGFloat = 200, layer: Int = 0) -> WindowInfo {
    WindowInfo(id: id, pid: pid, appName: "Notes", title: "", bounds: CGRect(x: 0, y: 0, width: width, height: height), layer: layer)
}

struct WindowListTests {
    @Test func aWindowEntryFromTheWindowListParses() throws {
        let window = try #require(WindowInfo(entry(title: "Shopping", layer: 3)))
        #expect(window.id == 42)
        #expect(window.pid == 7)
        #expect(window.appName == "Notes")
        #expect(window.title == "Shopping")
        #expect(window.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(window.layer == 3)
    }

    @Test(arguments: [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowBounds].map { $0 as String })
    func anEntryWithoutANumberOwnerOrBoundsIsSkipped(missing key: String) {
        var dict = entry()
        dict[key] = nil
        #expect(WindowInfo(dict) == nil)
    }

    @Test func boundsThatAreNotARectAreSkipped() {
        var dict = entry()
        dict[kCGWindowBounds as String] = "10, 20, 300, 200"
        #expect(WindowInfo(dict) == nil)
    }

    @Test func aMissingOwnerNameTitleOrLayerBecomesUnknownEmptyOrZero() throws {
        let window = try #require(WindowInfo(entry(owner: nil, title: nil, layer: nil)))
        #expect(window.appName == "Unknown")
        #expect(window.title == "")
        #expect(window.layer == 0)
    }

    @Test func aWindowWithNoTitleIsLabelledWithItsAppName() throws {
        let window = try #require(WindowInfo(entry()))
        #expect(window.label == "Notes")
    }

    @Test func aWindowWithATitleIsLabelledWithItsAppNameAndTitle() throws {
        let window = try #require(WindowInfo(entry(title: "Shopping")))
        #expect(window.label == "Notes – Shopping")
    }

    @Test func aLabelOver70CharactersIsCutTo69PlusAnEllipsis() throws {
        let window = try #require(WindowInfo(entry(title: String(repeating: "a", count: 64))))
        #expect(window.label == "Notes – \(String(repeating: "a", count: 61))…")
        #expect(window.label.count == 70)
    }

    @Test func aLabelOfExactly70CharactersIsKept() throws {
        let title = String(repeating: "a", count: 62)
        let window = try #require(WindowInfo(entry(title: title)))
        #expect(window.label == "Notes – \(title)")
        #expect(window.label.count == 70)
    }

    // Accented letters written both ways, an emoji with a skin tone, a family and a flag.
    @Test(arguments: ["é", "e\u{301}", "👍🏽", "👨‍👩‍👧", "🇦🇺"])
    func aLongTitleIsCutOnWholeCharactersNeverMidCharacter(character: String) throws {
        let window = try #require(WindowInfo(entry(title: String(repeating: character, count: 100))))
        // "Notes – " is 8 characters, so 61 whole copies fit before the ellipsis.
        #expect(window.label.count == 70)
        #expect(window.label.hasSuffix("\(character)…"))
        let expectedScalars = "Notes – ".unicodeScalars.count + 61 * character.unicodeScalars.count + 1
        #expect(window.label.unicodeScalars.count == expectedScalars)
    }

    @Test(arguments: [
        (layer: 0, pid: pid_t(7), width: CGFloat(80), height: CGFloat(60), pinnable: true),
        (layer: 0, pid: pid_t(7), width: CGFloat(79), height: CGFloat(600), pinnable: false),
        (layer: 0, pid: pid_t(7), width: CGFloat(800), height: CGFloat(59), pinnable: false),
        (layer: 25, pid: pid_t(7), width: CGFloat(800), height: CGFloat(600), pinnable: false),
        (layer: 0, pid: pid_t(1), width: CGFloat(800), height: CGFloat(600), pinnable: false),
    ])
    func onlyNormalWindowsOfOtherAppsAtLeast80By60CanBePinned(
        layer: Int, pid: pid_t, width: CGFloat, height: CGFloat, pinnable: Bool
    ) {
        let candidate = window(id: 1, pid: pid, width: width, height: height, layer: layer)
        // Pin on Top's own process is pid 1 here.
        #expect(Rules.pinnable([candidate], excluding: 1).isEmpty == !pinnable)
    }

    @Test func thePinnableListKeepsFrontToBackOrder() {
        let windows = [window(id: 3), window(id: 1, width: 20), window(id: 2), window(id: 5)]
        #expect(Rules.pinnable(windows, excluding: 1).map(\.id) == [3, 2, 5])
    }
}
