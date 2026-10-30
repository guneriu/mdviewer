# MDViewer — Product and Technical Specification

Status: original v1 product and security contract (2026-10-29), retained for reference. Implementation evidence and incomplete acceptance are tracked in [TEST_RESULTS.md](../../TEST_RESULTS.md); requirements below are not claims that all scenarios have passed.
Project: standalone `mdviewer/` source tree.
Related document: [Implementation plan](../plans/2026-10-29-mdviewer-v1.md).

## 1. Purpose and agreed workflow

Build a free, local, read-only macOS Markdown viewer, independent of Pi.
The user creates or receives a Markdown file in a Pi session and opens it using pi-files' existing system-open action. macOS launches MDViewer and displays the rendered document. No additional preview prompt, editor plugin, GitHub endpoint, or running Pi process is required.

One-time setup:
1. Build the app locally and install MDViewer.app in ~/Applications.
2. Select an .md file in Finder, choose Get Info → Open with → MDViewer → Change All.
3. Repeat for .markdown only if the user also wants that extension associated.
The app must not silently change file associations. Sublime remains available through Open With.

Normal use:
1. The agent saves a Markdown document.
2. The user activates the existing external-open action in pi-files.
3. macOS sends the document URL to MDViewer.
4. The app opens or focuses its document window.
5. Saving changes in Pi or Sublime refreshes that window without another click.

## 2. Scope and priorities

### P0 — required for v1

- Open .md and .markdown through Finder, macOS open, File → Open, and multiple-file open requests.
- Work on both cold launch and subsequent requests to an already-running app.
- Render entirely offline: no CDN, remote renderer, analytics, authentication, subscription, or runtime dependency download.
- Support headings, paragraphs, emphasis, links, lists, blockquotes, horizontal rules, fenced code, inline code, tables, strikethrough, task lists, and local raster images.
- Use bundled syntax highlighting for a documented small set of common languages; unknown languages remain readable plain code.
- Provide light/dark styling that follows macOS, readable typography, horizontal scrolling for wide tables/code, selectable text, copying, Cmd-F find, and zoom/reset.
- Reload when the source changes, including editor atomic-save replacement.
- Reuse the window for the same canonical file; open distinct documents in independent windows.
- Show a clear error for unreadable, missing, oversized, or unsupported-encoding files.
- Keep Markdown content inert and prevent automatic network access or execution.
- Ship a reproducible local build/install route and all dependency licenses.

### P1 — explicitly deferred

Mermaid diagrams, math rendering, PDF/export/printing enhancements, remote-image opt-in, broader asset-directory permissions, drag-and-drop, table of contents, tabs, session restore, a dedicated mdview CLI wrapper, universal binaries, public distribution, and notarization.

Mermaid source remains visible as a fenced code block in v1. A richer diagram renderer requires a separate security review; it must not quietly add network access.

### Non-goals

Editing or saving Markdown, replacing Sublime, executing code blocks, exact GitHub rendering parity, full arbitrary HTML support, automatic previews for every agent write, changes inside pi-files, or a cross-platform desktop framework.

## 3. Project boundary and recommended stack

Keep the standalone project layout; Git initialization and hosting remain separate owner decisions.
Do not place app code inside the external Pi extension project or its `packages/pi-files` package.

Recommended architecture (design choice, not a pre-existing implementation):
- Swift + AppKit for the application lifecycle, menus, windows, file-open events, and filesystem watching.
- WKWebView, supplied by macOS, for the document view.
- Bundled markdown-it for CommonMark plus its tables/strikethrough extensions.
- A pinned task-list plugin, with its license and generated disabled checkboxes verified.
- Bundled DOMPurify for defense-in-depth HTML sanitization.
- A small bundled highlight.js build for syntax highlighting.
- Swift Package Manager and explicit .app packaging scripts, subject to the feasibility gate in the implementation plan.

No Electron, Tauri, Node.js server, local HTTP listener, or browser tab is needed at runtime.
Development may use Node/npm to prepare vendored renderer assets; shipping users must not need Node, npm, or an active internet connection.

Proposed deployment target: macOS 13+. This is a recommended baseline, not a user-stated requirement or a verified compatibility promise.
Build initially for the local machine's architecture. Do not promise support for other architectures or older OS versions without testing.

## 4. Components and responsibilities

- Application delegate: use the URL-based application(_:open:) callback as the single document-open path, create the normal macOS menu bar, present the open panel, and report open failures. Do not mix it with legacy openFile/openFiles callbacks and assume both are invoked.
- Document coordinator: normalize file URLs, resolve symlinks for duplicate detection, route multi-file events, and own one session/window per canonical document.
- Document session: own source URL, current UTF-8 snapshot, watch/retry state, render generation, and window title/path.
- Document window: contain the web view, status/error banner, and find/zoom controls; never write the source.
- Render host: configure WKWebView, deliver source safely to trusted JavaScript, and apply only the newest completed render.
- Asset gateway: serve bundled renderer assets and approved document-local images through a restricted custom URL scheme.
- File watcher: observe the canonical target's parent directory, rebind after atomic replacement, and detect deletion/reappearance. A symlink opened initially identifies that target; later retargeting the symlink requires reopening the requested path. Asset-only edits do not trigger refresh in v1; Cmd-R rereads the document and refreshes local images.
- Link router: handle fragment navigation, other Markdown documents, explicit external-browser navigation, and unsupported targets.

The exact folder/file names are implementation details; separate these responsibilities enough to test path handling, reload state, and link policy without launching the entire UI.

## 5. Document lifecycle and file behavior

- Accept regular readable UTF-8 files, including UTF-8 BOM; report unsupported encodings instead of silently corrupting text.
- An empty Markdown file is valid and displays a small empty-document state.
- Start with a 10 MiB source-size limit; report it explicitly and do not truncate documents silently.
- Preserve the source file byte-for-byte; never create sidecar HTML beside it.
- Treat spaces, Unicode, percent signs, quotes, and shell-looking filenames as literal paths. Pass URLs/arguments directly; never construct shell commands from document content.
- Canonicalize aliases/symlinks for duplicate-window detection. Keep the originally requested display path available for user orientation.
- Show the source path in window UI or a standard represented-file control.
- On a burst of writes, debounce for approximately 200 ms and render after the source settles.
- On transient read failures during replacement, retry briefly. Keep the last good preview while showing the problem.
- A deleted file produces a missing-file banner without closing the window; recreation can resume preview.
- Preserve scroll position on refresh as far as practical, clamped to the new document length.
- Use monotonically increasing render generations so slower old reads/renders cannot replace newer content.
- Closing a document stops its watcher. Cmd-R forces a reread; Cmd-O opens a file; Cmd-W closes the window; Cmd-Q quits.

## 6. Rendering contract

- Configure markdown-it with raw HTML disabled. HTML-looking text must not become arbitrary document markup.
- Disable automatic external resource fetching and avoid linkification beyond the documented Markdown feature set.
- Keep code text escaped before highlighting; unknown or hostile language labels fall back to escaped plain text.
- Sanitize the generated HTML before insertion, then enforce the explicit URL policy for every href/src.
- Transfer source as a serialized argument through a supported WebKit JavaScript API, not by concatenating Markdown into script or HTML.
- Implement stable, deterministic heading IDs for internal anchor links and cover duplicate/non-ASCII headings with tests.
- Bundle renderer JavaScript, CSS, fonts if any, and licenses inside the app. Prefer system fonts.
- Render task lists as non-editable controls or equivalent accessible symbols, with no form submission.

V1 aims for the listed Markdown features, not complete GitHub Flavored Markdown conformance.

## 7. Local assets, links, and security boundary

Markdown is untrusted input. Arbitrary code execution, source writes, data exfiltration, and background network requests are unacceptable.

V1 distribution decision: the locally built app is not enabled for App Sandbox (do not add com.apple.security.app-sandbox). The native process has the user's ordinary filesystem permissions; the image-root policy is enforced by application code, not an OS sandbox guarantee. WebKit process isolation does not sandbox the host app. This choice supports parent-directory watching and adjacent assets without new folder-permission prompts. Verify the actual packaged entitlements in M0. A sandboxed/App Store release would require a separate security-scoped access design and is out of v1 scope.

Preferred resource design, to be proven first:
- Use WKURLSchemeHandler with an app-owned scheme such as mdviewer.
- Serve a fixed trusted shell and bundled JS/CSS from app resources.
- Map document assets through opaque per-session IDs; never accept an arbitrary absolute filesystem path from a web URL.
- Rewrite each allowed Markdown image src to a session-scoped, per-render-versioned gateway URL before DOM insertion. Resolve the original source path against the document directory in native code, not against the renderer shell's origin. Apply the same validated rewriting on manual refresh so changed image bytes are reread.
- Read source text and permitted image bytes in native code; do not grant the web view broad filesystem access.
- If this design fails its feasibility spike, reconsider the design explicitly. Do not silently relax access to a whole home directory or start a local web server.

Asset policy:
- Allow referenced PNG, JPEG, GIF, and WebP files within the canonical source document's directory or descendants.
- Resolve URL encoding, traversal, and symlinks before the containment check. Reject paths that escape the approved root, including ../ and symlink escapes.
- Do not automatically load SVG, HTML, iframe content, data URLs, remote images, absolute file URLs, or external fonts.
- Show a useful placeholder when an image is blocked or missing.
- Deliberate v1 limitation: a document referring to ../assets/image.png needs a later explicit broader-root permission feature; do not weaken the default to make it work.

Link policy:
- Same-document fragments remain inside the viewer.
- An explicit click on another local Markdown file may open that document through the native coordinator, even outside the image root; this is a user action, not an automatic resource read.
- Explicit http/https links open in the system browser only after validating their scheme; the embedded web view does not navigate there.
- Block javascript:, data:, arbitrary custom schemes, and executable targets. Do not automatically launch linked apps or scripts.
- Non-Markdown local links may be revealed in Finder, not executed.
- Reject unsolicited navigation, popups, downloads, redirects, frames, and new-window requests.

Defense in depth:
- Set a restrictive Content Security Policy: deny by default, permit only required bundled scripts/styles and gateway-provided image data, and deny connect/frame/object/form capabilities.
- Do not rely on WKNavigationDelegate alone to block subresource networking. Enforce the resource scheme/URL policy and verify actual network behavior.
- Do not expose a general-purpose JavaScript-to-native execution/file-access bridge.
- Store no document contents in persistent web storage or logs. Avoid persistent web caches where feasible.
- No analytics, cookies, or automatic update checks.

## 8. Packaging, installation, and cost

- Product name: MDViewer; installable bundle: MDViewer.app.
- Choose one stable reverse-DNS bundle identifier before the first release.
- Declare CFBundleDocumentTypes with CFBundleTypeRole = Viewer and appropriate Markdown LSItemContentTypes.
- Use an appropriate imported Markdown UTI declaration if needed; verify both .md and .markdown against the installed system instead of assuming one identifier works everywhere.
- Register as a handler without claiming to override the user's default editor; association is a deliberate Finder action.
- Provide build, package, install/update, uninstall, and reset-default instructions.
- For local use, build on the user's own machine and use ad-hoc signing where needed; no paid account should be required for that route.
- Notarized public distribution is separate work and may require an Apple Developer membership. Do not claim that a locally built/ad-hoc bundle is equivalent to notarized distribution or bypass Gatekeeper.
- Do not remove quarantine attributes or weaken system security automatically.
- Installation/update must preserve an existing user-chosen association and offer recovery instructions if Launch Services retains a stale path.

Observed planning environment: macOS 26.7.1; xcode-select points to /Library/Developer/CommandLineTools.
Full Xcode was not assumed installed. CLI-tool feasibility was originally an explicit gate; the subsequent dated observations in TEST_RESULTS.md are local evidence, not a guarantee for every toolchain.

Pin renderer/plugin versions before implementation; record source, version, checksum, license, and reproduction commands. Include all license notices in the app.
Known license families to verify for selected versions: markdown-it MIT, DOMPurify Apache-2.0 OR MPL-2.0, highlight.js BSD-3-Clause. Verify the task-list plugin separately.

## 9. Acceptance criteria

| ID | Scenario | Required outcome |
| --- | --- | --- |
| A01 | Set MDViewer as default and externally open an .md from pi-files | Rendered window appears without a preview prompt, GitHub call, or Pi-specific app integration. |
| A02 | Open by Finder Open With and open -a MDViewer /absolute/path.md | Works on cold launch and while the app is running; MDViewer is available as a handler for .md and .markdown. Setting the system default is tested in A01/M5. |
| A03 | Open two files, then reopen one by a symlink alias | Two document windows; reopening focuses the existing canonical document. |
| A04 | Open a fixture containing all P0 Markdown constructs | Tables, task lists, lists, headings, links, code, and images behave as documented. |
| A05 | Disconnect networking and open normal fixtures | All bundled rendering/highlighting still works. |
| A06 | Save via atomic rename, direct write, and a burst of edits | Latest settled source is displayed without extra windows; refresh normally completes within 1 second after the last write. |
| A07 | Delete, recreate, rename away, or deny read permission | Clear status, last good content retained where applicable, manual retry available, and no crash/source modification. |
| A08 | Use space/Unicode/quote/percent/shell-looking filenames and malformed encoding | Valid files open literally; invalid input gives a readable error. |
| A09 | Open hostile Markdown with HTML, malicious URLs, remote images, traversal, and symlink escapes | No script/native execution, automatic network requests, or out-of-root asset reads. |
| A10 | Click safe fragments, local Markdown links, web links, and unsafe links | Correct routing; only an explicit safe web-link click can open the external browser. |
| A11 | Use dark mode, keyboard menus, find, copy, and zoom | Readable, selectable, keyboard-usable document with working find/zoom and VoiceOver smoke coverage. |
| A12 | Open an empty file, an unknown-language fence, and a file above 10 MiB | Valid fallbacks or actionable size error; no silent truncation. |
| A13 | Install/update the .app locally and reopen from pi-files | Same expected association behavior; no paid runtime dependency and no source mutation. |
| A14 | Inspect the packaged bundle and dependency manifest | Renderer assets and license notices are present, pinned, and usable offline. |

Performance targets to measure on the user's Mac, not promises: cold open under 2 seconds and warm open under 1 second for a representative report up to 1 MiB. Record OS, hardware, fixture, and measured results.

## 10. Decisions and unresolved gates

The original design selected the native stack, read-only local rendering, restricted local images, no Mermaid in v1, no runtime server, and an independent project. Implementation was subsequently authorized separately. These documents do not authorize execution of unfinished work.

The following were the original first-spike questions; see TEST_RESULTS.md for dated answers and remaining limitations:
- Can the installed CLI toolchain build, package, sign, register, and launch the app correctly without full Xcode?
- Does a minimal XCTest or Swift Testing check plus a real WKWebView integration test run with the selected toolchain?
- Does the packaged bundle have the intended non-App-Sandbox entitlements, and do parent-directory watching and adjacent assets work under that actual configuration?
- Can the custom scheme render bundled scripts, apply CSP, load approved local images, and block networking reliably?
- Which UTI declaration and app identifier work with both file extensions on the target Mac?
- Which exact dependency versions/plugin achieve the rendering and security tests?

## 11. Evidence and references

- External pi-files integration research: `packages/pi-files/src/core.ts:237-244`; macOS path returns { cmd: "open", args: [absPath] }. This is an external source reference, not a file in this project.
- External pi-files terminal renderer research: `packages/pi-files/src/core.ts:346-348`; ANSI highlighting is not a GUI renderer to embed.
- [Apple: document type keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html): Viewer is an allowed document role.
- [Apple: application open-file events](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
- [Apple: choose a default application](https://support.apple.com/guide/mac-help/change-the-app-that-opens-a-file-mchlp1378/mac).
- [Apple: WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler); preferred design still requires the spike above.
- [Apple: scoped file loading alternative](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)); not a justification for broad filesystem grants.
- [SwiftPM executable products](https://docs.swift.org/swiftpm/documentation/packagedescription/executableproduct/); a package executable is not, by itself, a Finder app bundle.
- [Apple: notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- [markdown-it](https://github.com/markdown-it/markdown-it), [DOMPurify](https://github.com/cure53/DOMPurify), [highlight.js license](https://github.com/highlightjs/highlight.js/blob/main/LICENSE).

Library feature/license summaries above are research inputs. Verify the exact selected versions during implementation.
