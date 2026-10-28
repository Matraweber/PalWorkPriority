---
date: 2026-10-28
tags: [release, tooling]
status: current
---
# Workshop upload macro (2026-10-28)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [g7-final-build-2026-10-28](g7-final-build-2026-10-28.md) · [g1-workshop-2026-10-20](g1-workshop-2026-10-20.md) · [testing](testing.md)

The user asked for a macro that uploads the new mod files to the Steam
Workshop. Publishing stays the user's action: by default the macro stops one
click before the upload.

## How 0.4.1 was published

- The tool is Pocketpair's **Palworld Mod Uploader**, installed through Steam
  as app 4212470 (`C:\Program Files (x86)\Steam\steamapps\common\PalworldModUploader`).
  It is byte-identical to its GitHub release v0.3.0.
- It uploads a whole folder with ISteamUGC. It sets the title from
  `Info.json` ModName, the preview from `thumbnail.png`, the tags from
  `Info.json` Tags, and the change note typed into its Change Notes window.
- `.workshop.json` in the folder holds the item id (3786408856) and the last
  published version. The file is uploaded too, which is why the subscribed
  copy of 0.4.1 contains it.
- A folder named after a subscribed item id is view-only in the tool. The
  upload must come from a separately named folder.
- Its Workshop directory is saved in `workshop_path.txt` next to the exe. That
  file still pointed at a `C:\Program Files (x86)\Steam\steamapps\workshop\content\1623730`
  that no longer exists.

## The macro

`tools/workshop_upload.py` (staging, checks) and `tools/workshop-upload.ps1`
(UI Automation of the uploader). Commands are in [testing](testing.md).

- **prepare.** Checks the Workshop archive against the release manifest and
  that tag `v<version>` is the commit it was built from. Extracts the archive
  into `D:\PalWorkPriority-workshop\stage\PalWorkPriority`; an older stage is
  moved aside. Checks Info.json (version, package name, DebugMode off,
  thumbnail) and that there is no DLL. Copies `.workshop.json` from the
  subscribed copy and refuses a version that is already published.
- **Change note.** The CHANGELOG section is converted to Steam BBCode. Steam
  caps a change note at 8,000 bytes (`k_cchPublishedDocumentChangeDescriptionMax`)
  and the 0.5.0 section is about 10,000. Parts are kept in a fixed order
  (intro, Before you update, Limits, then the Fixed groups, then the rest),
  and the note names what it left out and links the full changelog on GitHub.
  For 0.5.0 that leaves out the panel/stand fixes and the performance
  numbers (7,491 bytes). The note file sits next to the folder, not in it,
  so it is not uploaded.
- **upload.** Points the uploader at the stage, starts it, selects
  PalWorkPriority and checks that the tool shows `PalWorkPriority 0.5.0`.
  Presses "Upload To Steam" and fills in the change note. Any other dialog
  stops the run with its text.
  - Default: the run stops with the Change Notes window open, and OK there
    publishes.
  - `--submit` presses OK and waits for "Workshop item submitted
    successfully".
  - `--dry-run` presses Cancel and closes the tool.
- **check.** After Steam has downloaded the update, compares the subscribed
  copy with the stage file by file and reads the version the uploader
  recorded.

## Dry run (22:28)

`prepare` staged 67 files of `PalWorkPriority-0.5.0-workshop.zip` (sha256
37be0c84…, tag v0.5.0 = 35366bf). `upload --dry-run`:

- The tool started, and PalWorkPriority showed 0.5.0.
- The version check passed: last published 0.4.1, so no warning.
- The Change Notes window took the whole note.
- Cancel produced "Upload canceled by user". Nothing was sent.

## Not covered

The real upload and the Steam download after it. Both are the user's action:
`python tools/workshop_upload.py upload`, press OK, then
`python tools/workshop_upload.py check`.

Steam may need a restart, or the item re-subscribed, before the subscribed
copy updates. The game's loader then reinstalls on the next launch, as in
[g1-workshop-2026-10-20](g1-workshop-2026-10-20.md).

## Fixes after the review

From bundle G of [review-2026-10-28](review-2026-10-28.md). The uploader's
behaviour below was read in its source (MainWindow.xaml.cs, OnItemSubmitted
and OnLoaded) and is covered offline by `tests/test_workshop_upload.py`.

- **Version guard.** The uploader writes `last_published_version` only after
  a successful upload, so the subscribed `.workshop.json` is one release
  behind. `prepare` now takes the live version from the subscribed
  `Info.json` and from the `last_published_version` of earlier stages. It
  refuses an equal or older version before it touches the stage, and writes
  the live version into the staged `.workshop.json`.
- **Submit result.** After a successful upload the uploader can replace
  "Workshop item submitted successfully." with "Submitted, but failed to
  update metadata / open Steam page". Both now count as published, the
  second with a warning. The wait also ignores the status text from before
  OK, so a startup "Failed to read workshop subscriptions" no longer reads as
  a failed upload.
- **Asserts.** Every guard is an explicit check with a message, so
  `python -O` keeps them.
- **check** defaults to the staged version. It refuses when the stage
  changed since `prepare` and compares Steam's copy with the hashes recorded
  then.
- **Row selection.** The driver waits until the Workshop directory box shows
  the stage path, then matches the row by its Directory cell.
- **Change note** from `git show v<version>:CHANGELOG.md`. For 0.5.0 it is the
  same 7,491 bytes as in the dry run.
- **Restart macro.** `restart-stand.ahk` stops before the first Escape if the
  menu check already reads open. With the stand open it reads closed: R123
  G135 B150 and R117 G128 B143, sampled live on 2026-10-28.

Not live-tested yet: the Directory-cell match and the directory wait (UI
Automation against the real uploader). The next `upload --dry-run` checks
both.
