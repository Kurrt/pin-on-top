import AppKit
import SwiftUI
import Testing
@testable import PinOnTop

// Draws the README's screenshots into docs/screenshots: the app's own welcome and Change Shortcut
// views, and mock-ups of a desktop and the menu bar menu. Every app, window and word in them is
// made up. Nothing is captured from the screen: each view draws itself into a bitmap, in a window
// that's never shown. (SwiftUI's ImageRenderer can't do this, as it leaves out the views AppKit
// draws, such as the welcome window's GroupBoxes.) It only runs when asked, so ./test.sh and CI
// skip it:
//
//   PIN_ON_TOP_SCREENSHOTS=1 ./test.sh --filter ScreenshotTests

/// The repo's top folder, found from this file's own path.
private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PIN_ON_TOP_SCREENSHOTS"] == "1"))
@MainActor
struct ScreenshotTests {
    @Test func drawsATimerPinnedOnTopOfABigRecipesWindow() throws {
        try save(Desktop(), as: "pinned.png")
    }

    @Test func drawsTheMenuBarMenuWithTheTimersOptionsOpen() throws {
        try expectTheMenusOwnWords()
        try save(MenuBarMenu(version: buildVersion()).canvas(), as: "menu.png")
    }

    @Test func drawsTheWelcomeWindowWithBothPermissionsGranted() throws {
        let model = WelcomeModel(
            screenRecordingAtLaunch: true, currentShortcut: { HotKey.standard }, isGranted: { _ in true })
        // The README's copy of the icon, drawn by the same code as the app's.
        let icon = try #require(NSImage(contentsOf: root.appendingPathComponent("docs/icon.png")))
        let view = WelcomeView(model: model, icon: icon, grant: { _ in }, relaunch: {}, showChangeShortcut: {}, done: {})
        try save(AppWindow(titlebar: .transparent) { view }.canvas(), as: "welcome.png")
    }

    @Test func drawsTheChangeShortcutWindowShowingTheDefaultShortcut() throws {
        let model = ShortcutModel(shortcut: HotKey.standard)
        let view = ShortcutView(model: model, record: {}, cancel: {}, reset: {}, done: {})
        try save(AppWindow(titlebar: .titled("Change Shortcut")) { view }.canvas(), as: "shortcut.png")
    }
}

// MARK: - Drawing

/// Never shown. It says it's key, so the default button is drawn the way the app's windows draw it
/// (SwiftUI also needs telling, below).
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Draws a view at 2x in light mode, with the default blue accent whatever this Mac uses, and
/// writes it to docs/screenshots as a PNG.
@MainActor
private func save(_ view: some View, as name: String) throws {
    // The argument domain wins over this Mac's own setting, as a launch argument would. 4 is blue.
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleAccentColor"] = 4
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).environment(\.controlActiveState, .key))
    let fitting = host.fittingSize
    host.frame = NSRect(x: 0, y: 0, width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
    let window = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    let size = host.bounds.size
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)?.retagging(with: .sRGB))
    bitmap.size = size
    host.cacheDisplay(in: host.bounds, to: bitmap)

    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = root.appendingPathComponent("docs/screenshots/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
}

/// The version build.sh builds, which the menu's header shows.
private func buildVersion() throws -> String {
    let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
    let versions = build.matches(of: #/^VERSION="(\d+\.\d+\.\d+)"$/#.anchorsMatchLineEndings()).map { String($0.1) }
    return try #require(versions.first)
}

/// The menu mock-up writes some titles and symbols out, since the app builds them in place rather
/// than from constants. This stops the screenshot showing words the menu no longer uses.
@MainActor
private func expectTheMenusOwnWords() throws {
    let source = try String(contentsOf: root.appendingPathComponent("Sources/main.swift"), encoding: .utf8)
    for title in MenuBarMenu.writtenTitles {
        #expect(source.contains("withTitle: \"\(title)\""), "main.swift has no \(title) item")
    }
    for symbol in MenuBarMenu.writtenSymbols {
        #expect(source.contains("symbol(\"\(symbol)\")"), "main.swift's menu has no \(symbol) symbol")
    }
    #expect(source.contains("sectionHeader(title: \"\(MenuBarMenu.pinAWindow)\")"))
    #expect(source.contains("\"Pin on Top \\(version)\""), "the menu's header isn't Pin on Top and the version")
    #expect(source.contains("\"\\(MenuWords.alwaysPin) “\\(Rules.menuTitle(appName))”\""))
    #expect(source.contains("window.title = \"Change Shortcut\""))
}

// MARK: - Made-up apps

/// A made-up app: its name, and an icon that's an SF Symbol on a tinted rounded square.
private struct MockApp {
    let name: String
    let symbol: String
    let tint: Color

    static let timer = MockApp(name: "Timer", symbol: "timer", tint: Color(red: 0.98, green: 0.55, blue: 0.16))
    static let recipes = MockApp(name: "Recipes", symbol: "fork.knife", tint: Color(red: 0.30, green: 0.70, blue: 0.36))
    static let packingList = MockApp(name: "Packing List", symbol: "checklist", tint: Color(red: 0.20, green: 0.55, blue: 0.95))
    static let readingLog = MockApp(name: "Reading Log", symbol: "book.closed", tint: Color(red: 0.55, green: 0.38, blue: 0.86))
}

private struct AppIcon: View {
    let app: MockApp
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(app.tint.gradient)
            .overlay {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

// MARK: - Windows

private enum Colours {
    static let window = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color.black.opacity(0.045)
    static let highlight = Color(nsColor: .selectedContentBackgroundColor)
    static let accent = Color(nsColor: .controlAccentColor)
}

/// The close, minimise and zoom buttons. A window that can only close greys out the other two, and
/// an inactive window greys out all three.
private struct WindowButtons: View {
    enum Style { case active, closeOnly, inactive }
    let style: Style

    var body: some View {
        HStack(spacing: 8) {
            button(Color(red: 1, green: 0.37, blue: 0.34), edge: Color(red: 0.89, green: 0.27, blue: 0.25), on: style != .inactive)
            button(Color(red: 1, green: 0.74, blue: 0.18), edge: Color(red: 0.88, green: 0.63, blue: 0.09), on: style == .active)
            button(Color(red: 0.16, green: 0.78, blue: 0.25), edge: Color(red: 0.10, green: 0.67, blue: 0.16), on: style == .active)
        }
    }

    private func button(_ fill: Color, edge: Color, on: Bool) -> some View {
        Circle()
            .fill(on ? fill : Color.black.opacity(0.11))
            .overlay(Circle().strokeBorder(on ? edge : Color.black.opacity(0.06), lineWidth: 0.5))
            .frame(width: 12, height: 12)
    }
}

/// A window's rounded corners, hairline edge and shadow. An inactive window's shadow is smaller.
private struct WindowFrame: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .background(Colours.window)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 1)
            .shadow(color: .black.opacity(active ? 0.3 : 0.22), radius: active ? 24 : 14, y: active ? 14 : 8)
    }
}

extension View {
    fileprivate func windowFrame(active: Bool = true) -> some View {
        modifier(WindowFrame(active: active))
    }

    /// Room around a window or menu for its shadow, on a transparent background.
    fileprivate func canvas() -> some View {
        padding(EdgeInsets(top: 28, leading: 40, bottom: 52, trailing: 40))
    }
}

/// One of the app's windows around its real view: a 28 pt title bar with the window buttons, the
/// way the app's window controllers set it up. Both windows can only close.
private struct AppWindow<Content: View>: View {
    enum Titlebar {
        /// Like the welcome window: no title, and the view runs up under the buttons.
        case transparent
        case titled(String)
    }

    let titlebar: Titlebar
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if case let .titled(title) = titlebar {
                    Text(title).font(.system(size: 13, weight: .bold))
                }
                HStack {
                    WindowButtons(style: .closeOnly)
                    Spacer()
                }
                .padding(.leading, 8)
            }
            .frame(height: 28)
            content
        }
        .windowFrame()
    }
}

// MARK: - The desktop

/// A made-up desktop: a soft wallpaper, a thin menu bar, a big Recipes window in use and a small
/// Timer window pinned on top of it, with the pointer over it so the pin badge shows.
private struct Desktop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBar()
            RecipesWindow().offset(x: 80, y: 100)
            TimerWindow().offset(x: 592, y: 146)
            Pointer().offset(x: 806, y: 200)
        }
        .frame(width: 900, height: 560)
        .clipped()
    }
}

/// A soft gradient from top to bottom, drawn a row of pixels at a time in solid colours. A gradient
/// view is dithered, and the noise makes the PNG twice the size.
private struct Wallpaper: View {
    private let stops: [(red: Double, green: Double, blue: Double)] = [
        (0.99, 0.86, 0.76), (0.94, 0.80, 0.88), (0.74, 0.80, 0.96),
    ]

    var body: some View {
        Canvas { context, size in
            let rows = Int(size.height * 2)
            for row in 0..<rows {
                let position = Double(row) / Double(rows - 1) * Double(stops.count - 1)
                let index = min(Int(position), stops.count - 2)
                let (from, to) = (stops[index], stops[index + 1])
                let part = position - Double(index)
                let colour = Color(
                    red: from.red + (to.red - from.red) * part, green: from.green + (to.green - from.green) * part,
                    blue: from.blue + (to.blue - from.blue) * part)
                let line = CGRect(x: 0, y: CGFloat(row) / 2, width: size.width, height: 0.5)
                context.fill(Path(line), with: .color(colour))
            }
        }
    }
}

private struct MenuBar: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(MockApp.recipes.name).fontWeight(.bold).padding(.trailing, 20)
            HStack(spacing: 20) {
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0) }
            }
            Spacer()
            HStack(spacing: 18) {
                // Pin on Top's status item, filled while a window is pinned.
                Image(systemName: "pin.fill")
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("Thu 12 Nov  10:30")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(width: 900, height: 24)
        .background(Color.white.opacity(0.45))
    }
}

private struct RecipesWindow: View {
    private let baking: [(name: String, symbol: String)] = [
        ("Lemon Tart", "chart.pie"), ("Pavlova", "birthday.cake"), ("Banana Bread", "oven"),
    ]
    private let soups: [(name: String, symbol: String)] = [("Pumpkin Soup", "carrot"), ("Minestrone", "leaf")]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.1)).frame(width: 1)
            detail
        }
        .frame(width: 640, height: 384)
        .windowFrame()
        .overlay(alignment: .topLeading) {
            WindowButtons(style: .active).padding(.leading, 20).padding(.top, 20)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Baking", baking, selected: "Lemon Tart")
            section("Soups", soups, selected: nil).padding(.top, 10)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 56)
        .frame(width: 190)
        .background(Colours.sidebar)
    }

    private func section(_ title: String, _ rows: [(name: String, symbol: String)], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.bottom, 2)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 7) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(Colours.accent)
                        .frame(width: 18)
                    Text(row.name)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    if row.name == selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.09))
                    }
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Text("Lemon Tart")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                Spacer()
                Image(systemName: "heart")
                Image(systemName: "square.and.arrow.up")
            }
            .font(.system(size: 15))
            .foregroundStyle(Color.black.opacity(0.55))
            .padding(.horizontal, 20)
            .frame(height: 52)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Tart().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lemon Tart").font(.system(size: 22, weight: .bold))
                        Text("Serves 8 · 1 hr 20 min").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            tag("Dessert")
                            tag("Make ahead")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        heading("Ingredients")
                        ForEach(
                            [
                                "1¼ cups plain flour", "125 g cold butter", "4 eggs", "¾ cup caster sugar",
                                "3 lemons, zest and juice", "⅔ cup cream",
                            ], id: \.self
                        ) { Text("•  \($0)") }
                    }
                    .frame(width: 160, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        heading("Method")
                        ForEach(
                            Array(
                                [
                                    "Rub the butter into the flour, bring it together and chill for 30 minutes.",
                                    "Line a tart tin and blind bake at 180\u{A0}°C for 15 minutes.",
                                    "Whisk the eggs, sugar, lemon and cream, pour into the case and bake until just set.",
                                ].enumerated()), id: \.offset
                        ) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(step.offset + 1).").foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
                                Text(step.element).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .padding(22)
            Spacer()
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MockApp.recipes.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(MockApp.recipes.tint.opacity(0.14), in: Capsule())
    }
}

/// A lemon tart, from above.
private struct Tart: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.88, green: 0.68, blue: 0.42))
            Circle()
                .strokeBorder(Color(red: 0.80, green: 0.57, blue: 0.32), style: StrokeStyle(lineWidth: 5, dash: [2.5, 3]))
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.93, blue: 0.55), Color(red: 0.98, green: 0.82, blue: 0.30)],
                    center: .topLeading, startRadius: 4, endRadius: 70))
                .padding(9)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 7, height: 7).offset(x: -10, y: -6)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 5, height: 5).offset(x: 12, y: 4)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 6).offset(x: -2, y: 14)
        }
    }
}

/// The pinned Timer as its mirror shows it: inactive, since you're using Recipes, and with the pin
/// badge in its top right corner, as OverlayView draws it while the pointer is over it.
private struct TimerWindow: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(MockApp.timer.tint.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: 0.6)
                    .stroke(MockApp.timer.tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("1:48").font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 3) {
                Text("Green tea").font(.system(size: 15, weight: .semibold))
                Text("3 minutes").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    roundButton("pause.fill")
                    roundButton("arrow.counterclockwise")
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 270, height: 156)
        .windowFrame(active: false)
        .overlay(alignment: .topLeading) {
            WindowButtons(style: .inactive).padding(.leading, 8).padding(.top, 8)
        }
        .overlay(alignment: .topTrailing) {
            PinBadge().padding(12)
        }
    }

    private func roundButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.7))
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.07), in: Circle())
    }
}

/// OverlayView's badge: a white pin.fill at 11 pt semibold on a 22 pt black circle at 55%.
private struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.black.opacity(0.55), in: Circle())
    }
}

/// The arrow pointer: black with a white edge.
private struct Pointer: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Arrow().stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            Arrow().fill(Color.black)
        }
        .frame(width: 12, height: 19)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }

    private struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            let points: [(CGFloat, CGFloat)] = [
                (0, 0), (0, 16.5), (4, 12.8), (6.6, 18.8), (9.1, 17.7), (6.6, 11.9), (11.6, 11.9),
            ]
            var path = Path()
            path.addLines(points.map { CGPoint(x: rect.minX + $0.0 / 12 * rect.width, y: rect.minY + $0.1 / 19 * rect.height) })
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - The menu bar menu

/// A row of a menu, as NSMenu draws it on macOS 14.
private enum MenuRow {
    enum Picture {
        case symbol(String)
        case app(MockApp)
    }

    case header(String)
    case item(String, picture: Picture? = nil, ticked: Bool = false, key: String? = nil, submenu: Bool = false, highlighted: Bool = false)
    case separator

    var height: CGFloat {
        switch self {
        case .header: 20
        case .item: 22
        case .separator: 11
        }
    }

    var opensSubmenu: Bool {
        if case .item(_, _, _, _, true, true) = self { true } else { false }
    }

    var hasPicture: Bool {
        if case .item(_, .some, _, _, _, _) = self { true } else { false }
    }
}

/// The menu bar menu as AppDelegate.menuNeedsUpdate(_:) builds it with both permissions granted,
/// the Timer pinned, three other windows open and Open at Login on, with the Timer's submenu, which
/// Pin.contextMenu() builds, open.
private struct MenuBarMenu: View {
    let version: String

    static let pinAWindow = "Pin a Window"
    static let writtenTitles = [
        "Pin/Unpin Frontmost Window", "Welcome and Tips…", "Change Shortcut…", "Open at Login", "About Pin on Top",
        "Quit Pin on Top", "Go to Window",
    ]
    static let writtenSymbols = ["pin", "gearshape", "keyboard", "info.circle", "power"]
    /// A menu's padding above its first row and below its last.
    static let padding: CGFloat = 5

    /// How far a submenu overlaps its menu.
    private static let overlap: CGFloat = 4

    private var rows: [MenuRow] {
        [
            .header("Pin on Top \(version)"),
            .item("Pin/Unpin Frontmost Window", picture: .symbol("pin"), key: HotKey.standard.text),
            .separator,
            .header(MenuWords.pinned),
            // The Timer window has no title, so it's listed by its app's name.
            .item(windowLabel(.timer, ""), picture: .app(.timer), ticked: true, submenu: true, highlighted: true),
            .separator,
            .header(Self.pinAWindow),
            .item(windowLabel(.recipes, "Lemon Tart"), picture: .app(.recipes)),
            .item(windowLabel(.packingList, "Weekend Away"), picture: .app(.packingList)),
            .item(windowLabel(.readingLog, "Chapter 4"), picture: .app(.readingLog)),
            .separator,
            .item("Welcome and Tips…", picture: .symbol("gearshape")),
            .item("Change Shortcut…", picture: .symbol("keyboard")),
            .item("Open at Login", ticked: true),
            .separator,
            .item("About Pin on Top", picture: .symbol("info.circle")),
            .item("Quit Pin on Top", picture: .symbol("power"), key: Rules.shortcutText(modifiers: .command, key: "q")),
        ]
    }

    private var submenu: [MenuRow] {
        [
            .item("Go to Window"),
            .item(MenuWords.opacity, submenu: true),
            .item("\(MenuWords.alwaysPin) “\(Rules.menuTitle(MockApp.timer.name))”"),
            .separator,
            .item(MenuWords.unpin),
        ]
    }

    /// A window's label, as WindowInfo writes it.
    private func windowLabel(_ app: MockApp, _ title: String) -> String {
        WindowInfo(id: 0, pid: 0, appName: app.name, title: title, bounds: .zero, layer: 0).label
    }

    var body: some View {
        // The submenu's first row lines up with the row it opens from.
        let opener = rows.firstIndex(where: \.opensSubmenu) ?? 0
        HStack(alignment: .top, spacing: -Self.overlap) {
            MockMenu(rows: rows)
            MockMenu(rows: submenu).padding(.top, rows.prefix(opener).map(\.height).reduce(0, +))
        }
    }
}

/// One menu: as wide as its widest row, rounded, light, with a hairline edge and a shadow.
private struct MockMenu: View {
    let rows: [MenuRow]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        // When any row has a picture, every title moves over to leave room for one.
        let hasPictures = rows.contains(where: \.hasPicture)
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index], hasPictures: hasPictures).frame(maxWidth: .infinity).frame(height: rows[index].height)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, MenuBarMenu.padding)
        .background(Color(white: 0.965), in: shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 1)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
    }

    @ViewBuilder
    private func row(_ row: MenuRow, hasPictures: Bool) -> some View {
        switch row {
        case let .header(title):
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.top, 3)
        case .separator:
            Rectangle().fill(Color.black.opacity(0.1)).frame(height: 1).padding(.horizontal, 14)
        case let .item(title, picture, ticked, key, submenu, highlighted):
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 13)
                    .opacity(ticked ? 1 : 0)
                    .padding(.trailing, 4)
                if hasPictures {
                    Group {
                        switch picture {
                        case let .symbol(name): Image(systemName: name).font(.system(size: 13))
                        case let .app(app): AppIcon(app: app, size: 16)
                        case nil: Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 6)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 28)
                if let key {
                    Text(key).foregroundStyle(highlighted ? Color.white : Color.black.opacity(0.45))
                }
                if submenu {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? Color.white : Color.black.opacity(0.85))
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Colours.highlight)
                }
            }
            .padding(.horizontal, 5)
        }
    }
}
