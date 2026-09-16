# ShotShelf

A tiny, invisible macOS menu bar app. The moment you take a screenshot:

1. a glass shelf slides in from the corner of your screen with the screenshot on it,
2. the screenshot is already on your clipboard, so ⌘V works right away,
3. the file stays *off* your Desktop until you close the shelf.

Several screenshots pile up into a stack. Click the stack to expand it and see
each one separately. Close the shelf with the × or by swiping it away, and all
screenshots move to your save folder (the Desktop by default).

## Install

Download the latest DMG from
[Releases](https://github.com/antaflu/shotshelf/releases), open it and drag
ShotShelf to Applications. Launch it once; from then on you only see a small
stack icon in the menu bar.

ShotShelf is ad-hoc signed, not notarized. The first time, macOS may block it:
right-click the app and choose **Open**, or run

```
xattr -dr com.apple.quarantine /Applications/ShotShelf.app
```

Requires macOS 13 or later. Universal build (Apple silicon and Intel).

## Dragging

- **Drag the stack** to take all screenshots along at once.
- **Drag a single screenshot** from the expanded shelf.

Dragged screenshots are offered both as a file and as plain image data, so
Finder, chat apps and editors all accept them. Dragging always copies; the
screenshot stays on the shelf.

Swipe gestures live on the shelf's border and caption (and on the header when
expanded), so dragging and swiping never get in each other's way.

## Settings

Open Settings from the gear on the expanded shelf, from the menu bar icon (⌘,),
or by opening ShotShelf again from Applications, which works even with both
icons turned off.

- **Saving:** the folder screenshots move to when you close the shelf.
- **Shelf:** which corner it appears in. It grows away from that corner and
  swipes off towards the nearest side.
- **Show and Hide:** a keyboard shortcut, an extra mouse button, and/or a hot
  corner (move the pointer in, or scroll sideways there, e.g. with the thumb
  wheel of a Logitech mouse). Hiding saves nothing; screenshots stay on the
  shelf. Turn off the macOS hot corner for the same corner.
- **Appearance:** menu bar and/or Dock icon, and which icon.
- **Updates:** current version, status, and automatic checking and
  downloading. A downloaded update installs on the next relaunch, or right away
  via **Relaunch and Install**.

## How it works

macOS decides where screenshots go through `com.apple.screencapture`. On
launch, ShotShelf points that location at its own staging folder
(`~/Library/Application Support/ShotShelf/Staging`) and watches it. When
ShotShelf quits, your original setting is restored and anything still on the
shelf moves to your save folder.

By default ShotShelf also turns off the floating macOS preview thumbnail: the
shelf replaces it, and macOS only writes the file *after* that thumbnail
disappears. You can turn it back on in Settings; it is restored on quit too.

ShotShelf never deletes a screenshot. If moving one fails, the file stays in
the staging folder and comes back on the shelf at the next launch.

## Updates and releases

The app checks the GitHub releases of `antaflu/shotshelf` (override with
`UPDATE_REPO`). Before installing, it verifies the SHA-256 checksum and the
bundle identifier.

To publish a new version:

```
./release.sh 1.2 "What's new"
```

This builds the DMG, writes a checksum, tags and pushes, and uploads both
files as a GitHub release.

## Building

Only the Xcode Command Line Tools are needed:

```
./build.sh
```

Produces `build/ShotShelf.app` and `build/ShotShelf-<version>.dmg`. The version
number lives in `VERSION`.
