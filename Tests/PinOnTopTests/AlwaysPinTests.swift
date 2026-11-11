import Foundation
import Testing
@testable import PinOnTop

private let notes = AlwaysPinRule(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Shopping")
private let safari = AlwaysPinRule(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Start Page")

struct AlwaysPinTests {
    @Test func rememberedAppsComeBackTheSameFromStorage() throws {
        let data = try #require(Rules.alwaysPinData([notes, safari]))
        #expect(Rules.alwaysPinRules(from: data) == [notes, safari])
    }

    @Test func anEmptyListComesBackEmptyFromStorage() throws {
        let data = try #require(Rules.alwaysPinData([]))
        #expect(Rules.alwaysPinRules(from: data).isEmpty)
    }

    @Test func nothingStoredMeansNoRememberedApps() {
        #expect(Rules.alwaysPinRules(from: nil).isEmpty)
    }

    // Records are stored as JSON with these field names, so a later build must still read them.
    @Test func aRecordWithTheStoredFieldNamesLoads() {
        let json = #"[{"bundleID": "com.apple.Notes", "appName": "Notes", "windowTitle": "Shopping"}]"#
        #expect(Rules.alwaysPinRules(from: Data(json.utf8)) == [notes])
    }

    @Test(arguments: [
        "",
        "not json",
        "null",
        "{}",
        #"{"bundleID": "com.apple.Notes", "appName": "Notes", "windowTitle": "Shopping"}"#,
        #"[{"bundleID": "com.apple.Notes"}]"#,
        #"[{"bundleID": 7, "appName": "Notes", "windowTitle": "Shopping"}]"#,
        #"[{"bundleID": "com.apple.Notes", "appName": "Notes", "windowTitle": "Shopping"}, 3]"#,
    ])
    func badDataMeansNoRememberedApps(json: String) {
        #expect(Rules.alwaysPinRules(from: Data(json.utf8)).isEmpty)
    }

    @Test func aBundleIDStoredTwiceKeepsOnlyItsFirstRecord() throws {
        let older = AlwaysPinRule(bundleID: notes.bundleID, appName: "Notes", windowTitle: "Recipes")
        let data = try #require(Rules.alwaysPinData([notes, safari, older]))
        #expect(Rules.alwaysPinRules(from: data) == [notes, safari])
    }

    @Test func rememberingAnAppAddsItToTheEnd() {
        #expect(Rules.adding(safari, to: [notes]) == [notes, safari])
    }

    @Test func rememberingAnAppAgainReplacesItsRecordWhereItIs() {
        let again = AlwaysPinRule(bundleID: notes.bundleID, appName: "Notes", windowTitle: "Recipes")
        #expect(Rules.adding(again, to: [notes, safari]) == [again, safari])
    }

    @Test func forgettingAnAppRemovesOnlyThatApp() {
        #expect(Rules.removing(bundleID: notes.bundleID, from: [notes, safari]) == [safari])
    }

    @Test func forgettingAnAppThatIsNotRememberedChangesNothing() {
        #expect(Rules.removing(bundleID: "com.example.Other", from: [notes, safari]) == [notes, safari])
    }

    @Test func pinningAWindowUpdatesOnlyThatAppsTitle() {
        let updated = Rules.updatingTitle("Recipes", bundleID: notes.bundleID, in: [notes, safari])
        #expect(updated == [AlwaysPinRule(bundleID: notes.bundleID, appName: "Notes", windowTitle: "Recipes"), safari])
    }

    @Test func aTitleForAnAppThatIsNotRememberedChangesNothing() {
        #expect(Rules.updatingTitle("Recipes", bundleID: "com.example.Other", in: [notes, safari]) == [notes, safari])
    }
}
