# Changelog

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
