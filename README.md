# Pin on Top

A tiny macOS menu bar app that keeps any window floating above everything else.

Most "always on top" tools are closed source, want broad permissions, or inject code into other apps. Pin on Top is a single Swift file (about 600 lines) you can read in one sitting. It uses only Apple's frameworks, has no dependencies and no networking code, and you build it yourself from source.

## Features

- Pin any window with **⌃⌥⌘P** (Control-Option-Command-P), or pick it from the menu bar list
- Pin as many windows as you like
- Pinned windows float above every other app
- Click a pinned window to jump straight to it
- Right-click a pinned window to change its opacity or unpin it
- Optional "Open at Login"

## Install

You need macOS 14 Sonoma or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Kurrt/pin-on-top.git
cd pin-on-top
./build.sh --install
```

This builds `build/Pin on Top.app`, copies it to `/Applications` and opens it. Run `./build.sh` on its own to build without installing.

## Permissions

The first time it opens, macOS asks for two permissions. Turn both on for **Pin on Top** in System Settings > Privacy & Security, then quit and reopen the app.

| Permission | Why it's needed |
| --- | --- |
| Screen Recording | To show the live mirror of a pinned window (see below). |
| Accessibility | To tell which window is focused, notice minimised windows, and bring the exact window forward when you click its mirror. |

Nothing leaves your Mac. The only link the app opens is System Settings.

If the menu bar menu shows a **Grant…** item, that permission is still missing.

## Usage

- **Pin:** focus a window and press ⌃⌥⌘P, or choose it under **Pin a Window** in the menu bar menu.
- **Unpin:** press ⌃⌥⌘P on the pinned window, right-click its mirror and choose **Unpin**, or click it under **Pinned** in the menu.
- **Use the pinned window:** click it. The real window comes forward and you can type, scroll and resize as usual. When you switch to another app it floats on top again.
- **Opacity:** right-click a pinned window and choose **Opacity**.

A small pin badge appears when you hover over a pinned window that's floating on top.

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
- The app is signed ad hoc, not notarised. After you rebuild it, macOS treats it as a new app: remove **Pin on Top** from Screen Recording and Accessibility in System Settings, then add it again.

## Uninstall

Choose **Quit Pin on Top** from the menu bar menu, delete `/Applications/Pin on Top.app`, then remove it from Screen Recording and Accessibility in System Settings.

## Licence

[MIT](LICENSE)
