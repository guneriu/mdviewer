# Automatic refresh when referenced images change — design

Status: proposed (2026-10-30). Feature 3 of the post-v1 round. Contract base:
[v1 specification](2026-10-29-mdviewer-v1-design.md) (image policy, refresh A06/A07).

## Problem

`DocumentRefresh` (`Sources/MDViewerCore/DocumentRefresh.swift`) watches only the
Markdown file and its physical parent directory. Changing a referenced image (a
re-exported diagram, a new screenshot) does not refresh the preview. The README says
"Asset-only changes need Cmd-R." Cmd-R and automatic reload already use the same read,
stage, and render path, and the gateway serves `Cache-Control: no-store` with fresh
capability URLs each render. So the missing piece is only the trigger.

## Goals

1. Saving a referenced image in place or atomically, deleting it, or creating a
   previously missing referenced image refreshes the preview automatically. Covers
   images in the document directory and in nested subdirectories.
2. No change to image containment, budgets, no-follow reads, or capability rules.
   Watch events only trigger the existing reload; they never grant access.
3. Bounded resource use. No per-image file descriptors.

## Non-goals

Watching images outside the document directory (they are blocked anyway). Watching
linked Markdown files. Partial re-render of only the image. Refreshing on changes to
unreferenced files.

## Design

### Watch mechanism: one FSEvents stream per window

Add `Sources/MDViewerCore/AssetWatcher.swift`. It wraps `FSEventStreamCreate` on the
**physical** document directory (`realpath` of `assetRoot`, as in the `/tmp` fix) with
`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
kFSEventStreamCreateFlagWatchRoot`, 0.1 s latency, and a dispatch queue
(`FSEventStreamSetDispatchQueue`).

Why FSEvents instead of more `DirectoryWatcher`s:
- Directory vnode watchers miss in-place image overwrites.
- Per-file watchers cost one descriptor each (up to 256 images × N windows against
  the default 256 descriptor soft limit).
- FSEvents is recursive and uses no per-file descriptors.

Pass both paths and their FSEvents flags to `receive(paths:flags:)`. Trigger once
per batch for an exact watched path, or a directory event whose path is a **strict
ancestor** of a watched path (a precomputed ancestor set avoids per-event tree scans).
Also trigger a conservative rescan/reload for
`kFSEventStreamEventFlagMustScanSubDirs`, `kFSEventStreamEventFlagUserDropped`,
`kFSEventStreamEventFlagKernelDropped` or `kFSEventStreamEventFlagRootChanged` when
the watch set is nonempty: these flags mean exact event delivery cannot be trusted.
They do not authorize any new path.

Match physical paths after Unicode canonical normalization on **both** watch and
event sides (NFC/NFD-insensitive). APFS preserves names as written; do not assume
FSEvents always returns NFD. Read `URLResourceValues.volumeSupportsCaseSensitiveNames`
once for the physical root: when it is false, case-fold both sides with the same
locale-independent rule. On a case-sensitive volume keep case distinctions. No
filesystem I/O is performed in the event callback.

### Watch set

- After each **successful committed** render, `RenderHost` reports the set of image
  candidate paths it resolved for that generation. These are physical, contained paths:
  existing regular-file candidates plus contained-but-missing candidates, so creating
  a missing image triggers a refresh. Keep contained regular files that fail only
  content, format, decode or budget checks (including zero-size, mid-write and
  over-budget files); a later valid write must still trigger a retry.
- Standardize local paths before containment checks, preserving v1 in-root `..`
  references such as `img/../a.png`. Exclude structurally unsafe references
  (scheme/invalid local path, escaping traversal or symlink escape) and non-regular files. An existing path must pass the same
  no-follow descriptor/type/containment checks before being recorded; failures
  that cannot establish this safety are not candidates. Watching a rejected image
  grants **no access**, resource or capability: all rendering checks still apply.
  Record the policy-resolved reference spelling after the descriptor checks, not
  the `F_GETPATH` spelling, which may select a different hard-link alias. Distinct
  referenced hard-link paths remain separate bounded triggers; bytes/capabilities
  are still deduplicated by inode.
- `AssetPolicy`/`ImageBatch` currently drops file URLs after identity checks. Extend
  it to return `resolvedPaths: Set<String>` alongside the existing results, computed
  from the same validated resolution. No second resolution path is added.
- The set is capped at `ImageLimits.uniqueImages` (256) existing regular-file
  candidates (accepted or content/budget-rejected) plus up to 256 missing candidates. Generation order matters: a report from a stale generation is ignored
  (`requireCurrent`).

### Integration in `DocumentRefresh`

- `start()` creates the `AssetWatcher` after the directory watcher. If FSEvents stream
  creation fails, refresh still works without image watching: it logs one diagnostic
  line with no document content, and keeps the existing behavior (Cmd-R).
- Before awaiting the renderer, begin a bounded in-flight event window. Keep one
  pending bit if any non-source event under the physical root (or any loss/root
  flag) arrives, even when the previous watch set is empty. No event path is retained.
- `updateAssetPaths(_ paths: Set<String>, generation: Int)` replaces the watch set if
  the generation is current, ends that window and requests one debounced reload
  when an event was recorded and the new set is nonempty. This conservative replay
  covers newly referenced images changed between batch read and commit, including
  the first render. A failed/cancelled current render or close clears the window.
- An asset event calls the existing `reload(debounce: true)`. It does not compare the
  Markdown snapshot, so an unchanged `.md` still re-renders. Existing generation,
  cancellation, retry, warning, and close rules apply unchanged.
- `close()` stops and invalidates the stream (`FSEventStreamStop`,
  `FSEventStreamInvalidate`, `FSEventStreamRelease`) before returning. A closed session
  cannot publish (existing test pattern).

### Noise control

- Ordinary exact events for the Markdown file itself are ignored by the asset watcher;
  the existing watchers handle it, which avoids double reloads. Loss/root flags still
  cause conservative reloads even if the reported path is not a watched image.
- Event bursts collapse through the existing 200 ms debounce.
- A huge directory tree (for example a document in `$HOME`) produces many events.
  Filtering uses watch/ancestor set lookups per path, with no I/O. Unreferenced
  file events do not trigger reloads; ancestor-directory and loss/root events may
  conservatively reload because their affected descendants are not individually known.
  During rendering, an unreferenced in-root event may also cause one replay after
  a nonempty committed set: the next references are not yet authoritative.

## Security and contract impact

- The trigger-only design keeps all reads inside `AssetPolicy`. FSEvents paths are
  never opened directly.
- No entitlements, CSP, renderer, or vendored asset changes.
- README "Asset-only changes need Cmd-R" becomes "referenced local images refresh
  automatically; Cmd-R still forces a reload". ARCHITECTURE.md flow and module table get the
  watcher.

## Acceptance

- B1: In-place overwrite, atomic replace, delete, and recreate of `img/a.png`
  referenced from `doc.md` each produce exactly one re-render within 1 s (native test +
  isolated probe). Delete shows the existing placeholder. Replacing the whole `img/`
  directory (`mv tmpdir img` after moving the old directory aside) also refreshes;
  native matching tests cover ancestor events and all four loss/root flags.
- B2: Creating a referenced-but-missing image refreshes and displays it, including
  `New.png` referenced then `new.png` created on a case-insensitive volume. Canonically
  equivalent NFC/NFD paths match on either volume type. A zero-size, mid-write, invalid
  or over-budget contained regular candidate stays watched across a placeholder
  commit and refreshes when rewritten validly, without receiving a capability while rejected.
- B3: Changing an unreferenced file, a symlink-escape target, or a file outside the
  root triggers no render (completed generation unchanged after 500 ms).
- B4: Works for documents directly under `/tmp` (physical-path matching).
- B5: After `close()`, image changes publish nothing. Internal operation spies wrap
  real C stream calls and verify Stop → Invalidate → Release exactly once on stop,
  deinit and session close, with the live-stream count returning to zero even when
  the watcher object is retained after close.
- B6: Existing native, watcher, WebKit, and hardening suites pass unchanged.
