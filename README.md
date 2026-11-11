<img src="docs/icon.png" alt="Pin on Top's icon" width="128">

# Pin on Top

A tiny macOS menu bar app that keeps any window floating above everything else.

Most "always on top" tools are closed source, want broad permissions, or inject code into other apps. Pin on Top is a single Swift file (about 1300 lines) you can read in one sitting. It uses only Apple's frameworks and has no dependencies and no networking code. Download it, or build it yourself from source.

## Features

- Pin any window with **⌃⌥⌘P** (Control-Option-Command-P), or pick it from the menu bar list
- Pin as many windows as you like
- Pinned windows float above every other app, fading in and out as you switch
- Click a pinned window to jump straight to it
- Right-click a pinned window to change its opacity, Always Pin its app, or unpin it
- **Always Pin** remembers an app and keeps one of its windows pinned after the app, Pin on Top or the Mac restarts
- A welcome window that walks you through the two permissions
- One app for Apple silicon and Intel Macs
- Optional "Open at Login"

## Install

You need macOS 14 Sonoma or later.

### Download

1. Download `Pin-on-Top-1.0.0.zip` and `Pin-on-Top-1.0.0.zip.sha256` from the [latest release](https://github.com/Kurrt/pin-on-top/releases/latest).
2. To check the zip, run this in Terminal in the folder you saved them to (usually `cd ~/Downloads` first). It should print `Pin-on-Top-1.0.0.zip: OK`.

   ```bash
   shasum -a 256 -c Pin-on-Top-1.0.0.zip.sha256
   ```

   Safari may unzip downloads for you. If the zip has gone, turn off **Open “safe” files after downloading** in Safari's General settings and download it again.
3. Unzip it and move **Pin on Top** to your Applications folder.
4. Open it. The app is signed ad hoc, not notarised, so macOS blocks it the first time. Close the warning, go to System Settings > Privacy & Security, and choose **Open Anyway** next to the message about Pin on Top. Or run this in Terminal, then open it again:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Pin on Top.app"
   ```

### Build from source

You also need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Kurrt/pin-on-top.git
cd pin-on-top
./build.sh --install
```

This builds `build/Pin on Top.app` as one app for Apple silicon and Intel, copies it to `/Applications` and opens it. Run `./build.sh` on its own to build without installing. An app you build yourself isn't quarantined, so macOS opens it without asking.

### Updating

Quit Pin on Top and replace the app in Applications with the new download, as above. If you build from source, pull and run `./build.sh --install` again. Your Always Pin apps are kept.

The app is signed ad hoc, so macOS treats each new build, downloaded or built yourself, as a new app and it needs its permissions again. Remove **Pin on Top** from Screen Recording and Accessibility in System Settings > Privacy & Security, then open it and grant them again from the welcome window.

## Permissions

Pin on Top needs two permissions. The first time it opens, and whenever one of them is missing, a welcome window lists them:

1. Choose **Grant…** next to each one. macOS may ask first, then System Settings opens at the right page. Turn on **Pin on Top** there.
2. Screen Recording only starts working once the app reopens, so choose **Quit and Reopen** after you turn it on.
3. Choose **Done**.

To see it again, choose **Welcome and Permissions…** from the menu bar menu. If the menu shows a **Grant…** item, that permission is still missing.

| Permission | Why it's needed |
| --- | --- |
| Screen Recording | To show the live mirror of a pinned window (see below). |
| Accessibility | To tell which window is focused, notice minimised windows, and bring the exact window forward when you click its mirror. |

Nothing leaves your Mac. The app opens System Settings when you grant a permission, and the link in **About Pin on Top** opens the project page in your browser. [SECURITY.md](SECURITY.md) lists what it can see and what it keeps.

## Usage

- **Pin:** focus a window and press ⌃⌥⌘P, or choose it under **Pin a Window** in the menu bar menu.
- **Unpin:** press ⌃⌥⌘P on the pinned window, right-click its mirror and choose **Unpin**, or click it under **Pinned** in the menu.
- **Use the pinned window:** click it. The real window comes forward and you can type, scroll and resize as usual. When you switch to another app it floats on top again.
- **Opacity:** right-click a pinned window and choose **Opacity**. It stays that way until you unpin the window.
- **About:** choose **About Pin on Top** in the menu for the version and a link to the project page.

A small pin badge appears when you hover over a pinned window that's floating on top.

### Always Pin

Right-click a pinned window and choose **Always Pin “App”** (with the app's name) to turn it on or off. You can also turn an app off by clicking it under **Always Pin** in the menu bar menu. Turning it off doesn't unpin the window.

While it's on, Pin on Top checks about once a second. If the app is running and none of its windows is pinned, it pins the window with the same title as the one pinned last, or else the app's frontmost window. So the window comes back after the app, Pin on Top or the Mac restarts (turn on **Open at Login** for that last one), and when the pinned window closes, the app's next window is pinned.

- Unpinning one of its windows by hand (the shortcut, **Unpin**, or the **Pinned** list) pauses Always Pin for that app until it quits and opens again, or until you pin one of its windows by hand or turn Always Pin off and on.
- It needs Screen Recording and does nothing without it.
- Apps without a bundle identifier can't be remembered, so the item is greyed out for them.

## How it works

macOS has no public way for one app to change another app's window level. Tools that truly do it need System Integrity Protection turned off so they can inject code into the window server.

Pin on Top instead shows a live [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) mirror of the window in a floating panel that sits exactly over the real one:

- While you're working in the pinned window, the mirror hides and you use the real window directly.
- When you switch to anything else, the mirror appears on top, kept up to date at up to 60 fps.
- Clicking the mirror brings the real window forward.
- If the window moves or resizes, the mirror follows it. If the window closes, it's unpinned.

To match Accessibility windows to window IDs, the app uses `_AXUIElementGetWindow`. It's undocumented but has been stable for many years and is widely used by window managers.

## Limitations

- You can't type into the mirror itself. Clicking it switches you to the real window.
- If the pinned window lives on another Space, its mirror may stop updating and show the last frame until you go back to it.
- Always Pin only pins a window that's on screen. A window on another Space, minimised or hidden is pinned once you can see it.
- The app is signed ad hoc, not notarised. macOS blocks a download the first time you open it, and treats each new build as a new app, so you grant the permissions again after updating or rebuilding (see [Updating](#updating)).

## Uninstall

Turn off **Open at Login** if it's on, choose **Quit Pin on Top** from the menu bar menu, and delete `/Applications/Pin on Top.app`. Then remove it from Screen Recording and Accessibility in System Settings. To forget its Always Pin apps and the welcome window too, run:

```bash
defaults delete io.github.kurrt.pin-on-top
```

## Tests

```bash
./test.sh
```

They need only the Xcode Command Line Tools and no permissions. [CONTRIBUTING.md](CONTRIBUTING.md) says what they cover and what to check by hand.

## Contributing

Issues and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately, as [SECURITY.md](SECURITY.md) explains.

## Licence

[MIT](LICENSE)
