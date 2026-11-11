import AppKit
import Foundation
import Testing
@testable import PinOnTop

/// The repo's top folder, found from this file's own path.
private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// The version build.sh builds, from its one VERSION line.
private func buildVersion() throws -> String {
    let versions = try read("build.sh").matches(of: #/^VERSION="(\d+\.\d+\.\d+)"$/#.anchorsMatchLineEndings()).map { String($0.1) }
    #expect(versions.count == 1, "build.sh's VERSION lines: \(versions)")
    return try #require(versions.first)
}

private let projectPage = "https://github.com/Kurrt/pin-on-top"

/// The shortcut the way the docs write it, from the hot key itself: ⌃⌥⌘P and Control-Option-Command-P.
private func shortcut() -> (glyphs: String, words: String) {
    let modifiers: [(flag: NSEvent.ModifierFlags, glyph: String, word: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]
    let used = modifiers.filter { HotKey.menuModifiers.contains($0.flag) }
    let key = HotKey.menuKey.uppercased()
    return (used.map(\.glyph).joined() + key, (used.map(\.word) + [key]).joined(separator: "-"))
}

/// Checks that the docs keep the app's promises and agree with the code, in the spirit of the
/// other repos' docs and contract tests.
struct DocsTests {
    @Test func mainSwiftImportsOnlyAppleFrameworks() throws {
        let source = try read("Sources/main.swift")
        let imports = source.matches(of: #/^(?:@\w+\s+)*import\s+([\w.]+)/#.anchorsMatchLineEndings()).map { String($0.1) }
        let allowed: Set = [
            "AppKit", "ApplicationServices", "Carbon", "Carbon.HIToolbox", "CoreGraphics", "IOSurface",
            "ScreenCaptureKit", "ServiceManagement", "SwiftUI",
        ]
        #expect(!imports.isEmpty)
        #expect(Set(imports).subtracting(allowed).isEmpty, "unexpected imports: \(imports)")
    }

    // The README promises no networking code and that nothing leaves your Mac.
    @Test(arguments: [
        "URLSession", "URLRequest", "NSURLConnection", "NWConnection", "NWListener", "NWBrowser",
        "NWPathMonitor", "CFSocket", "CFStreamCreatePairWithSocket", "getaddrinfo", "socket(", "http://",
    ])
    func mainSwiftHasNoNetworkingCode(api: String) throws {
        let source = try read("Sources/main.swift")
        #expect(!source.contains(api))
    }

    @Test func everyLinkInMainSwiftIsASystemSettingsPaneOrTheProjectPage() throws {
        let source = try read("Sources/main.swift")
        let opened = source.matches(of: #/URL\(string:\s*"([^"]*)/#).map { String($0.1) }
        #expect(!opened.isEmpty)
        for url in opened {
            #expect(url.hasPrefix("x-apple.systempreferences:") || url == projectPage, "\(url)")
        }
        for match in source.matches(of: #/[A-Za-z][A-Za-z0-9+.\-]*://[^\s"\\)]*/#) {
            #expect(match.0 == projectPage, "\(match.0)")
        }
    }

    @Test func theOnlyPrivateCallIsAXUIElementGetWindowWhichTheDocsName() throws {
        let source = try read("Sources/main.swift")
        let names = source.matches(of: #/@_silgen_name\("([^"]+)"\)/#).map { String($0.1) }
        #expect(names == ["_AXUIElementGetWindow"])
        for path in ["README.md", "SECURITY.md"] {
            let text = try read(path)
            #expect(text.contains("`_AXUIElementGetWindow`"), "\(path)")
        }
    }

    @Test func theMinimumMacOSAgreesAcrossTheDocsAndTheBuilds() throws {
        let package = try read("Package.swift").matches(of: #/\.macOS\(\.v(\d+)\)/#).map { String($0.1) }
        #expect(package.count == 1)
        let minimum = try #require(package.first)

        let build = try read("build.sh")
        let targets = build.matches(of: #/-apple-macos(\d+)\.0/#).map { String($0.1) }
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0 == minimum }, "build.sh targets: \(targets)")
        let plist = build.matches(of: #/<key>LSMinimumSystemVersion</key>\s*<string>(\d+)\.0</string>/#).map { String($0.1) }
        #expect(plist == [minimum])

        let readme = try read("README.md").matches(of: #/macOS (\d+) \w+ or later/#).map { String($0.1) }
        #expect(!readme.isEmpty)
        #expect(readme.allSatisfy { $0 == minimum }, "README: \(readme)")
        let contributing = try read("CONTRIBUTING.md").matches(of: #/macOS (\d+) or newer/#).map { String($0.1) }
        #expect(contributing == [minimum])
    }

    @Test(arguments: ["README.md", "SECURITY.md"])
    func theDocsShortcutMatchesTheHotKey(path: String) throws {
        let text = try read(path)
        let (glyphs, _) = shortcut()
        #expect(text.contains(glyphs))
        // Any other shortcut written with two or more modifiers would be a stale one.
        for match in text.matches(of: #/[⌃⌥⇧⌘]{2,}[A-Z0-9]/#) {
            #expect(match.0 == glyphs, "\(path): \(match.0)")
        }
    }

    @Test func theReadmeSpellsTheShortcutOut() throws {
        let readme = try read("README.md")
        #expect(readme.contains(shortcut().words))
    }

    @Test func sourcesHoldsExactlyOneSwiftFile() throws {
        let files = try #require(FileManager.default.enumerator(atPath: root.appendingPathComponent("Sources").path))
        let swiftFiles = files.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        #expect(swiftFiles == ["main.swift"])
    }

    // The release workflow refuses a tag that isn't build.sh's version and takes its notes from
    // CHANGELOG.md's section for that version.
    @Test func theChangelogsNewestSectionIsTheVersionBuildShBuildsAndSaysWhatsInIt() throws {
        let version = try buildVersion()

        let changelog = try read("CHANGELOG.md")
        let sections = changelog.matches(of: #/^## (.+)$/#.anchorsMatchLineEndings()).map { String($0.1) }
        #expect(sections.first == version, "CHANGELOG.md's sections: \(sections)")
        let newest = try #require(changelog.components(separatedBy: "\n## ").dropFirst().first)
        #expect(newest.contains("\n- "), "the \(version) section has no list of changes")
    }

    @Test(arguments: ["CFBundleShortVersionString", "CFBundleVersion"])
    func buildShWritesItsVersionIntoTheApp(key: String) throws {
        let build = try read("build.sh")
        let values = build.matches(of: #/<key>(\w+)</key>\s*<string>([^<]*)</string>/#).filter { $0.1 == key }.map { String($0.2) }
        #expect(values == ["$VERSION"])
        // A quoted heredoc would write "$VERSION" itself.
        #expect(build.contains("<<PLIST\n"))
    }

    @Test func theIconTheBuildCopiesIsCommittedWithTheReadmesCopy() throws {
        let build = try read("build.sh")
        #expect(build.contains("cp Resources/AppIcon.icns "))
        #expect(build.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))

        let icns = try Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        #expect(icns.prefix(4) == Data("icns".utf8))
        // ic10 is the 1024 px image, the largest an .icns holds.
        #expect(icns.range(of: Data("ic10".utf8)) != nil)

        let png = try Data(contentsOf: root.appendingPathComponent("docs/icon.png"))
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // The width and height, big-endian, open the header chunk at byte 16.
        let size = [16, 20].map { start in png.dropFirst(start).prefix(4).reduce(0) { $0 << 8 | Int($1) } }
        #expect(size == [512, 512])
    }

    // The README's install steps name the download, so a release has to update them too.
    @Test func theDownloadTheReadmeNamesIsTheVersionBuildShBuilds() throws {
        let version = try buildVersion()
        let named = try read("README.md").matches(of: #/Pin-on-Top-(\d+\.\d+\.\d+)\.zip/#).map { String($0.1) }
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { $0 == version }, "README names \(named), build.sh builds \(version)")
    }

    // SECURITY.md lists what the app keeps in its preferences, so a new key needs a line there.
    @Test func securityNamesEveryPreferenceTheAppKeeps() throws {
        let source = try read("Sources/main.swift")
        let declared = source.matches(of: #/static let (\w+Key) = "(\w+)"/#).map { (String($0.1), String($0.2)) }
        let keys = Dictionary(declared) { first, _ in first }
        let used = source.matches(of: #/forKey:\s*([^)]*)\)/#).map { String($0.1) }
        #expect(!used.isEmpty)
        let security = try read("SECURITY.md")
        for key in used {
            // Each key is a named constant, so the test can find what's stored under it.
            let name = try #require(key.hasPrefix("Self.") ? keys[String(key.dropFirst(5))] : nil, "\(key)")
            #expect(security.contains("`\(name)`"), "SECURITY.md doesn't name \(name)")
        }
    }

    // The commands that clear the app's preferences or permissions have to name its bundle ID.
    @Test(arguments: ["README.md", "SECURITY.md", "CONTRIBUTING.md"])
    func theDocsCommandsNameTheAppsBundleID(path: String) throws {
        let bundleIDs = try read("build.sh").matches(of: #/<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>/#).map { String($0.1) }
        #expect(bundleIDs.count == 1)
        let bundleID = try #require(bundleIDs.first)
        let named = try read(path).matches(of: #/(?:defaults delete|tccutil reset \w+) ([\w.-]+)/#).map { String($0.1) }
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { $0 == bundleID }, "\(path): \(named)")
    }

    @Test func theReadmeLinksMainSwiftAndItsLineCountIsWithinATenth() throws {
        let lines = try read("Sources/main.swift").filter { $0 == "\n" }.count
        let claimed = try read("README.md").matches(of: #/\[a single Swift file\]\(Sources/main\.swift\) \(about (\d+) lines\)/#).compactMap { Int($0.1) }
        #expect(claimed.count == 1)
        for count in claimed {
            #expect(abs(count - lines) * 10 <= lines, "README says about \(count) lines, main.swift has \(lines)")
        }
    }
}
