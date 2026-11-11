# Contributing

Issues and pull requests are welcome. The app stays one Swift file that uses only Apple's
frameworks, with no dependencies and no networking code, so please keep it that way. For
anything security related, please use [SECURITY.md](SECURITY.md) instead of an issue.

## Tests

Run the tests from the top folder, on macOS 14 or newer with the Xcode Command Line Tools
(Swift 6 or newer):

```bash
./test.sh
```

They check the window list, the coordinate maths, the capture size, when a mirror shows and
fades, which window the shortcut picks, which window Always Pin picks and what it stores, when
the welcome window opens and what its tips say, which shortcuts the Change Shortcut window
takes, how it names keys and what it stores, and that the docs, the build and the changelog
agree with the code, using made-up windows and screens. They need no Screen Recording or
Accessibility permission and touch nothing real. `./test.sh --filter Visibility` runs only
the tests whose name matches. `./build.sh` builds the app the same way a release does, as one
app for Apple silicon and Intel: `lipo -archs "build/Pin on Top.app/Contents/MacOS/PinOnTop"`
prints `x86_64 arm64`.

The mirror itself, focusing windows, the menus, Always Pin, the welcome window, changing the
shortcut and the permission prompts need a real Mac, so check these by hand when a change
touches them. The app is signed ad hoc, so macOS treats each build as a new app: after you
rebuild, both permissions stop working though System Settings still shows them on.
`tccutil reset ScreenCapture io.github.kurrt.pin-on-top` (or `Accessibility`) takes a
permission away so you can grant it again, and `defaults delete io.github.kurrt.pin-on-top`
makes the next launch a first one.

**Mirroring and focus**

- Pin a window and switch to another app. The mirror floats on top and keeps updating.
- Click the mirror. The real window comes forward and the mirror hides.
- Move and resize the pinned window, including onto another display. The mirror follows.
- Minimise it, hide its app with ⌘H, then close it. The mirror goes each time.
- Pin two windows of one app. Each mirror shows only while its own window isn't focused.

**Fades**

- Switch away from a pinned window. Its mirror fades in. Switch back and it fades out.
- Click the mirror. It goes at once, with no ghost over the real window.
- Set the opacity to 50%, then switch away and back a few times. The mirror comes back at
  50%, and **Opacity** still ticks 50%.

**Always Pin**

- Turn it on for a pinned window, then quit the app and open it again. Within about a second
  a window is pinned again, the one with the same title if it's open.
- Quit and reopen Pin on Top. The window is pinned again.
- Close the pinned window while the app has another one open. The next one is pinned.
- Unpin the window by hand. It isn't pinned again until the app quits and opens again.
- Turn it off under **Always Pin** in the menu bar menu. The window stays pinned and the app
  leaves the list.
- Take Screen Recording away and reopen Pin on Top. Always Pin does nothing and shows no alert,
  though the welcome window opens.

**The Pinned submenu**

- Pin two windows and open the menu bar menu. Each is under **Pinned** with its app's icon and
  a tick, and pointing to one opens the same items as right-clicking it. Clicking it doesn't
  unpin it.
- **Opacity** there ticks the window's current step, and choosing another changes the mirror.
  The right-click menu then ticks the same step.
- **Always Pin “App”** there turns Always Pin on and off, and the **Always Pin** section
  follows. For an app with no bundle identifier it's greyed out, with a tooltip saying why.
- **Go to Window** there brings the window forward, and **Unpin** unpins it.
- Hover over a floating mirror's pin badge. Its tooltip names Opacity, Always Pin and Unpin.

**The welcome window and permissions**

- After `defaults delete`, it opens at launch. With both permissions on, it doesn't open at
  the next launch.
- After a `tccutil reset`, **Grant…** shows macOS's prompt and opens the right System
  Settings page. Once the permission is on, the row turns to **Granted** within about a
  second.
- After you grant Screen Recording, **Quit and Reopen** shows and reopens the app.
- Below the permissions are four tips, each on one or two lines, and the first shows the
  shortcut in use.
- **Change…** beside the first tip opens the Change Shortcut window. Change the shortcut and
  the tip shows the new one straight away.
- **Done** closes it, and **Welcome and Tips…** in the menu opens it again.
- Turn Accessibility off. **Grant Accessibility…** shows in the menu and pinning still works.

**Changing the shortcut**

- **Change Shortcut…** in the menu opens the window, showing the shortcut in use. Choose
  **Record New Shortcut** and press ⇧⌘K. It pins and unpins straight away, ⌃⌥⌘P no longer
  does, and **Pin/Unpin Frontmost Window** in the menu shows ⇧⌘K.
- While recording, hold modifier keys alone and it keeps waiting. Press K, or ⇧K, and the
  window says a shortcut needs ⌘, ⌃ or ⌥ and keeps recording.
- While recording, press a shortcut another app answers from anywhere, such as Spotlight's
  ⌘Space. That app gets the press, so the window can't record it: it keeps waiting, or stops
  recording if that app comes forward. The window only says another app may be using a
  shortcut when macOS refuses one, and in practice that's **Reset to ⌃⌥⌘P** while another app
  holds ⌃⌥⌘P for itself alone.
- While recording, press Escape, switch to another app, or close the window. Each time,
  recording stops and the old shortcut pins again.
- While recording, press the current shortcut. It's recorded rather than pinning a window.
- **Reset to ⌃⌥⌘P** is greyed out while the shortcut is ⌃⌥⌘P. After a change it brings
  ⌃⌥⌘P back.
- Record ⌥F5, then ⌃⌥←. **Pin/Unpin Frontmost Window** shows each as its key equivalent.
- Quit and reopen Pin on Top. Your shortcut still pins. Quit, run `defaults delete` and reopen
  it, and ⌃⌥⌘P pins again.

**About and the menu**

- The menu starts with the version and has symbols on its actions.
- **About Pin on Top** shows the icon, the version, the copyright and a link that opens the
  project page.

## The app icon

`scripts/make_icon.swift` draws the icon. After changing the drawing, run it from the top
folder and look at `docs/icon.png`, then at the small sizes the second command unpacks, since
the icon has to read at 32 px:

```bash
swift scripts/make_icon.swift
iconutil -c iconset Resources/AppIcon.icns -o /tmp/AppIcon.iconset
```

It writes `Resources/AppIcon.icns` for the app and `docs/icon.png` for the README. Commit
both, so building doesn't need the script.

## Releases

```bash
./build.sh --zip
```

This builds the app and zips it to `build/Pin-on-Top-<version>.zip`, with its SHA-256 in
`build/Pin-on-Top-<version>.zip.sha256`. `./build.sh --print-version` prints the version.

To make a release:

1. Bump `VERSION` in `build.sh`, add a `## <version>` section at the top of `CHANGELOG.md`
   saying what changed, and update the zip's name in the README's install steps. The tests
   check that all three agree.
2. Once that's on `main`, push the tag `v<version>`, such as `v1.1.0`.

The Release workflow refuses a tag that doesn't match `VERSION`. It runs the tests, builds the
zip and publishes it with its `.sha256`, using the changelog section as the release notes.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): summary
```

The type is lowercase. The scope is optional and can only use a-z, 0-9 and -, starting with
a letter or digit. That's stricter than Conventional Commits, so `fix(main.swift)` is
refused. Keep the line to 72 characters with no full stop at the end. To explain more, leave
a blank line and add a body.

| Type | Use it for |
| --- | --- |
| `feat` | Something new people can use |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `refactor` | A code change that keeps the behaviour the same |
| `perf` | Making it faster or lighter |
| `style` | Formatting only |
| `build` | `build.sh`, `Package.swift` or the app bundle |
| `ci` | The GitHub workflows |
| `chore` | Other upkeep that doesn't change the app |
| `revert` | Undoing an earlier commit |

For example:

```
feat(menu): show which display each window is on
fix(mirror): follow a window onto another display
docs: explain the Accessibility permission
```

If a change makes people grant a permission again, learn a new shortcut or otherwise notice
that the app works differently, add `!` after the type or scope and say what to do in the
body:

```
feat(hotkey)!: move the default shortcut to Control-Option-Command-T

Unless you've changed the shortcut, use Control-Option-Command-T to pin and unpin after you
rebuild.
```

A pull request's title follows the same rule. A squash merge makes one commit, and by default
GitHub takes its subject from the title if the pull request has two or more commits, or from
the commit's own subject if it has one, then adds the pull request's number as ` (#N)`. One
` (#N)` at the end of a subject isn't counted towards the 72 characters.

`Revert "..."` messages from git and GitHub, and `Reapply "..."` messages from git, are
accepted as they are.

## The commit check

GitHub Actions checks every new commit and the pull request title. A first push or a force
push checks only the newest commit.

To catch most problems as you commit, turn on the hook:

```bash
git config core.hooksPath .githooks
```

It also lets through `Merge`, `fixup!`, `squash!` and `amend!` subjects while you work, and
Actions refuses those unless they are real merge commits.

To check your branch by hand:

```bash
python3 -I scripts/check_commits.py --range=origin/main..HEAD
```

This needs `origin/main` to exist. If it doesn't, the check says so and looks at only the
newest commit.

The check has its own tests, which Actions runs too. They make throwaway git repos and touch
nothing else:

```bash
python3 -I -m unittest discover -s scripts -v
```
