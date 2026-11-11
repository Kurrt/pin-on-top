import Testing
@testable import PinOnTop

struct MenuTests {
    @Test func aLongAppNameIsCutTo69CharactersAndAnEllipsisLikeAWindowLabel() {
        let name = String(repeating: "a", count: 80)
        #expect(Rules.menuTitle(name) == "\(String(repeating: "a", count: 69))…")
    }

    @Test(arguments: ["Notes", String(repeating: "a", count: 70)])
    func aTitleOf70CharactersOrFewerIsKept(title: String) {
        #expect(Rules.menuTitle(title) == title)
    }
}
