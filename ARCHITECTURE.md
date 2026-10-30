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
| `DocumentRefresh.swift` | One refresh session per window: parent-directory and file watchers, 200 ms debounce, generation counter and cancellation, retries, warning/displayed state. |
| `DirectoryWatcher.swift` | Dispatch filesystem-event source over `O_EVTONLY\|O_NONBLOCK\|O_NOFOLLOW` descriptors; rejects FIFOs, nonregular targets and final-component symlinks. |
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
  └─ reload(): DocumentIO bounded read ──► render(source, generation)
                                                  │
RenderHost.render                                 ▼
  1. JS prepareMarkdown → image and link references
  2. DocumentIO image batch → AssetGateway.stage (containment, budgets)
  3. LinkPolicy classifies links
  4. JS stage → DOMPurify-sanitized DOM → commit; native capability commit
```

Each change bumps a generation number. Stale reads and renders are cancelled, and
a closed session cannot publish. When a read fails, the last good preview stays on
screen with an "out of date" warning. Recreating the file clears the warning.

## Security boundaries

Markdown is treated as hostile.

- **Source reads:** no-follow, nonblocking, regular files only, 10 MiB cap, identity re-checked with `fstat`. The source file is never written.
- **Watchers:** strict no-follow on the final component. The parent directory is resolved with `realpath` before it is watched, which handles symlinked parents such as `/tmp` → `/private/tmp`.
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
| `scripts/test-watchers.py` | Four watcher scenarios, each in its own process with a 10 s limit (FIFO and `/tmp`). |
| `scripts/test-renderer-assets.mjs`, `test-reference-performance.mjs` | Renderer asset and performance checks (Node). |
| `scripts/test-packaging.py`, `test-release-verification.py`, `verify_assets.py` | Bundle, signature, tamper and install-guard checks. |
| `scripts/build-renderer.mjs` (`npm run build`) | Regenerates vendored renderer assets, notices and manifest from pinned npm deps. |

Evidence from verification runs is written under `.build/*-evidence/`. Dated
results are recorded in [TEST_RESULTS.md](TEST_RESULTS.md).
