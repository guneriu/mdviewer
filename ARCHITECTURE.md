# MDViewer architecture

MDViewer is a native macOS app (Swift, AppKit) that renders untrusted Markdown in
a locked-down `WKWebView`, using a bundled JavaScript renderer. Everything runs
locally: no server, no network, no runtime dependency downloads.

Product and security contract: [specification](docs/specs/2026-10-29-mdviewer-v1-design.md).
Milestones: [implementation plan](docs/plans/2026-10-29-mdviewer-v1.md).

## Package layout

| Path | Role |
| --- | --- |
| `Package.swift` | SwiftPM (tools 5.9, macOS 13): products `MDViewer` (app executable) and `MDViewerCore` (library), plus test targets `MDViewerCoreTests` and `M0Integration`. |
| `Sources/MDViewer/` | App shell. `main.swift` is the entry point. `AppDelegate.swift` handles open events and keeps one window per canonical file. `DocumentWindow.swift` owns the window UI and connects refresh to rendering. |
| `Sources/MDViewerCore/` | Testable core and security logic (table below). |
| `web/renderer.js` | Renderer source: markdown-it, DOMPurify and highlight.js glue, which stages the DOM. |
| `Resources/Web/` | Vendored runtime assets copied into the bundle: `shell.html`, the built `renderer.js`, `styles.css`. |
| `Resources/Notices/`, `THIRD_PARTY_NOTICES.md`, `vendor-manifest.json` | Licenses and hash/provenance inventory for the vendored assets. |
| `Packaging/` | `Info.plist` (app, document types, `LSHandlerRank=Alternate`) and `Integration-Info.plist` (probe bundle without document types). |
| `scripts/` | Build, package, install and verification entry points (see below). |
| `Tests/MDViewerCoreTests/` | Swift Testing unit tests (asset policy, watchers, location, refresh, links). |
| `Tests/M0Integration/` | Isolated probe executable that drives real WebKit and watchers without launching the actual app. |
| `Fixtures/` | Markdown and image fixtures, including hostile and Unicode-named files. |

### `MDViewerCore` modules

| File | Responsibility |
| --- | --- |
| `DocumentLocation.swift` | Validates a document URL, derives `canonicalURL` and `assetRoot`, and performs the bounded source read (10 MiB cap, regular file only, `O_RDONLY\|O_NONBLOCK\|O_NOFOLLOW`, `fstat` stable before and after). |
| `DocumentIO.swift` | Shared serial actor (`DocumentIO.shared`) used for all source and image reads, off the main thread. |
| `DocumentRefresh.swift` | One refresh session per window: source and optional asset watchers, 200 ms debounce, generation counter and cancellation, retries, warning/displayed state. |
| `DirectoryWatcher.swift` | Dispatch filesystem-event source over `O_EVTONLY\|O_NONBLOCK\|O_NOFOLLOW` descriptors; rejects FIFOs, nonregular targets and final-component symlinks. |
| `AssetWatcher.swift` | Per-document FSEvents stream with bounded committed image paths, physical/case-aware/Unicode-normalized matching, ancestor and loss/root rescan triggers, and idempotent lifetime cleanup. |
| `RenderHost.swift` | `WKWebView` lifecycle: nonpersistent data store, content-blocking rules, navigation policy, render pipeline. |
| `AssetGateway.swift` | `mdviewer:` URL-scheme handler. Serves only registered bundle resources and per-render image capabilities, enforces containment and image budgets, sets CSP. |
| `LinkPolicy.swift` | Classifies link targets: same-document, local Markdown, external (http/https/mailto), reveal-in-Finder, or blocked. |

## Runtime flow

```
Finder / `open` / pi-files
        │  application(_:open:)                     AppDelegate.swift
        ▼
DocumentLocation(url) ── canonical URL ──► existing window? focus it
        │ new
        ▼
DocumentWindow ──► RenderHost (WKWebView + AssetGateway on mdviewer:)
        │
        ▼
DocumentRefresh.start()
  ├─ DirectoryWatcher(realpath(parent))   ← atomic saves, delete/recreate
  ├─ DirectoryWatcher(canonical file)     ← in-place writes (rebound on change)
  ├─ AssetWatcher(realpath(parent))       ← referenced image/ancestor/loss events
  └─ reload(): DocumentIO bounded read ──► render(source, generation)
                                                  │
RenderHost.render                                 ▼
  1. JS prepareMarkdown → image and link references
  2. DocumentIO image batch → AssetGateway.stage (containment, budgets)
  3. LinkPolicy classifies links
  4. JS stage → DOMPurify-sanitized DOM → commit; native capability/link commit
  5. requireCurrent → onAssetPaths(batch.resolvedPaths, generation)
     → DocumentRefresh.updateAssetPaths → replace AssetWatcher trigger set
```

Each change bumps a generation number. Stale reads and renders are cancelled, and
a closed session cannot publish. When a read fails, the last good preview stays on
screen with an "out of date" warning. Recreating the file clears the warning.

## Referenced image refresh

The [image-refresh design](docs/specs/2026-10-30-image-auto-refresh-design.md)
adds a trigger-only FSEvents stream under the physical document root. Only a
successful current render publishes a replacement path set; failed, stale and
closed renders cannot change it. An empty successful render clears it. Events use
`reload(debounce: true)`, bypassing only the source snapshot filter, not any read,
render, generation or capability checks. Startup failure logs a content-free
fallback diagnostic once and leaves source watching and manual Reload available.
Before rendering, the watcher opens a bounded pending-event window, including on
first render with an empty set. It retains at most 512 normalized in-root non-source
paths with directory-event metadata. Publishing a nonempty current set consumes
the window and requests one debounced reload only for an exact new watched path
or a directory event in its ancestor set. Overflow or loss/root flags mark unknown
work and conservatively replay once. Failed/cancelled renders and close clear the
window. Newly referenced image changes between batch read and commit are not lost;
repeated unrelated writes do not chain renders. Retained event paths are never opened.
An internal default-true `startsNativeStream` parameter is disabled only for injected
unit events; product construction and real-event probes always start the stream.

`AssetPolicy` collects at most **256 existing contained regular-file paths + 256
missing paths** within the 2,048-reference scan limit. Existing ancestors of missing
paths are physically resolved and containment checked. Dangling/escaping symlinks
and nonregular files are excluded. Content-, format- or budget-rejected regular
candidates remain triggers but receive no image capability. Physical paths use
canonical Unicode decomposition and case folding only when volume metadata
explicitly reports case-insensitive names; unknown capability keeps case
distinctions. This handles `/tmp` → `/private/tmp`, Unicode spellings and creation
of a differently cased missing image on a case-insensitive volume.

Each stream uses file events, no-defer and watch-root flags, 0.1 s latency and the
main dispatch queue. Exact referenced paths or strict ancestor-directory events
trigger a debounced full reload. Must-scan, user/kernel-dropped and root-changed
flags conservatively reload a nonempty watch set. Ordinary unreferenced/sibling
and outside events are ignored, as is the source file's own exact event (existing
source watchers handle it). Callback event paths are copied while valid, matched
in memory and **never opened, resolved or used to grant access**. The retained C
context uses a weak owner; stop/deinit break callbacks, stop/invalidate/release the
stream, and queued events cannot publish after close.

## Content-anchored refresh and Follow Changes

The [scroll-anchor design](docs/specs/2026-10-30-scroll-anchor-follow-changes-design.md)
extends the accepted-commit path, not the native capability transaction. Staging
assigns each sanitized top-level block a private JS-array key:
`tagName:FNV-1a(textContent)#occurrence`. FNV-1a hashes UTF-16 code units in one
linear pass over a single cached `textContent` read per block; keys are never HTML
attributes or persisted state. Duplicate text is distinguished by occurrence in
document order; this is a heuristic identity, not a semantic diff.

An accepted commit captures the first old block with `bottom > 0`, then replaces
the DOM and restores that key to its saved viewport top. If it disappeared, the
nearest surviving predecessor uses **its own** saved top; otherwise both pixel
coordinates are clamped to the new bounds. Rejected generations change neither
the committed keys nor viewport state. For at most one second, image load/error
events re-apply the final anchor without awaiting decoding or delaying commit.
Listeners retire on scroll differing from renderer-owned coordinates, wheel/key
input, fragment navigation, the next accepted commit, or timeout.

Follow Changes compares old/new key sequences. On a refresh, the first changed
block (last remaining block for a trailing deletion) is centered and highlighted
for 1.2 seconds only if it is off-screen after anchoring and following is enabled.
That followed block becomes the late-image anchor. A new accepted commit clears
the previous highlight; reduced motion uses a static temporary background instead
of animation. First render never follows.

`AppDelegate` owns the checked View item and the sole persisted Bool,
`MDViewerFollowChanges` (default false). It updates all open windows and passes the
value into new windows before `RenderHost.load()`. `RenderHost` retains the Bool
across reload/invalidation/process recovery, serializes and awaits JS application,
and re-applies a changed value before publishing initial readiness. Only the
current shell epoch may release queued rendering, followed by `onReady`; stale
completions are ignored and setter failures report through `onFailure`. Existing
recovery callbacks still queue preview work before initialization finishes. No
document paths, block keys or scroll positions are stored by this preference.

## Security boundaries

Markdown is treated as hostile.

- **Source reads:** no-follow, nonblocking, regular files only, 10 MiB cap, identity re-checked with `fstat`. The source file is never written.
- **Watchers:** source descriptors retain strict no-follow on the final component. The parent directory is resolved with `realpath` before it is watched, which handles symlinked parents such as `/tmp` → `/private/tmp`. Asset event paths are trigger-only strings; only bounded policy-validated paths from a committed render are authoritative.
- **Images:** must be strict descendants of the document directory after symlink resolution, re-checked through a second no-follow descriptor. Formats: PNG, JPEG, GIF, WebP. Budgets: 25 MiB per file, 64 MiB per batch, 256 unique files, 2,048 refs, 16,384 px per axis, 16 MP per image, 64 MP per batch, 32 frames.
- **WebKit:** ephemeral data store, popups disabled, content rules block network schemes, CSP denies network/connect/frame/object, and the custom scheme serves only exact registered GETs.
- **Renderer:** raw HTML is off and output is sanitized with DOMPurify. Custom-scheme URLs survive sanitization only if they match capabilities the native side issued.
- **Not sandboxed:** the app is not App Sandbox-enabled, so containment is enforced by the app, not the OS.

## Build, package and verification

| Entry point | Purpose |
| --- | --- |
| `scripts/package.sh` (`CONFIGURATION=release` optional) | Verify assets, run `swift build --build-system swiftbuild`, assemble and ad-hoc sign `.build/MDViewer.app` or `.build/release-package/MDViewer.app`. |
| `scripts/install.sh --dry-run \| --install [--replace]` | Guarded copy to `~/Applications/MDViewer.app`, with staged verification and rollback. Never launches the app or sets defaults. |
| `scripts/test-swift.sh` | Native Swift Testing suite (loads the Swift Testing macro plugin; do not use bare `swift test`). |
| `scripts/test-webkit.sh` | Isolated debug/release verification through `verify_m0.py`: package, probe bundle, real WebKit, watcher scenarios, fixture hashes. |
| `scripts/test-watchers.py` | Eight watcher scenarios / 44 checks, each in its own process with a 10 s limit (FIFO, source `/tmp`, image events/directory replacement/filtering/physical `/tmp`). |
| `scripts/test-renderer-assets.mjs`, `test-reference-performance.mjs` | Renderer asset and performance checks (Node). |
| `scripts/test-packaging.py`, `test-release-verification.py`, `verify_assets.py` | Bundle, signature, tamper and install-guard checks. |
| `scripts/build-renderer.mjs` (`npm run build`) | Regenerates vendored renderer assets, notices and manifest from pinned npm deps. |

Evidence from verification runs is written under `.build/*-evidence/`. Dated
results are recorded in [TEST_RESULTS.md](TEST_RESULTS.md).
