# Changelog

## 1.1.0

Pin on Top's options are easier to find, and you can change the shortcut.

**New**

- **Change Shortcut…** in the menu bar menu, and **Change…** in the welcome window, for when ⌃⌥⌘P clashes with another
  app. Choose **Record New Shortcut** and press a key while holding ⌘, ⌃ or ⌥. The window says why when it can't use a
  shortcut, including when macOS won't register it, and the old one keeps working. **Reset to ⌃⌥⌘P** goes back to the
  default. The menu and the welcome window show the shortcut you chose, and it's kept when Pin on Top quits.
- Tips in the welcome window: how to pin and switch to a pinned window, and where its options and Always Pin are.

**Changed**

- Each window under **Pinned** in the menu bar menu opens the same options as right-clicking it: Go to Window,
  Opacity, Always Pin and Unpin. Clicking it no longer unpins it.
- The menu's welcome item is now **Welcome and Tips…**, since the window has tips as well as the permissions.
- The pin badge's tooltip names the right-click menu's options.

## 1.0.0

The first release you can download. Before this, you built Pin on Top from source, which still works.

**New**

- A download: one app for Apple silicon and Intel Macs, zipped, with a SHA-256 file to check it against. It's signed
  ad hoc, not notarised, so macOS asks you to allow it the first time you open it.
- **Always Pin**: right-click a pinned window and choose **Always Pin “App”**. Pin on Top then keeps one of that app's
  windows pinned after the app, Pin on Top or the Mac restarts, preferring the window you pinned last. Unpinning one by
  hand pauses it until the app quits. Turn an app off from the **Always Pin** section of the menu bar menu.
- A welcome window that says what the app does and shows the shortcut, with a **Grant…** button for each missing
  permission and **Quit and Reopen** once Screen Recording is turned on. It opens the first time, while a permission is
  missing, and from **Welcome and Permissions…** in the menu.
- **About Pin on Top**, with the version and a link to the project page.
- An app icon.
- Pinned windows fade in and out as they float on top and step aside.

**Changed**

- Pin on Top no longer shows the system's permission prompts by itself when it opens. The welcome window asks instead.
- A tidier menu: the version at the top, symbols on the actions, shorter section headings, and long app names cut short
  like window titles.
- Building from source makes one app for Apple silicon and Intel Macs, with the icon and the version.
