# Content-anchored scroll and "Follow Changes" — design

Status: proposed (2026-10-30). Feature 1 of the post-v1 round. Contract base:
[v1 specification](2026-10-29-mdviewer-v1-design.md) (refresh behavior, A06/A07).

## Problem

Scroll position is already kept across live refresh. `commitMarkdown` in
`web/renderer.js:134-142` saves `scrollX/scrollY` and restores it, clamped to the new
page height. `Tests/M0Integration/RefreshProbe.swift:108-114` checks it within 5 px.

That pixel offset only works when nothing above the viewport changes height. Edits
higher up in the file (a new paragraph, a table that grows, an image that loads) move
the content you were reading by the height difference. The preview appears to jump,
which is the most common case when you keep the viewer beside an editor.

There is also no way to find what changed after a save. If the edit is off-screen,
the preview refreshes silently.

## Goals

1. **Content anchoring (always on).** After a refresh, the block that was at the top
   of the viewport stays at the same on-screen offset, even when content above it
   changes height.
2. **Follow Changes (opt-in).** A View-menu toggle, *Follow Changes* (Cmd-Shift-F, off by
   default). When it is on and a refresh changes content, the first changed block is
   scrolled into view if it is not already visible, and briefly highlighted.
3. Behavior is unchanged for the first render, explicit fragment navigation, find, and zoom.

## Non-goals

Mapping editor cursor positions or syncing scroll with an editor. Diffing inside a
block. Animations beyond a short CSS highlight. Remembering scroll across window close
and reopen.

## Design

All logic lives in the renderer (`web/renderer.js`). The native side only stores and
passes the toggle.

- **Block keys.** Each top-level child of `#document` gets a key computed at
  staging time: `tagName + ":" + hash(textContent)` plus an occurrence index for
  duplicate keys (e.g. `P:9f3a…#2`). Use a small, deterministic, non-cryptographic hash
  (FNV-1a over UTF-16 code units). Read `node.textContent` once per block and hash that
  cached string in one linear pass, including for a single ≈1 MB code block. No attributes are added to the sanitized HTML; keys
  live in a JS `WeakMap`/array, so DOMPurify output and CSP stay unchanged.
- **Anchor capture (before `replaceChildren`).** Find the first top-level block whose
  `getBoundingClientRect().bottom > 0`. Record its key, its `top` offset, and the
  existing `{x, y}` as a fallback.
- **Anchor restore (after `replaceChildren`).** If a new block has the same key,
  scroll so its `top` equals the recorded offset. Otherwise, use the nearest preceding
  surviving key in old-document order. If neither exists, use the existing clamped
  `{x, y}` behavior. Never scroll past the document bounds.
- **Late image layout.** For up to 1 s after each accepted commit, re-apply the final
  viewport anchor on image `load` and `error` events (including the followed block
  when Follow Changes moved the viewport). Cancel on user scroll, wheel or key input,
  explicit fragment navigation, or a newer commit. Distinguish the renderer's own
  restoration scrolls from user scrolls. Do not await image `decode()` before commit:
  slow or failed decoding must not delay the generation/capability transaction or
  keep an otherwise ready text preview hidden.
- **Change detection.** Compare the old and new key sequences. The first index whose
  key differs (or the first extra block) is the *first changed block*. Report a
  deletion at the end of the document as the last block.
- **Follow Changes.** `window.setFollowChanges(Bool)` stores a flag. If the flag is set
  and a changed block exists, the block is outside the viewport after restore, and the
  commit is a refresh (not the first render), call `scrollIntoView({block: "center"})`
  and add a `changed-flash` class for 1.2 s. The animation goes in `Resources/Web/styles.css`,
  is suppressed by `prefers-reduced-motion`, and has no effect on screen-reader output.
- **Native toggle.** A *Follow Changes* menu item in the View menu, owned by the app
  shell, stored in `UserDefaults` key `MDViewerFollowChanges` (a Bool and nothing else).
  `RenderHost` gains `setFollowChanges(_:)`, which calls
  `window.setFollowChanges` through the existing `callAsyncJavaScript` path. It is also
  applied after the shell loads and after content-process recovery. If the Bool changes
  while an asynchronous application is in flight, re-apply the latest value before
  releasing queued renders; stale shell completions cannot initialize a newer shell.
  All open windows update when it is toggled.

## Security and contract impact

- No new HTML attributes, schemes, message handlers, or CSP changes. Hashing uses
  only text already rendered.
- Changing `web/renderer.js` and `styles.css` requires `npm run build`, which regenerates
  `Resources/Web/renderer.js` and `vendor-manifest.json` hashes. `verify_assets.py` must pass.
- The `UserDefaults` Bool is the only new persisted state. No document data is stored.

## Acceptance

- A1: Inserting 50 lines above the viewport keeps the top visible block within 5 px of its
  previous screen offset (real WebKit probe). A variant with an image above the viewport
  loading after commit stays within 5 px after load/error during the 1 s settling window;
  user scroll/key/wheel input cancels further corrections.
- A2: Deleting the anchored block falls back to the nearest preceding block; the
  scroll stays inside the document bounds.
- A3: With Follow Changes off, an off-screen edit does not move the viewport. With it
  on, the changed block ends up inside the viewport and gets `changed-flash`.
- A4: First render, fragment navigation, find, zoom, and the existing
  `RefreshProbe` scroll test still pass. Renderer asset checks, the manifest, and the
  performance budget still pass, including a ≈1 MB single code block in
  `scripts/test-reference-performance.mjs`. A setting toggled during an in-flight
  shell initialization reaches its latest value before queued renders commit.
