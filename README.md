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

## Working with screenshots

- **Drag the stack** to take all screenshots along at once.
- **Drag a single screenshot** from the expanded shelf.
- **Select several** on the expanded shelf: ⌘-click them, or drag a
  Finder-style selection rectangle from empty space (or after briefly holding
  a screenshot). Hold ⌘ to add to the current selection. Dragging or any action on a selected screenshot applies to all of them.
- **Click** a screenshot to select it, as in Finder (⌘-click adds, ⇧-click
  selects a range). Then **space** opens Quick Look, **⌘C** copies, **⌘A**
  selects all, **⌘⌫** moves to the Trash, **Escape** deselects and the arrow
  keys step through. **Double-click** opens Quick Look too. Hovering enlarges it slightly and
  shows a × that saves it to your folder, or trashes it if you prefer.
- **Quick actions** (optional, in Settings): Copy and View buttons in the
  middle and Delete in the bottom-left on hover. You can still start a drag
  anywhere. The × is then hidden when it would do the same as Delete.
- **Drop images onto the shelf** to keep them there for a while. Drag them
  towards the shelf's corner and it comes out by itself. Files from disk are
  only referenced: closing or deleting them just takes them off the shelf, the
  original stays put. Images without a file (e.g. from a browser) are saved
  like screenshots.
- **Newest first**, grouped by date when the shelf holds more than one day: Today,
  Yesterday, Earlier this week, Last week, 2 weeks ago, and month names
  further back. With everything from a single day, no labels appear.
- **Collapse** the expanded shelf by clicking its header: the chevron, the
  count, or the empty space beside it.

Dragged screenshots are offered both as a file and as plain image data, so
Finder, chat apps and editors all accept them. Dragging always copies; the
screenshot stays on the shelf.

Swipe the shelf away by its border: the edge and caption when collapsed, and
the edge, header and bottom strip when open. Drag a selection rectangle from
the gaps between screenshots. That way dragging, selecting and swiping never
get in each other's way.

## Shelves

The icons in the middle of the header are your shelves — up to six. A fresh
install starts with three — **Starred**, **Shelf 1** and **Shelf 2** — and
opens on Shelf 1. New shelves are numbered on from there; names you give a
shelf yourself are kept.

- **Click** one to switch. The screenshots slide in from the side.
- **Drag screenshots** onto one to move them there.
- **Starred** collects: starring a screenshot (right-click › Add to Starred, or
  drag it onto the star) keeps it on its own shelf and also shows it on
  Starred, with a small star on it elsewhere.
- **Drag the icons** themselves to reorder your shelves.
- The shelf you're on is at full strength; the others are dimmed, and their
  emoji lose their colour.
- **Right-click** one for Change Shelf Icon, Rename, New Shelf, Save Shelf,
  Open Shelf and Delete Shelf (only when that shelf is empty).

The icon picker has every emoji macOS can draw plus a few hundred symbols, with
a search field; the bin button clears the icon again.

Right-click a screenshot for Copy, Quick Look, Save, Delete, and Move to
Shelf. Right-click an empty part of the shelf to paste an image or a file from
the clipboard.

Your shelves are kept in `~/Library/Application Support/ShotShelf`, so they
survive quitting and updating. Quitting no longer empties the shelf into your
save folder; it stays as you left it.

A `.shelf` file holds a copy of every image plus the shelf's name and icon, so
it keeps working on another Mac. Save one from the menu bar icon or a shelf's
right-click menu, and open it by double-clicking it in Finder.

## Settings

Open Settings from the gear on the expanded shelf, from the menu bar icon (⌘,),
or by opening ShotShelf again from Applications, which works even with both
icons turned off.

- **Saving:** the folder screenshots move to, and whether closing a single
  screenshot or the whole shelf saves or trashes. Quitting always saves.
- **Shelf:** thumbnail size (Small, Medium or Large), quick actions on hover,
  and which corner it appears in. It grows away from that corner and
  swipes off towards the nearest side.
- **Show and Hide:** a keyboard shortcut, an extra mouse button, and/or a hot
  corner. In the hot corner, either move the pointer in, or scroll or swipe
  within 210 pt of it: sideways, up and down, or either (MX Master thumb wheel,
  Magic Mouse, trackpad). Left or up shows the shelf, right or down hides it,
  with an option to swap. Scrolling elsewhere is ignored. Hiding saves nothing; screenshots stay on the
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

## Tests

```
./test.sh
```

Builds and runs the suites in `Tests/` against the app's own sources: the
shelves and starring, the keyboard and Quick Look, the layout, the corner
gestures, the panel's behaviour, and the mouse interactions (driven with
synthetic clicks and drags).

## Building

Only the Xcode Command Line Tools are needed:

```
./build.sh
```

Produces `build/ShotShelf.app` and `build/ShotShelf-<version>.dmg`. The version
number lives in `VERSION`.
