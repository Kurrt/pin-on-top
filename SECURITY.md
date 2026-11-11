# Security

## Reporting a problem

Please report security problems privately, using GitHub's private vulnerability reporting.
On this repo's **Security** tab, open **Advisories** and choose **Report a vulnerability**.
Please don't open a public issue for one. If that button isn't there, open an issue that only
asks how to report something privately, and leave out the details. Please leave out real
window titles and screenshots of private windows too. A made-up example is enough.

Only the latest release, and `main`, are supported.

## What access this app has

It's worth knowing what you're giving it before you turn its permissions on.

- **Screen Recording.** macOS grants this for the whole screen, but the app only asks
  ScreenCaptureKit for the windows that are pinned, one window each. Frames stay in memory, are
  drawn into the mirror and are never saved or sent anywhere.
- **Accessibility.** macOS lets an app with this read and control other apps. Pin on Top only
  asks which window is focused and whether a pinned window is minimised, and brings a pinned
  window forward when you click its mirror. It doesn't read the text or controls in any
  window, and it doesn't press keys or click for you.
- **The window list.** To fill the menu, and for Always Pin, it reads each on-screen window's
  app name, title, position and size from macOS. Titles never leave your Mac.
- **One shortcut.** It registers the shortcut you choose, ⌃⌥⌘P by default, with macOS, and
  macOS tells it about that shortcut only, not other keys. While you record a new one in the
  Change Shortcut window, it sees only the keys you press in that window, and it stops
  recording when you close the window or switch to another app.
- **Open at Login**, only if you turn it on, through macOS's own login items.
- **What it keeps.** Three things, in the app's preferences on this Mac only:
  - **Always Pin's apps**, only if you use it. For each app, its bundle ID (such as
    `com.apple.Notes`), its name and the title of the window pinned last, as JSON under the
    `alwaysPin` key. Turning an app off removes it, and turning them all off leaves an empty
    list.
  - **`hasSeenWelcome`**, set once the welcome window has shown, so it doesn't open at every
    launch.
  - **The shortcut**, only if you change it. Its key code, modifiers and the key's name, as
    JSON under the `shortcut` key. Resetting it to ⌃⌥⌘P removes the key.

  To clear them all, quit Pin on Top and run `defaults delete io.github.kurrt.pin-on-top`.
- **What it opens.**
  - System Settings, at the right page, when you ask to grant a permission. **Grant…** asks
    macOS for the permission first, which may show macOS's own prompt.
  - The project page, https://github.com/Kurrt/pin-on-top, in your browser, when you click
    the link in **About Pin on Top**.
  - **Quit and Reopen** runs `/usr/bin/open -n` on Pin on Top itself, then quits. It runs no
    other programs.
- **No network.** There's no networking code, so nothing leaves your Mac. It writes no logs
  and saves no frames or screenshots.
- **One undocumented call.** `_AXUIElementGetWindow` matches Accessibility windows to window
  IDs. It's private to Apple, and the app only uses it to read a window's ID.
- **Ad hoc signing.** The app and the release download are signed ad hoc, not notarised by
  Apple, so macOS can't vouch for them. GitHub Actions builds each release from its tagged
  commit with `.github/workflows/release.yml`. The `.sha256` file shows the zip arrived
  intact, but it comes from the same release, so it doesn't prove who made it. To be sure,
  read the source and build it yourself.
