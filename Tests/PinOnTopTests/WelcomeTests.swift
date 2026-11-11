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
}
