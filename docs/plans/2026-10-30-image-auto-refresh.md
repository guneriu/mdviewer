# Referenced Image Auto-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Follow the operator's single-writer and review rules.

**Goal:** Automatically refresh when an allowed referenced image changes or a contained missing image appears, without adding per-image descriptors or new read privileges.

**Architecture:** Extend the existing image-policy result with validated physical candidate paths, publish them only after a generation-valid DOM/capability commit, and replace a window-local FSEvents watch set. The stream only matches normalized paths and requests the existing debounced reload; every subsequent image read still passes the unchanged security/budget pipeline.

**Tech Stack:** Swift, CoreServices/FSEvents, Darwin, Swift Testing, AppKit/WKWebView, Python timeout harnesses.

**Spec:** [Automatic refresh when referenced images change](../specs/2026-10-30-image-auto-refresh-design.md).

**Execution order:** Feature **1 → 3 → 8 → 7**. Execute after the scroll plan and before CLI/Quick Look. Re-read `Sources/MDViewerCore/RenderHost.swift` after feature 1; retain its Follow Changes readiness behavior. Do not edit renderer assets for this feature.

**Authorization:** This is a future implementation plan. Planning runs none of the commands below. Never launch/install/register the actual app, change defaults, use `open`/`lsregister`, or set `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES`. Commit steps are future checkpoints only. Every watcher/probe scenario must run in a timeout-bounded child process and clean up only its own UUID fixture.

## Verified file map

- Create `Sources/MDViewerCore/AssetWatcher.swift`: one recursive physical-root FSEvents stream, canonical/case-aware watch and ancestor sets, event-flag handling and deterministic stop.
- Modify `Sources/MDViewerCore/AssetGateway.swift`: `ImageBatch.resolvedPaths`; shared validated resolution for existing regular-file and missing candidates, even when content/budgets fail; preserve `AssetPolicy` reads and budgets.
- Modify `Sources/MDViewerCore/DocumentRefresh.swift`: stream lifecycle, current-generation `updateAssetPaths`, degradation on stream failure, debounced asset trigger.
- Modify `Sources/MDViewerCore/RenderHost.swift`: report paths only after commit and `requireCurrent`.
- Modify `Sources/MDViewer/DocumentWindow.swift`: connect host reports to refresh session.
- Modify `Tests/MDViewerCoreTests/AssetPolicyTests.swift`, `Tests/MDViewerCoreTests/DocumentRefreshTests.swift`: path-policy, stale report and closed/failure tests.
- Create `Tests/MDViewerCoreTests/AssetWatcherTests.swift`: path matching and stream lifetime regressions.
- Modify `Tests/M0Integration/WatcherProbe.swift`, `Tests/M0Integration/Probe.swift`, `scripts/test-watchers.py`: native image-event scenarios in separate 10 s child processes.
- Modify `Tests/M0Integration/RefreshProbe.swift`: real WebKit changed image/placeholder and committed-path reporting tests, called from existing refresh flow.
- Final docs: `README.md`, `ARCHITECTURE.md`, `TEST_RESULTS.md`.

## Review follow-up (2026-10-30)

- [x] P1: Red → restore standardized in-root traversal → green; escaping paths
  remain excluded from rendering and watch sets, with descriptor guards unchanged.
- [x] P2a: Red first-render/new-reference event-loss tests → one-bit in-flight
  recording and debounced replay after current nonempty publication → green.
  Clear pending state on failure/cancellation/empty commit/stop; never read event paths.

## Source reconciliation and invariants

`Sources/MDViewerCore/AssetGateway.swift:11-15` defines the **instance property** `ImageLimits.uniqueImages = 256`, matching the spec. Use that spelling; do not introduce a competing constant. `ImageBatch` currently exposes `references`, `resources`, counters, but no paths. The current policy throws one `forbiddenAsset` error for failed opens; record `errno == ENOENT` at the open site before throwing so only genuine missing candidates become triggers.

An existing candidate path must come from the already containment-checked `F_GETPATH` result and pass no-follow/type checks, but enter the watch set **before** content/format/decode/budget rejection. Keep zero-size, mid-write, invalid-format and over-budget regular files watched so a valid rewrite can recover. Inode deduplication remains intact; hard-link aliases may have distinct trigger paths. Retain at most `limits.uniqueImages` existing regular-file candidates (accepted or content/budget-rejected) plus `limits.uniqueImages` missing paths (default 256 + 256); the combined `resolvedPaths` is at most 512, and the 2,048 reference cap still applies. These are trigger caps, not extra image read/resource budgets.

Do not turn arbitrary failures into missing candidates: bad schemes/structurally invalid local paths, escaping traversal after standardization, escaping symlinks and non-regular files (including FIFOs) are excluded. Existing paths whose no-follow/type/containment safety cannot be established are excluded too. An unsupported extension remains blocked from rendering, but is not itself a reason to drop an otherwise contained regular-file trigger. Watching content/budget-rejected candidates grants no file access, resource or capability. Resolve missing candidates through the same factored policy resolver: physical existing ancestors plus the missing suffix, with strict descendant containment. This must work for a missing leaf and a missing nested directory under `/tmp`; no watcher-side URL resolution or filesystem I/O is allowed. Existing safeguards (`O_NOFOLLOW`, `O_NONBLOCK`, `fstat`, descriptor containment, limits) must remain.

### Task 1: Return a bounded, validated physical image watch set

**Files:** Modify `Sources/MDViewerCore/AssetGateway.swift`, `Tests/MDViewerCoreTests/AssetPolicyTests.swift`.

- [ ] **Step 1 — Write failing policy tests.** Use UUID roots and the existing valid 1 px PNG fixture. Assert accepted `a.png`, contained missing `img/missing.png`, and missing-directory `future/a.png` appear as physical paths, while scheme/traversal/symlink-escape/non-regular cases produce no paths. Add zero-size and invalid rasters, an unsupported-format regular file and sparse oversized file: each stays in `resolvedPaths` but not `resources`/`references`. Retain FIFO, in-root/out-of-root symlink, Unicode composed/decomposed filename and hard-link alias cases. Use `Darwin.realpath` in the test oracle for the root rather than Foundation's `/tmp` spelling. Minimal assertion shape:

```swift
let batch = AssetPolicy.images(references: ["a.png", "img/missing.png", "../outside.png",
    "https://example.invalid/a.png", "https://example.invalid/a.svg"], root: root)
#expect(batch.resolvedPaths == Set([
    physicalRoot.appendingPathComponent("a.png").path,
    physicalRoot.appendingPathComponent("img/missing.png").path
]))
#expect(batch.resources.count == 1)
```

Define `physicalRoot` in the test from a successful `realpath(root.path, nil)` and free the returned pointer with `defer`. Add small custom-limit cases: `limits.uniqueImages = 1`, two allowed distinct resources and two missing paths; assert no more than one existing and one missing path is retained. With spare trigger capacity, an over-budget regular path **must** enter the set without a resource. Add a truncate→placeholder commit→valid rewrite regression so rejected content cannot drop its trigger.
- [ ] **Step 2 — Run red.** `bash scripts/test-swift.sh`. Expected: compile failure for absent `resolvedPaths`; keep red output as evidence.
- [ ] **Step 3 — Implement the additive batch field and shared resolver.** Add:

```swift
public fileprivate(set) var resolvedPaths: Set<String> = []
fileprivate var existingPaths: Set<String> = []
fileprivate var missingPaths: Set<String> = []
```

Factor the current scheme/relative-path/containment validation inside `AssetPolicy`, not `AssetWatcher`. Produce a single physical candidate for the existing open path and the missing-path branch. Separate extension/content acceptance from trigger eligibility: keep the current allowed formats for gateway resources, but perform bounded no-follow regular-file/descriptor containment validation before returning a content/format rejection. For nonexistent descendants, walk to the nearest existing ancestor, resolve it with POSIX `realpath`, append only the validated missing components, and re-check component containment against the physical root; reject permission/errors other than ENOENT. Check final-component symlinks/escaping ancestors before recording a missing candidate. Keep the existing no-follow/nonblocking descriptor open and descriptor-based containment check. At an ENOENT open failure, record only a policy-valid missing path if the missing cap permits, then preserve the existing failure/placeholder result. After `fstat` establishes a regular file and `F_GETPATH` establishes containment, record the descriptor path in `existingPaths` if that cap permits, before zero-size/format/byte/pixel/frame/decode checks and before accepted-inode reuse returns. Do not read extra raster bytes or relax any rejection to obtain a trigger. Compute `resolvedPaths = existingPaths.union(missingPaths)` without adding reads to event callbacks. Preserve rejection byte accounting and reference/resource deduplication.
- [ ] **Step 4 — Run green.** `bash scripts/test-swift.sh`. Expected: physical/existing-rejected/missing/bounds tests and all existing hardening/image-budget cases pass. Neither missing nor rejected candidates confer gateway capabilities.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewerCore/AssetGateway.swift Tests/MDViewerCoreTests/AssetPolicyTests.swift && git commit -m "feat: report validated image refresh candidate paths"`.

### Task 2: Build a trigger-only FSEvents wrapper

**Files:** Create `Sources/MDViewerCore/AssetWatcher.swift`, `Tests/MDViewerCoreTests/AssetWatcherTests.swift`.

- [ ] **Step 1 — Write failing matching/lifetime tests.** Exercise `receive(paths:flags:)` with parallel path/`FSEventStreamEventFlags` arrays. Canonically equivalent NFC/NFD paths trigger once per batch. Directory events at a strict ancestor (including the root and a missing nested directory) trigger; a sibling prefix such as `img-old` or an unreferenced file does not. Test each of MustScanSubDirs/UserDropped/KernelDropped/RootChanged at a nonmatching/source path, including combined flags; they trigger once with a nonempty watch set, never after stop or with an empty set. Ordinary source events trigger zero callbacks; `updatePaths` replaces watch and ancestor sets; stop is idempotent. Test pure matching with an internal case-sensitivity override: insensitive mode matches `New.png`/`new.png`, sensitive mode does not; both modes match canonical equivalents. Production derives the mode from root volume metadata. No 256-file/descriptor fixture is needed.

```swift
watcher.updatePaths([physicalRoot.appendingPathComponent("café.png").path])
watcher.receive(paths: [physicalRoot.appendingPathComponent("cafe\u{301}.png").path],
    flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)])
#expect(changes == 1)
watcher.stop()
watcher.receive(paths: [physicalRoot.appendingPathComponent("café.png").path],
    flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)])
#expect(changes == 1)
```

Place the test in `@MainActor`; define its UUID root and real stream before use, and defer `stop`/fixture cleanup. Keep C callback conversion separate from this testable string-batch handler.
- [ ] **Step 2 — Run red.** `bash scripts/test-swift.sh`. Expected: `AssetWatcher` is absent.
- [ ] **Step 3 — Implement one stream and bounded filtering.** Public surface:

```swift
@MainActor
public final class AssetWatcher {
    public init(root: URL, document: URL, onChange: @escaping () -> Void) throws
    public func updatePaths(_ paths: Set<String>)
    public func stop()
    internal func receive(paths: [String], flags: [FSEventStreamEventFlags])
}
```

Import CoreServices. Resolve root/document physical spellings once, not on events. Use `FSEventStreamCreate`, `kFSEventStreamEventIdSinceNow`, 0.1 s latency and exactly `FileEvents | NoDefer | WatchRoot`; use `FSEventStreamSetDispatchQueue(stream, .main)`. Without `UseCFTypes`, decode callback `eventPaths` as the supplied `char **`; copy both paths **and** parallel `eventFlags` while the callback buffers are valid. Pass them together to `receive(paths:flags:)`; never discard flags. Read `root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames` once during initialization; only false enables case folding (nil preserves case). Use a shared normalization function on watched paths, ancestors, source and events: `decomposedStringWithCanonicalMapping`, then `.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))` only in insensitive mode, then canonical normalization again. APFS preserves names as written; NFD event spelling is not guaranteed.

`updatePaths` normalizes once and precomputes a set of every strict component ancestor back through the watched physical root (not string prefixes or ancestors outside it). Reject more than 512 supplied watch paths defensively. `receive` rejects stopped/mismatched-array/empty-watch batches; first check these loss/root flags before ordinary source exclusion:

```swift
let rescanFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
for (path, flag) in zip(paths, flags) {
    if flag & rescanFlags != 0 { onChange(); return }
    let key = normalize(path)
    if key == documentPath { continue }
    if watchedPaths.contains(key) ||
       (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 &&
        ancestorPaths.contains(key)) {
        onChange(); return
    }
}
```

Here `documentPath`, `watchedPaths` and `ancestorPaths` are pre-normalized stored values; `normalize(_:) -> String` uses the root's stored case mode. There is no filesystem I/O or descendant scan in `receive`. Ancestor/loss events only request reload from the existing set: never add event paths to it. Conservative directory/loss triggers are the bounded exception to ignoring unreferenced file events.

Use a retained callback-context box with FSEventStreamContext retain/release callbacks, not an unsafe unowned pointer to the watcher. Deliver on the main queue and isolate state there. Break the callback on `stop`; then call `FSEventStreamStop`, `FSEventStreamInvalidate`, `FSEventStreamRelease`, clear stream/context references, and make stop idempotent. Deinit performs equivalent cleanup. If creation/start fails, dispose any partially initialized stream and throw; never leak a callback box or descriptor. The context must not strongly retain the watcher in a cycle.
- [ ] **Step 4 — Run green.** `bash scripts/test-swift.sh`. Expected: normalization/case/ancestor/loss-flag/filtering/update/stop cases pass. Inspect the implementation to confirm there is no per-image `open`, `stat`, `realpath`, or descriptor loop in `receive`.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewerCore/AssetWatcher.swift Tests/MDViewerCoreTests/AssetWatcherTests.swift && git commit -m "feat: watch referenced image paths with FSEvents"`.

### Task 3: Integrate stream lifecycle and current-generation path updates

**Files:** Modify `Sources/MDViewerCore/DocumentRefresh.swift`, `Tests/MDViewerCoreTests/DocumentRefreshTests.swift`.

- [ ] **Step 1 — Write failing refresh tests.** Start a session whose renderer calls `updateAssetPaths` with its generation; assert a stale generation cannot replace the last current set. Reload with identical Markdown and a matching asset event; assert the renderer runs again. Close, inject a matching batch, and assert no new render/completed generation. Add an injected stream-creation failure test: source rendering, warning/retry and Cmd-R paths still work without asset watching. Reuse the existing async `wait` helper and clean only the test's UUID root.

```swift
refresh.updateAssetPaths([allowedPath], generation: currentGeneration)
refresh.updateAssetPaths([unrelatedPath], generation: currentGeneration - 1)
#expect(!refresh.isClosed)
observedWatcher?.receive(paths: [allowedPath], flags: [0])
try await wait { refresh.completedGeneration > currentGeneration }
refresh.close()
let completed = refresh.completedGeneration
observedWatcher?.receive(paths: [allowedPath], flags: [0])
try await Task.sleep(nanoseconds: 350_000_000)
#expect(refresh.completedGeneration == completed)
```

Use an internal factory overload for failure injection returning the concrete `AssetWatcher`, with a closure that throws `POSIXError(.EIO)`; keep the existing public initializer source-compatible. In the successful injected factory, assign the new watcher to a local `var observedWatcher: AssetWatcher?` before returning it, so the snippet can inject real `receive(paths:flags:)` batches. Define `allowedPath`, `unrelatedPath` and `currentGeneration` from that fixture's physical paths and first completed render. No new public watcher protocol is needed.
- [ ] **Step 2 — Run red.** `bash scripts/test-swift.sh`. Expected: absent update/factory/lifecycle integration fails compile or the matching event does not render.
- [ ] **Step 3 — Implement refresh integration.** Create the stream after the physical parent watcher is established in `start()`, before initial reload. Stream callbacks use `[weak self]` and `self?.reload(debounce: true)`, **not** `changed()` (the Markdown snapshot is unchanged). Add the guarded set handoff:

```swift
public func updateAssetPaths(_ paths: Set<String>, generation: Int) {
    guard !isClosed, latest == generation else { return }
    assetWatcher?.updatePaths(paths)
}
```

Initialize the watch set empty. Catch only stream creation/start failures; log one content-free line per session, such as `MDViewer: image auto-refresh unavailable; use Reload`, with no path/source bytes. Do not fail `start` or change displayed state for this optional failure. In `close`, mark closed/invalidate first, stop and clear the stream before returning, then preserve existing task/vnode cleanup. Leave retries, snapshots and source-watch rebinding unchanged. Deinit must not leave the stream active if the owner disappears without `close`.
- [ ] **Step 4 — Run green.** `bash scripts/test-swift.sh`. Expected: current-only replacement, unchanged-source asset reload, degraded initialization and post-close behavior pass alongside old retry/snapshot cases.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewerCore/DocumentRefresh.swift Tests/MDViewerCoreTests/DocumentRefreshTests.swift && git commit -m "feat: route asset changes through document refresh"`.

### Task 4: Publish paths only after committed render transactions

**Files:** Modify `Sources/MDViewerCore/RenderHost.swift`, `Sources/MDViewer/DocumentWindow.swift`, `Tests/M0Integration/RefreshProbe.swift`.

- [ ] **Step 1 — Write failing commit-report tests.** Attach a callback collector to a probe host. Render an accepted image plus missing candidate and assert one `(paths, generation)` report. Use the existing delayed-prepare/stage/commit hooks to invalidate older generations; assert none publishes paths. Throw from stage and assert the last successful report/watch set survives. Assert empty successful Markdown reports an empty set, and close prevents late publication.

```swift
var reports: [(Set<String>, Int)] = []
host.onAssetPaths = { paths, generation in reports.append((paths, generation)) }
try await render(host, source: "![a](pixel.png) ![missing](img/new.png)", root: root)
try check(reports.count == 1 && reports[0].0.count == 2,
          "only a successful commit reports accepted and missing candidates")
```

Define the collector around a fresh test host so earlier probe renders cannot contaminate its count.
- [ ] **Step 2 — Run red.** `bash scripts/test-webkit.sh`. Expected: absent `onAssetPaths` or report assertion fails.
- [ ] **Step 3 — Implement the commit-boundary callback.** Add `public var onAssetPaths: ((Set<String>, Int) -> Void)?`. Retain the `ImageBatch` already returned by `DocumentIO.shared.images`. In the existing success path, after JavaScript commit succeeds, `self.gateway.commit(stage)`, committed-link dictionary updates and `self.rebuildLinks()` complete, place the callback immediately after the final `try self.requireCurrent(version)` and before `completion(.success(version))`:

```swift
self.onAssetPaths?(batch.resolvedPaths, version)
```

These are the existing local names: `images` is the reference array, `batch` is the `ImageBatch`, and there is no separate `commitLinks` method.

Never emit from `prepareMarkdown`, `stage`, cancellation or catch paths. Clear callback in `close`. In `DocumentWindow`, after constructing `refresh` and before `host.load`/`refresh.start`, connect `host.onAssetPaths = { [weak self] paths, generation in self?.refresh.updateAssetPaths(paths, generation: generation) }`. Keep the main-actor/generation checks on both ends; a callback from a stale host is not authoritative. Wire the same handoff explicitly in the isolated live-refresh fixture (the probe does not construct `DocumentWindow`).
- [ ] **Step 4 — Run green.** `bash scripts/test-swift.sh && bash scripts/test-webkit.sh`. Expected: only committed current sets publish; prior DOM/capabilities and watch set survive renderer failure.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewerCore/RenderHost.swift Sources/MDViewer/DocumentWindow.swift Tests/M0Integration/RefreshProbe.swift && git commit -m "feat: publish image watch paths after render commit"`.

### Task 5: Verify real image events with bounded native child processes

**Files:** Modify `Tests/M0Integration/WatcherProbe.swift`, `Tests/M0Integration/Probe.swift`, `scripts/test-watchers.py`.

- [ ] **Step 1 — Add failing scenarios.** Extend the `CommandLine.arguments[1]` dispatch in `Tests/M0Integration/Probe.swift:258-278` and the lowercase `scenarios` tuple in `scripts/test-watchers.py:15-20` with `--asset-image-events`, `--asset-image-directory`, `--asset-image-filtering`, `--asset-tmp-parent`. Each creates its own fixtures, starts a `DocumentRefresh`, renders through a counting closure that obtains `AssetPolicy.images` paths and calls `updateAssetPaths`, and records successful render count/completed generation. The event scenario uses `img/a.png`: in-place overwrite, atomic file replace, delete, recreate and missing-file creation; wait for each render then allow a 500 ms quiet period and assert exactly one additional **completed render**, not one invalidation. Add whole-directory replacement in a separate `--asset-image-directory` child case: populate a UUID-owned `tmpdir/a.png` with different dimensions, move the old `img` aside, then run `mv tmpdir img` via absolute fixture paths (never merge into the still-existing directory). Expect the watched `img/a.png` to refresh within 1 s and exactly one settled completed render. This exercises the ancestor-directory event, not just exact file paths. The filtering scenario mutates an unreferenced sibling, an escaping symlink target and an outside file, waits 500 ms and asserts completed generation unchanged. Include Unicode-normalized event matching. On a case-insensitive fixture volume (detected with `volumeSupportsCaseSensitiveNames`), reference missing `img/New.png`, create `img/new.png` and assert a refresh; record an explicit skip on a case-sensitive volume, with both modes still covered by Task 2's native seam tests. The `/tmp` scenario owns `/tmp/MDViewer-asset-UUID.md` and a UUID image path, checks physical matching, closes then changes the image and asserts no publication.
- [ ] **Step 2 — Run red.** Build the dedicated probe, then run `python3 scripts/test-watchers.py "$(swift build --build-system swiftbuild --show-bin-path)/M0Integration"`. Expected: new cases identify any missing stream delivery/path matching; existing four cases remain unchanged.
- [ ] **Step 3 — Wire bounded scenario dispatch.** Keep Python's existing 10 s child-process timeout, UUID temporary directories and launch-services opt-in unset:

```python
# Append before the existing loop; retain its four existing pairs.
scenarios += (
    ("--asset-image-events", "ASSET IMAGE EVENTS PASSED"),
    ("--asset-image-directory", "ASSET IMAGE DIRECTORY PASSED"),
    ("--asset-image-filtering", "ASSET IMAGE FILTERING PASSED"),
    ("--asset-tmp-parent", "ASSET TMP PARENT PASSED"),
)
```

Add `else if` dispatch branches in `M0Integration.main()` for those exact flags, calling the matching async native methods; each method prints its matching success marker only after all checks pass. Update the runner's final scenario/check-count summary to the actual total. Explicitly remove `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES` from child environments. Retain `defer { refresh.close() }`. A test fixture may write its own PNG bytes; production never writes source/images. Count completed renderer callbacks separately from `invalidate()` increments so event-burst debounce behavior is measured correctly. Do not raise the one-second settled event budget or ten-second scenario limit; split a scenario into more child cases if the sum of deliberate quiet waits needs isolation.
- [ ] **Step 4 — Run green.** `swift build --build-system swiftbuild --product M0Integration`, then `python3 scripts/test-watchers.py "$(swift build --build-system swiftbuild --show-bin-path)/M0Integration"`. Expected: B1–B5 native event/filter/close checks pass within 1 s per image change and old FIFO/source watcher cases pass. If platform event coalescing produces duplicate completed renders, retain evidence and investigate; do not silently weaken “exactly one.”
- [ ] **Step 5 — Commit.** `git add Tests/M0Integration/WatcherProbe.swift Tests/M0Integration/Probe.swift scripts/test-watchers.py && git commit -m "test: cover bounded referenced image watcher scenarios"`.

### Task 6: Verify actual WebKit image replacement and hardening

**Files:** Modify `Tests/M0Integration/RefreshProbe.swift`; reuse the already existing defaulted `js(..., arguments:)` helper in `Tests/M0Integration/Probe.swift:20-24`.

- [ ] **Step 1 — Write failing browser assertions.** In a new live-refresh case, connect `onAssetPaths` to the refresh session and render `![a](img/a.png)` from a UUID document. Record the capability URL and image dimensions; overwrite with a second valid raster and assert a fresh capability URL and decoded dimensions within 1 s. Delete and assert `.blocked-image`; recreate and assert a loaded `<img>`. Start with missing `img/new.png`, create it and assert it loads. On a case-insensitive volume also reference `img/New.png` before creating `img/new.png`. Truncate a previously displayed regular image to zero bytes, wait for the placeholder commit, then write a valid raster and assert a loaded image without changing Markdown. Repeat for invalid/mid-write content and an over-budget regular image rewritten below budget; the rejected generation must expose no image capability but retain the trigger. Repeat atomic file and directory replacement and assert only one completed render after quiet. Test close while an event/render is queued. Use `naturalWidth > 0 && complete`, not URL changes alone:

```swift
try await waitUntil("replacement image decoded") {
    try await js(host, """
const image = document.querySelector('#document img');
return !!image && image.complete && image.naturalWidth > 0 && image.src !== oldURL;
""", arguments: ["oldURL": oldURL]) as? Bool == true
}
```

Define `oldURL` from the last successful DOM before mutating that fixture. Keep per-operation timing from the existing live-refresh test.
- [ ] **Step 2 — Run red.** `bash scripts/test-webkit.sh`. Expected: the new tests catch missing production handoff, stale capability reuse, a missing/case-matching gap or loss of content-rejected triggers; preserve any real failure.
- [ ] **Step 3 — Correct only observed wiring defects.** Keep all image reads in `DocumentIO`/`AssetPolicy`; the callback must remain `reload(debounce: true)`, never `changed()`, direct image reads or direct DOM mutation. Preserve the feature-1 scroll/follow behavior when an image-triggered full render occurs. No JS/CSS/vendor changes are needed.
- [ ] **Step 4 — Run green/full regression.** `bash scripts/test-swift.sh`; build/run the bounded watcher command from Task 5; `bash scripts/test-webkit.sh`; `CONFIGURATION=release bash scripts/test-webkit.sh`; `python3 scripts/verify_assets.py`; `node scripts/test-renderer-assets.mjs && node scripts/test-reference-performance.mjs`. Expected: B1–B6, hostile-content, source cap, FIFO, image budget and transaction tests pass with no generated asset diff.
- [ ] **Step 5 — Commit.** `git add Tests/M0Integration/RefreshProbe.swift && git commit -m "test: verify image only refresh in isolated WebKit"`. If implementation needed a correction, include only the implicated files from this plan's map.

### Task 7: Document automatic assets and scoped evidence

**Files:** Modify `README.md`, `ARCHITECTURE.md`, `TEST_RESULTS.md`.

- [ ] **Step 1 — Write the failing docs checklist.** Remove the claim “Asset-only changes need Cmd-R”; explain contained referenced image creation/deletion/overwrite, Cmd-R fallback, bounded FSEvents watching and no outside/unreferenced-file triggers (ancestor-directory and loss/root events conservatively reload).
- [ ] **Step 2 — Check baseline.** `rg -n 'Asset-only|Cmd-R|FSEvents|AssetWatcher' README.md ARCHITECTURE.md TEST_RESULTS.md`. Expected: the old limitation is still present or the new module/flow is missing.
- [ ] **Step 3 — Update docs.** User wording: “Referenced local images refresh automatically; Cmd-R still forces a reload. If image watching cannot start, Reload remains available.” Add `AssetWatcher.swift` to the architecture table and committed-path callback to runtime flow; document the 256 existing regular-file + 256 missing path caps, physical canonical/case-aware matching, ancestor and loss/root rescans, optional failure and trigger-only security boundary. Explain that content/budget-rejected regular candidates remain triggers but gain no access/capability. Record dated native/isolated browser timings, exactly-one completed render counts, filtering/close tests and the fact the actual app/Launch Services was not exercised.
- [ ] **Step 4 — Verify docs.** `git diff --check` and inspect the three-file diff. Expected: no stale asset-only limitation, no claims of new entitlements/network privileges or actual-app validation.
- [ ] **Step 5 — Commit.** `git add README.md ARCHITECTURE.md TEST_RESULTS.md && git commit -m "docs: describe automatic referenced image refresh"`.

## Acceptance coverage

B1 (file/directory replacement and loss flags) → Tasks 2–6; B2 (missing/rejected-content recovery, canonical/case matching) → Tasks 1–2, 5–6; B3 → Tasks 1–2 and 5; B4 → Tasks 1 and 5; B5 → Tasks 2–6; B6 → Task 6. Stream failure is optional degradation, not a bypass of source or asset security. A watcher event never supplies a capability or a new candidate set.
