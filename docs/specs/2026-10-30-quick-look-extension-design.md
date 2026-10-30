# Quick Look preview extension — design

Status: **parked** (2026-10-30). The feasibility spike did not get the extension discovered;
see "Quick Look feasibility spike — parked" in [TEST_RESULTS.md](../../TEST_RESULTS.md).
Original status: proposed (2026-10-30). Feature 7 of the post-v1 round. Implemented last
(order 1 → 3 → 7; feature 8, the mdv CLI, was dropped). Contract base: [v1 specification](2026-10-29-mdviewer-v1-design.md).

## Goal

Pressing Space on a `.md` file in Finder shows the same sanitized rendering as
MDViewer. The extension reuses the WebKit renderer and is built by `scripts/package.sh`
without an Xcode project.

## Non-goals

Thumbnails (`com.apple.quicklook.thumbnail`), Spotlight indexing, live refresh in Quick
Look, links that open other documents, find, zoom, and App Store or notarized
distribution.

## Approach summary

A view-based preview extension, `MDViewerQuickLook.appex`, embedded at
`MDViewer.app/Contents/PlugIns/`. Its principal class is a programmatic
`QLPreviewingController` (no storyboard) that hosts the existing `RenderHost`
(`Sources/MDViewerCore/RenderHost.swift`, already in the library target) with a
private copy of `Resources/Web`.

Apple does not document how to build an appex outside Xcode, whether ad-hoc signing
is accepted, or which sandbox entitlements WKWebView needs (research brief
2026-10-30). The plan therefore starts with a **go/no-go feasibility spike**. Feature
work only continues if the spike passes; otherwise the feature is dropped and the
findings recorded.

## Design

### Build (no Xcode)

- New library target `MDViewerQuickLookCore` depends on `MDViewerCore` and owns
  `PreviewRequest` plus the preview controller logic. `MDViewerQuickLookTests` depends
  on and imports this library, **not** the extension executable: its request/controller
  tests must run in a normal test host, never through `_NSExtensionMain`.
- `MDViewerQuickLook` is an executable product with a thin shim depending on
  `MDViewerQuickLookCore`; no lifecycle/controller implementation lives in the shim.
  Only this target uses `-Xlinker -e -Xlinker _NSExtensionMain`. Link QuickLookUI/WebKit
  and compile core/library/shim with `-application-extension`. `unsafeFlags` are allowed
  for a local, non-published package; if SwiftPM rejects them, `package.sh` uses the
  spike-proven `swiftc` recipe for the same library/shim boundary. The spike verifies
  the library principal class survives linking and is discoverable in the appex.
- `MDViewerCore` must remain app-extension-safe: no `NSApplication.shared`/`NSWorkspace`
  use in code paths compiled into the extension. Link opening stays in the app target
  (already true: `LinkPolicy` decides, `DocumentWindow` acts). The plan audits this.
- `scripts/package.sh` assembles
  `Contents/PlugIns/MDViewerQuickLook.appex/Contents/{Info.plist,MacOS/MDViewerQuickLook,Resources/Web/…}`.
  It signs inside-out: first the appex with its entitlements file, then the app
  **without** `--deep`, so the appex signature and entitlements are not stripped.

### Info.plist (appex)

`CFBundlePackageType=XPC`, `CFBundleIdentifier=de.local.mdviewer.quicklook`,
`LSMinimumSystemVersion=13.0`, and
`NSExtension = { NSExtensionPointIdentifier = com.apple.quicklook.preview;
NSExtensionPrincipalClass = MDViewerQuickLookCore.PreviewViewController;
NSExtensionAttributes = { QLSupportedContentTypes = [net.daringfireball.markdown];
QLSupportsSearchableItems = false } }`. The class is exported with
`@objc(PreviewViewController)`; the spike must prove the exact runtime/plist name
pair (custom Objective-C names may be unqualified) before production packaging.

### Entitlements (appex only)

- `com.apple.security.app-sandbox = true`. Required by PlugInKit for extensions.
- Nothing else by default. No `network.client`, no temporary-exception file access,
  and no user-selected file access.
- If the spike shows WKWebView cannot render under the bare sandbox, adding
  `com.apple.security.network.client` is a **security decision for the user**. It is
  not part of this approved design. It would be recorded in the specification with its
  rationale (the CSP still blocks all remote loads).
- The main app stays unsandboxed and unchanged. `verify_m0.py` keeps asserting this for
  the app executable, and gains a separate check that the appex has exactly the approved
  entitlements.

### Preview controller

- `preparePreviewOfFile(at:completionHandler:)`:
  1. reads the file through the existing `DocumentIO` limits (size cap, UTF-8 rules)
  2. creates the `WKWebView` with the same non-persistent configuration, CSP, and
     `mdviewer://` scheme gateway as the app
  3. renders through `RenderHost`
  4. calls the completion handler only after the first commit completes (or with an
     error after a 5 s timeout)
  Errors show a short native status message, like `DocumentWindow`'s status text, with no file contents in logs.
- **Links:** navigation policy cancels every navigation except the initial shell load.
  Fragment links scroll in place. External links do nothing: there is no
  `NSWorkspace` in the extension, and Quick Look is a preview.
- **Images:** `AssetPolicy` is unchanged. The sandbox may deny reads of sibling files,
  because the Quick Look grant for directories is not documented. Denied reads become
  the existing blocked-image placeholder. No entitlement is added to widen access.
  The spike records the observed behavior.
- **Teardown:** the controller stops the web view and drops the gateway on deinit; the
  extension process can be reused.

### Registration

The appex is discovered when the containing app is registered (installed in
`~/Applications`, opened once by the user). `install.sh` does **not** call `pluginkit -a`,
`qlmanage -r`, or `lsregister`, so the existing no-registration rule in AGENTS.md
stays. README documents the manual steps for the user: open the app once, check
System Settings → Login Items & Extensions → Quick Look, and `qlmanage -r` if needed.

## Feasibility spike (gate)

Run in a fake-HOME/`.build` sandbox where possible. Mutating or registering commands
(`pluginkit -a`, `qlmanage -p/-r`, installing) only with explicit user approval at that step.

1. Build a minimal appex (static "hello" view, no WebKit) with the toolchain above,
   ad-hoc signed with the sandbox entitlement. `codesign --verify --deep --strict` passes.
2. The user approves registration. `pluginkit -mAvvv -p com.apple.quicklook.preview` lists
   it, and `qlmanage -p sample.md` shows the hello view.
3. Swap in WKWebView with the bundled shell and the `mdviewer://` scheme. It renders
   without `network.client`; if it does not, stop and ask the user.
4. Check sibling image reads and record the result.

Go means steps 1–3 pass. No-go means the spec is marked rejected, with findings, and
no product code is merged.

## Security and contract impact

- The new executable runs in Quick Look's host context and is sandboxed. Renderer CSP,
  DOMPurify settings, link blocking, and image limits are identical to the app's.
- `verify_assets.py` gains an allowlist for the appex layout (Info.plist, executable,
  Web resources with hashes). Tamper tests extend to it.
- The packaging tests must reject any extra appex entitlements and any additional
  appex, and verify the signing order.

## Acceptance

- Q0: The spike gate passes (above).
- Q1: Space on a Markdown file shows rendered output matching the app for the
  regression fixtures (headings, tables, task lists, code, blocked raw HTML).
- Q2: Remote images, scripts, and links never load or navigate (hardening fixture in
  Quick Look).
- Q3: Packaged bundle checks pass: asset allowlist, appex entitlements are exactly
  `app-sandbox`, signatures are valid, and the main app is still unsandboxed. The thin
  executable discovers the library-owned principal class; request/controller tests
  depend only on `MDViewerQuickLookCore` and run without the extension entry point.
- Q4: Existing suites pass. The app works the same whether or not the extension is enabled.
- Manual acceptance (Q0 step 2, Q1, Q2) runs only with user approval.
