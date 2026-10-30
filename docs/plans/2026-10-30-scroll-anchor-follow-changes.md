# Content-Anchored Scroll and Follow Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Follow the operator's single-writer and review rules.

**Goal:** Keep the reader's visible block stable through refresh and offer an opt-in, persistent Follow Changes toggle.

**Architecture:** Compute deterministic block identities in renderer-owned arrays after sanitization. Capture geometry immediately before an accepted DOM commit and restore the surviving anchor, then optionally follow the first changed block. AppKit owns one application-wide Bool; `RenderHost` retains and reapplies it whenever its shell becomes ready.

**Tech Stack:** JavaScript, markdown-it, DOMPurify, CSS, Swift/AppKit, WKWebView, Swift Testing, isolated M0Integration probes.

**Spec:** [Content-anchored scroll and Follow Changes](../specs/2026-10-30-scroll-anchor-follow-changes-design.md).

**Execution order:** Feature **1 → 3 → 8 → 7**: this plan, image auto-refresh, mdv CLI, Quick Look. `Sources/MDViewerCore/RenderHost.swift` is shared with image refresh and Quick Look: preserve its generation/capability transaction and re-read it before each subsequent plan.

**Authorization:** Planning is not execution approval. No commands in this document were run during planning. Implementation may use isolated probes, but must not launch/install/register the actual app, call `open`/`lsregister`, change document defaults, or set `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES`. Commit steps below are future checkpoints, not permission to commit during this docs-only task. Use only locally available pinned dependencies; if `npm ci --ignore-scripts` cannot run offline, stop rather than fetch from the network.

## Verified file map and constraints

- Modify `web/renderer.js`: `stageMarkdown`, `commitMarkdown`, new `window.setFollowChanges` and private identity/geometry helpers. Existing staging retains a `DocumentFragment` in `pendingDOM`; generation checks must stay before any visible mutation.
- Modify `Resources/Web/styles.css`: highlight with a reduced-motion override.
- Modify `Sources/MDViewerCore/RenderHost.swift`: stored setting, `setFollowChanges(_:)`, shell-ready application in `webView(_:didFinish:)` before releasing queued rendering (including recovery-triggered work).
- Modify `Sources/MDViewer/AppDelegate.swift`: checked View menu item, Cmd-Shift-F, `MDViewerFollowChanges` Bool, broadcast to existing/new windows.
- Modify `Sources/MDViewer/DocumentWindow.swift`: forwarding method; accept initial setting before `host.load()`.
- Modify `Tests/M0Integration/RefreshProbe.swift`: real WebKit geometry, late-image settling and preference lifecycle tests, called from existing refresh probe flow.
- Modify `scripts/test-reference-performance.mjs`: large single-block hashing regression alongside the existing many-reference budget.
- Regenerate `Resources/Web/renderer.js`, `vendor-manifest.json`, `THIRD_PARTY_NOTICES.md`, `Resources/Notices/THIRD_PARTY_NOTICES.md` together via `npm ci --ignore-scripts && npm run build`; do not hand-edit bundled JavaScript or hashes.
- Existing checks: `scripts/test-renderer-assets.mjs`, `scripts/test-reference-performance.mjs`, `scripts/test-webkit.sh`, `scripts/verify_assets.py`, `scripts/test-swift.sh`.
- Final docs: `README.md`, `ARCHITECTURE.md`, `TEST_RESULTS.md`.

Do not change sanitizer options, raw HTML policy, CSP, link routing, image capabilities, source access, or stored document state. No new DOM attributes for keys. The existing document generation dataset remains unchanged. First render has no old block sequence and must not follow/highlight. Fragment navigation, WebKit find and zoom stay separate APIs.

### Task 1: Prove and implement content-anchor restoration

**Files:** Modify `web/renderer.js`, `Tests/M0Integration/RefreshProbe.swift`, `scripts/test-reference-performance.mjs`; reuse the existing helpers in `Tests/M0Integration/Probe.swift` and regenerate the renderer inventory listed above.

- [ ] **Step 1 — Write the failing WebKit test.** Reuse the existing `Tests/M0Integration/Probe.swift:20-24` helper `static func js(_ host: RenderHost, _ script: String, arguments: [String: Any] = [:]) async throws -> Any`; it already forwards arguments to `callAsyncJavaScript`, so no helper/API change is needed. Add `testContentAnchors(_ host: RenderHost, root: URL) async throws` to the existing `M0Integration` extension and call it after the unchanged practical-scroll assertion in `testRenderTransactions`. Use the existing `render`, `js`, `check` helpers:

```swift
let original = (0..<300).map { "Paragraph \($0)\n\n" }.joined()
try await render(host, source: original, root: root)
_ = try await js(host, "scrollTo(0, 900); return true")
try await Task.sleep(nanoseconds: 80_000_000)
let anchor = try await js(host, """
const node = [...document.querySelector('#document').children]
  .find(n => n.getBoundingClientRect().bottom > 0);
return { text: node.textContent, top: node.getBoundingClientRect().top };
""") as! [String: Any]
let prefix = (0..<50).map { "Inserted \($0)\n\n" }.joined()
try await render(host, source: prefix + original, root: root)
let restored = try await js(host, """
const node = [...document.querySelector('#document').children]
  .find(n => n.textContent === text);
return node.getBoundingClientRect().top;
""", arguments: ["text": anchor["text"]!]) as! Double
try check(abs(restored - (anchor["top"] as! Double)) < 5,
          "inserting 50 blocks above preserves visible content within 5 px")
```

Add an A1 late-image variant: use a UUID-owned tall PNG above the captured block and delay assigning its fresh capability URL until 150 ms after commit (a probe-only `commitMarkdown` wrapper can temporarily remove/restore the committed image's `src`). Check the offset immediately after commit and again once `complete && naturalWidth > 0`, within the 1 s window. Repeat with an image error event; after explicit scroll, wheel and key input, dispatch another image event and assert it does not restore the old viewport. Restore the original wrapper after each case. Assert a second commit retires the first settling listeners/timer.

In `scripts/test-reference-performance.mjs`, add a separate `--block-anchor-child` mode using the existing 5 s child timeout and 4 s timing ceiling. Read `web/renderer.js`, extract the source-named `blockEntries(container)` helper up to the next top-level helper, and evaluate it with Node's `vm` (no DOM dependency). Parse one fenced code block containing `'x'.repeat(1_000_000)` with the existing markdown-it instance; supply its code text in a `PRE` fixture with a counted `textContent` getter. Assert exactly one getter read per block and a stable key; warm up once, then time five calls with a fresh counter each time. The getter count deterministically catches repeated reads even on fast machines. Label timing as an isolated hashing measurement, not full DOM/app performance. Preserve all six existing advisory reference cases and their individual 5 s/4 s limits; no renderer VM or 1,000-image benchmark exists in this script.
- [ ] **Step 2 — Run red.** `bash scripts/test-webkit.sh` and `node scripts/test-reference-performance.mjs`. Expected: geometry/late-image assertions fail under pixel-only restoration and the new hashing child fails because `blockEntries` is absent. Once keys exist, its getter count catches repeated `textContent` reads. Preserve real failures in `.build/` evidence, not Git; do not fabricate a performance failure or loosen 5 px/budgets.
- [ ] **Step 3 — Implement private identity and restore helpers.** At staging, index `staging.content.children` after sanitization/capability restoration. Retain `{node, key}` entries alongside `pendingDOM.content`; the nodes move with the fragment. Use occurrence numbers starting at 1:

```javascript
function blockEntries(container) {
  const counts = new Map();
  return [...container.children].map(node => {
    const text = node.textContent;
    let hash = 0x811c9dc5;
    for (let i = 0; i < text.length; i++) {
      hash = Math.imul(hash ^ text.charCodeAt(i), 0x01000193) >>> 0;
    }
    const base = `${node.tagName}:${hash.toString(16)}`;
    const occurrence = (counts.get(base) || 0) + 1;
    counts.set(base, occurrence);
    return { node, key: `${base}#${occurrence}` };
  });
}
function clampScroll(x, y) {
  scrollTo(Math.max(0, Math.min(x, Math.max(0, document.documentElement.scrollWidth - innerWidth))),
           Math.max(0, Math.min(y, Math.max(0, document.documentElement.scrollHeight - innerHeight))));
}
```

Keep `committedBlocks = []` in the renderer closure. Before replacing children, snapshot all old block tops/bottoms and `{x: scrollX, y: scrollY}`. Find the first old block with `bottom > 0`; walk backward from that index until its key exists in the new key→node map. After replacement, restore that node to **its own saved top**, not the deleted anchor's top: `clampScroll(position.x, scrollY + node.getBoundingClientRect().top - saved.top)`. If no match exists, clamp the saved pixel position. Update `committedBlocks` only after a generation-valid commit; rejected staging/commits must not touch anchors. Store keys in arrays, not HTML attributes.

At the end of each accepted commit, retain only the final anchor's live node/top and pixel fallback for a 1,000 ms settling window. Use capturing `load`/`error` listeners on `#document` filtered to `IMG`; re-run the same clamped restore when the anchor still belongs to this generation. Keep the correction synchronous with the image event, not an image `decode()` await: slow/failed images must not block a ready text commit or extend its capability transaction. Cancel the previous window before each new accepted commit; a rejected commit must not cancel the current one. Cleanup removes both image listeners, user-input listeners and the expiry timer. Stop on wheel, keydown, user scroll or `scrollToFragment`. Track the actual clamped coordinates after every renderer-owned scroll; a `scroll` event at those coordinates is its own correction, while a different position cancels settling (including scrollbar/other navigation). Retain no detached old nodes. Task 3 must select the final target after following, so late images never undo Follow Changes.
- [ ] **Step 4 — Rebuild and run green.** `npm ci --ignore-scripts && npm run build`, then `python3 scripts/verify_assets.py`, `node scripts/test-reference-performance.mjs` and `bash scripts/test-webkit.sh`. Expected: generated inventory verifies; A1, late-image/cancellation and old scroll assertions pass; the single-block getter/timing checks and six unchanged advisory cases pass within their child bounds.
- [ ] **Step 5 — Commit the scoped change.** `git add web/renderer.js Tests/M0Integration/RefreshProbe.swift scripts/test-reference-performance.mjs Resources/Web/renderer.js vendor-manifest.json THIRD_PARTY_NOTICES.md Resources/Notices/THIRD_PARTY_NOTICES.md && git commit -m "feat: anchor refreshed preview to visible content"`.

### Task 2: Lock down fallback and duplicate-block behavior

**Files:** Modify `Tests/M0Integration/RefreshProbe.swift`, `web/renderer.js`; regenerate renderer inventory if implementation changes.

- [ ] **Step 1 — Write regression cases** in `testContentAnchors`: capture the first visible and preceding block's text/top, delete the visible block from a long unique sequence, and assert preceding block returns to its own saved offset within 5 px; delete all old blocks and assert `0 <= scrollY <= max(0, scrollHeight-innerHeight)`; render duplicate paragraphs and assert each duplicate can anchor independently; replace a long document with one short paragraph and assert scroll is clamped. Use this geometry assertion with the existing `js`/`check` helpers:

```swift
let bounded = try await js(host, """
return scrollY >= 0 && scrollY <= Math.max(0,
  document.documentElement.scrollHeight - innerHeight);
""") as? Bool
try check(bounded == true, "fallback remains within document bounds")
```

For duplicates, choose an unchanged duplicate occurrence; insertion of an identical earlier occurrence inherently changes occurrence identity and is not an editor-cursor mapping guarantee. Also retain a staged render, invalidate it, and verify releasing it changes neither visible blocks nor anchor state (extend the existing delayed-stage test).
- [ ] **Step 2 — Run red/characterize.** `bash scripts/test-webkit.sh`. Expected: new tests expose any missing predecessor/occurrence/bounds handling; if Task 1 already satisfies a case, retain it as a regression, not a fabricated failure.
- [ ] **Step 3 — Correct only fallback defects.** Use a single backward walk and key map, not repeated whole-document scans:

```javascript
let match = null;
for (let i = anchorIndex; i >= 0; i--) {
  if (newByKey.has(oldGeometry[i].key)) {
    match = { node: newByKey.get(oldGeometry[i].key), top: oldGeometry[i].top };
    break;
  }
}
```

If no block crosses the viewport (empty old sequence), use pixel fallback. Do not retain detached old nodes once the commit finishes.
- [ ] **Step 4 — Run green.** Rebuild vendored assets if changed; run `bash scripts/test-webkit.sh` and `node scripts/test-reference-performance.mjs`. Expected: all fallback assertions pass; the single-block hashing and six advisory reference cases retain their 5 s child/4 s timing bounds.
- [ ] **Step 5 — Commit.** Stage only files changed in this task and use `git commit -m "test: cover scroll anchor fallback and duplicate blocks"`.

### Task 3: Detect the first changed block and follow it only on refresh

**Files:** Modify `web/renderer.js`, `Resources/Web/styles.css`, `Tests/M0Integration/RefreshProbe.swift`; regenerate renderer inventory.

- [ ] **Step 1 — Write failing tests.** With 300 paragraphs and scroll at 900, edit the final paragraph: with setting false assert the previous anchor remains within 5 px and no flash exists; with true assert the changed block intersects the viewport and has `changed-flash`. Repeat for insertion and deletion at the end, unchanged refresh, and first render in a fresh host. Tests call `host.setFollowChanges` only after Task 4; in this task use `js(host, "window.setFollowChanges(enabled); return true", arguments: ["enabled": true])`. Add an assertion that the class disappears within a bounded wait after 1.2 s, and check reduced-motion stylesheet behavior in the asset check.
- [ ] **Step 2 — Run red.** `bash scripts/test-webkit.sh`. Expected: `window.setFollowChanges` is absent before implementation.
- [ ] **Step 3 — Implement the renderer flag, comparison, and CSS.** Compare old/new key arrays before mutating them:

```javascript
let followChanges = false;
window.setFollowChanges = enabled => { followChanges = enabled === true; };
function firstChangedIndex(before, after) {
  let i = 0;
  while (i < before.length && i < after.length && before[i].key === after[i].key) i++;
  return i === before.length && i === after.length ? -1 : Math.min(i, after.length - 1);
}
```

After anchoring, only when old blocks exist, the flag is true, and index is nonnegative, inspect the new block rect. If `rect.bottom <= 0 || rect.top >= innerHeight`, center it and add `changed-flash`; remove the class after 1,200 ms. Clear the previous flash timer/class on the next accepted commit. Use one flash timer, separate from Task 1's bounded image-settling timer; no observers, new attributes or message handlers. Start settling only after the final anchor/follow scroll, retaining the followed block's resulting top when following occurred. Test an off-screen changed block with a delayed image above it: it must remain visible after load, not jump back to the pre-follow anchor. Do not run follow logic from `scrollToFragment`, find or zoom.

```css
@keyframes changed-flash {
  from { background-color: var(--changed-highlight); }
  to { background-color: transparent; }
}
:root { --changed-highlight: #ffe599; }
@media (prefers-color-scheme: dark) { :root { --changed-highlight: #66551a; } }
.changed-flash { animation: changed-flash 1.2s ease-out; }
@media (prefers-reduced-motion: reduce) {
  .changed-flash { animation: none; background-color: var(--changed-highlight); }
}
```

- [ ] **Step 4 — Run green.** Rebuild assets; run `python3 scripts/verify_assets.py`, `node scripts/test-renderer-assets.mjs`, `bash scripts/test-webkit.sh`. Expected: off/on/first-render/deletion/unchanged cases pass; CSS introduces no accessibility announcements.
- [ ] **Step 5 — Commit.** Stage changed renderer, CSS, probe and regenerated inventory files; `git commit -m "feat: follow and highlight offscreen Markdown changes"`.

### Task 4: Retain the preference across WebKit shell lifecycles

**Files:** Modify `Sources/MDViewerCore/RenderHost.swift`, `Tests/M0Integration/RefreshProbe.swift`.

- [ ] **Step 1 — Write failing host tests.** Create a fresh `RenderHost`, call `setFollowChanges(true)` **before** `load()`, render two long documents with the final block changed, and assert the changed block becomes visible. Toggle false and assert anchoring without following. Call `load()` again and repeat true behavior; extend the existing bounded content-process recovery probe to assert true survives recovery. Close every test host with `defer`. Use the same DOM observations as Task 3, not a new debug bridge. Add a deterministic race: before `load()`, install a probe-only `.atDocumentStart` `WKUserScript` in `.page` that intercepts assignment of `window.setFollowChanges` with a configurable property setter and wraps the assigned function. Hold only its first call on a promise, exposing page-local held/release hooks; native initialization must await that promise. Start with true, wait boundedly until held, toggle false, queue a render, then release. Record applied values in the wrapper and assert false is applied before the queued render/`onReady`, with anchoring rather than following. Remove the user script/hooks when closing the test host. Repeat using the existing bounded process-recovery fixture while an apply is held, proving a stale completion cannot mark the replacement shell ready. No production message bridge or timing-dependent window is needed.
- [ ] **Step 2 — Run red.** `bash scripts/test-webkit.sh`. Expected: Swift compilation fails because the public setter is absent.
- [ ] **Step 3 — Add the host setter and readiness handoff.** Keep state in the host, not UserDefaults:

```swift
private var followChanges = false
private var applyingFollowChangesEpoch: Int?
public func setFollowChanges(_ enabled: Bool) {
    followChanges = enabled
    guard isReady, !closed else { return }
    applyFollowChanges(epoch: shellEpoch)
}
private func applyFollowChanges(epoch: Int) {
    guard !closed, shellEpoch == epoch, applyingFollowChangesEpoch == nil else { return }
    let applied = followChanges
    applyingFollowChangesEpoch = epoch
    webView.callAsyncJavaScript("await window.setFollowChanges(enabled); return true",
        arguments: ["enabled": applied], in: nil, in: .page) { [weak self] result in
        guard let self, !self.closed, self.shellEpoch == epoch,
              self.applyingFollowChangesEpoch == epoch else { return }
        self.applyingFollowChangesEpoch = nil
        switch result {
        case .failure(let error):
            self.shellFailed(error)
        case .success:
            if self.followChanges != applied {
                self.applyFollowChanges(epoch: epoch)
                return
            }
            if !self.isReady {
                self.isReady = true
                self.loadingShell = false
                let pending = self.pendingRender
                self.pendingRender = nil
                self.cancelPending = nil
                pending?()
                self.onReady?()
            }
        }
    }
}
```

In `webView(_:didFinish:)`, call `applyFollowChanges(epoch: shellEpoch)` **before** releasing `pendingRender` or invoking `onReady`; move the existing release into the successful, value-stable completion shown above. Reset `applyingFollowChangesEpoch` on shell replacement, failure and close (never the stored Bool), so an old in-flight call cannot block initialization or publish readiness. Preserve the existing `loadingShell`/`cancelPending` cleanup and pending-render-before-`onReady` order. Serialize calls and compare the completed `applied` value with current `followChanges`; if changed, re-apply before readiness. Ignore completion from closed/replaced shells without clearing the new shell's in-flight state. Keep `isReady` false until the preference call succeeds. On failure report through `onFailure` and do not release queued rendering into an uninitialized shell. `onRecovery` currently runs in `webViewWebContentProcessDidTerminate`, not `didFinish`: leave its timing unchanged; any recovery-triggered render queues until this initialization completes. Do not reset the stored preference in `loadShell`, `invalidate`, or process recovery.
- [ ] **Step 4 — Run green.** `bash scripts/test-swift.sh && bash scripts/test-webkit.sh`. Expected: queued, reloaded, recovered and in-flight-toggle hosts apply the latest flag before initial commits; all existing generation/link/capability tests pass.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewerCore/RenderHost.swift Tests/M0Integration/RefreshProbe.swift && git commit -m "feat: retain follow changes across renderer recovery"`.

### Task 5: Wire the application-wide checked View menu item

**Files:** Modify `Sources/MDViewer/AppDelegate.swift`, `Sources/MDViewer/DocumentWindow.swift`.

- [ ] **Step 1 — Specify the failing UI contract.** Before editing, inspect the menu and record that it lacks Follow Changes. Add review assertions to the task evidence: missing defaults means false; only a Bool at `MDViewerFollowChanges`; Cmd-Shift-F with checked state; existing/new windows receive the same setting. This app executable is not imported by the core test target; do not pretend isolated host tests exercise its menu. An actual-app UI check remains explicitly permission-gated.
- [ ] **Step 2 — Run the baseline check.** `rg -n 'MDViewerFollowChanges|Follow Changes|setFollowChanges' Sources/MDViewer`. Expected: no matches before this task.
- [ ] **Step 3 — Implement only the shell wiring.** Add a stored menu item and action in `AppDelegate`:

```swift
private let followChangesItem = NSMenuItem(title: "Follow Changes",
    action: #selector(toggleFollowChanges(_:)), keyEquivalent: "f")
private var followChanges: Bool { UserDefaults.standard.bool(forKey: "MDViewerFollowChanges") }
@objc private func toggleFollowChanges(_ sender: Any?) {
    let enabled = !followChanges
    UserDefaults.standard.set(enabled, forKey: "MDViewerFollowChanges")
    followChangesItem.state = enabled ? .on : .off
    for document in documents.values { document.setFollowChanges(enabled) }
}
```

Set item target to self, `keyEquivalentModifierMask = [.command, .shift]`, and initial checked state from the Bool. Append it to View without changing find/zoom shortcuts. Extend `DocumentWindow.init(location:followChanges:)` with a default false parameter and call `host.setFollowChanges(followChanges)` before `host.load()`. Add `func setFollowChanges(_ enabled: Bool) { host.setFollowChanges(enabled) }`; pass the app's value when constructing every window. Do not persist document paths, anchors or keys.
- [ ] **Step 4 — Verify scoped green.** `swift build --build-system swiftbuild --product MDViewer` (compile only; do not launch), `bash scripts/test-swift.sh`, `bash scripts/test-webkit.sh`; inspect `rg -n 'MDViewerFollowChanges|Follow Changes|setFollowChanges' Sources/MDViewer`. Expected: build and probes pass; all shell paths are wired. Record actual menu interaction and multiwindow UX as unverified unless user separately authorizes real-app testing.
- [ ] **Step 5 — Commit.** `git add Sources/MDViewer/AppDelegate.swift Sources/MDViewer/DocumentWindow.swift && git commit -m "feat: add persistent follow changes view toggle"`.

### Task 6: Run the complete isolated acceptance matrix

**Files:** Modify `Tests/M0Integration/RefreshProbe.swift` and `scripts/test-renderer-assets.mjs` only if a missing regression needs an assertion.

- [ ] **Step 1 — Add missing acceptance assertions.** Retain the original scroll offset test. With Follow Changes on, call `scrollToFragment("target")` and assert the matching heading is visible; call `host.find` and assert a successful result; use `host.zoom(by: 1.2)`/`resetZoom()` and assert existing bounds and restored scale. Do not trigger a render merely by navigation/find/zoom. Add source checks that block keys do not use `setAttribute`/dataset and that reduced-motion disables the flash animation.
- [ ] **Step 2 — Run new checks before correcting regressions.** `node scripts/test-renderer-assets.mjs && bash scripts/test-webkit.sh`. Expected: any remaining A4 regression fails at its own assertion, not a timeout increase.
- [ ] **Step 3 — Correct only observed regressions.** Keep all anchor/follow logic inside accepted commits and preserve these unrelated API entry points:

```javascript
window.scrollToFragment = fragment => {
  const id = `user-content-heading-${fragment}`;
  const heading = document.getElementById(id) || document.getElementById(`user-content-heading-${slug(fragment)}`);
  if (heading) { heading.scrollIntoView(); heading.setAttribute('tabindex', '-1'); heading.focus({ preventScroll: true }); }
  return !!heading;
};
```

No navigation, find or pageZoom side effects should be added to `setFollowChanges`.
- [ ] **Step 4 — Run acceptance.** `bash scripts/test-swift.sh`; `node scripts/test-renderer-assets.mjs && node scripts/test-reference-performance.mjs`; `python3 scripts/verify_assets.py`; `bash scripts/test-webkit.sh`; `CONFIGURATION=release bash scripts/test-webkit.sh`. Expected: A1–A4, hostile-content and transaction tests pass with current budgets/timeouts. The WebKit script bounds probe subprocesses; do not directly run an unbounded GUI probe. No actual-app/Launch Services claim follows from these checks.
- [ ] **Step 5 — Commit tests.** Stage only regression files and regenerated inventory if needed; `git commit -m "test: verify anchored refresh and follow changes acceptance"`. If no code/test change was necessary, retain the evidence for Task 7 rather than making an empty commit.

### Task 7: Document the feature and dated verification scope

**Files:** Modify `README.md`, `ARCHITECTURE.md`, `TEST_RESULTS.md`.

- [ ] **Step 1 — Write the documentation acceptance checklist.** User docs must explain always-on anchoring, View → Follow Changes, Cmd-Shift-F, default off and application-wide persistence. Developer docs must explain keys, predecessor fallback and readiness ordering. Evidence must distinguish isolated WebKit from actual menu/Launch Services testing.
- [ ] **Step 2 — Check the old docs.** `rg -n 'Follow Changes|MDViewerFollowChanges|content.anchor' README.md ARCHITECTURE.md TEST_RESULTS.md`. Expected: old docs do not yet cover the complete contract.
- [ ] **Step 3 — Add concise documentation.** Suggested user text: “Refresh keeps the visible content anchored. Enable View → Follow Changes (⌘⇧F) to jump to and briefly highlight an off-screen changed block. It is off by default and applies to all viewer windows.” Add the sole Bool preference and shell recovery behavior to architecture. Record execution date, actual commands, result counts, 5 px geometry checks and performance measurements in `TEST_RESULTS.md`; explicitly label actual-app menu interaction untested if permission was not granted.
- [ ] **Step 4 — Review docs against A1–A4.** `git diff --check` and inspect the three-file diff. Expected: no whitespace errors, no claim of app launch/install/default-handler verification, no stale description of pixel-only refresh.
- [ ] **Step 5 — Commit docs.** `git add README.md ARCHITECTURE.md TEST_RESULTS.md && git commit -m "docs: describe anchored scrolling and follow changes"`.

## Coverage and source reconciliation

A1 (including late-image settling/cancellation) → Task 1; A2 → Task 2; A3 → Tasks 3–5; A4 (single-block performance and in-flight preference race) → Tasks 1, 4 and 6. The supplied spec's renderer and scroll-probe line anchors match the inspected baseline. One source detail to preserve: `scripts/build-renderer.mjs` rewrites both notice copies as well as `vendor-manifest.json`, not just the generated renderer. No security-contract changes are required.
