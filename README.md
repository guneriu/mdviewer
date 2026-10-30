# MDViewer

A local, offline, read-only Markdown viewer for macOS. MDViewer opens `.md` and
`.markdown` files in native windows, renders with bundled JavaScript inside
system WebKit, and refreshes the preview when the source changes. It is not an
editor, browser service, or Node runtime; no Pi process is needed to use it.

**Status:** local build and automated verification evidence is available, but this
is not a notarized or fully accepted release. Automatic refresh for documents
directly inside `/tmp` (a symlink parent) was fixed on 2026-10-30. See
[limitations](#limitations-and-security) and the
[historical acceptance results](TEST_RESULTS.md) for unresolved checks.

## Quickstart

Prerequisites: macOS 13+ (macOS 14+ to run the tests), a Swift 6 toolchain
(`xcode-select --install` is enough; full Xcode is optional), Python 3, and the
standard `codesign`/`plutil` tools. You need Node 22+ only to regenerate renderer
assets.

```sh
git clone <repo-url> mdviewer && cd mdviewer
CONFIGURATION=release bash scripts/package.sh   # → .build/release-package/MDViewer.app
bash scripts/test-swift.sh                      # optional: native unit tests
bash scripts/install.sh --dry-run               # shows what would be installed
bash scripts/install.sh --install               # copies to ~/Applications/MDViewer.app
open -a ~/Applications/MDViewer.app README.md   # first launch
```

To make it the default viewer, select a `.md` file in Finder → **Get Info →
Open with → MDViewer → Change All**. Updating uses `--install --replace` after
quitting the app. The sections below explain each step, its safety guards, and
how to uninstall.

## What it displays

- Headings, paragraphs, emphasis, links, ordered/unordered lists, blockquotes,
  horizontal rules, fenced/inline code, tables, strikethrough, and disabled,
  accessible task checkboxes. Raw HTML is displayed as text, not executed.
- Explicit syntax highlighting for JavaScript, TypeScript, JSON, CSS, XML/HTML,
  Bash, Python, and Swift, including registered aliases. There is no language
  autodetection. Unknown languages and Mermaid remain escaped plain code;
  Mermaid diagrams and math are not rendered.
- Relative PNG, JPEG, GIF, and WebP images within the canonical document directory
  or its descendants. Missing or blocked images show a placeholder; parser-rejected
  image syntax stays literal. Remote, SVG, data, absolute-file, `../assets/`, and
  symlink-escape images are blocked.
- Stable Unicode heading fragments, with `-2`, `-3`, etc. for duplicates. Exact IDs
  take precedence over NFC/case-normalized fallback. For example, `#日本-語` targets
  “日本 語”.

Same-document links stay local. Explicit local Markdown links open through the
native document coordinator, even outside the image root. Explicit HTTP, HTTPS,
and mailto links use the default system application. Other local files require
confirmation to reveal in Finder, not execute. Unsafe schemes and executable
targets are blocked; the embedded view does not navigate away.

There is one window per canonical file. Sources are read-only UTF-8 (BOM accepted),
with a **10 MiB** cap, an empty-document state, and readable input errors. MDViewer
does not save Markdown, execute code blocks, export documents, accept drag-and-drop,
provide tabs or session restore, or aim for exact GitHub rendering parity.

## Requirements

- macOS with a Swift toolchain and SDK capable of building the project, plus
  Python 3 for bundled-asset verification and the standard macOS signing tools.
- Historical local validation used Apple Silicon, macOS 26.7.1, Swift 6.4 and
  Command Line Tools SDK 27 without full Xcode. The compiled deployment target is
  **macOS 13**, not a runtime-tested compatibility guarantee. The test framework
  requires **macOS 14**. Other toolchains, OS versions, and architectures need
  their own validation.
- Node **>=22** and npm are needed only to regenerate renderer assets. Normal
  app packaging uses the existing vendored assets, not npm or network downloads.

## Build and verify — no launch or installation

From the project directory:

```sh
bash scripts/package.sh
# Debug app: .build/MDViewer.app

CONFIGURATION=release bash scripts/package.sh
# Release app: .build/release-package/MDViewer.app

PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_assets.py --bundle .build/release-package/MDViewer.app
bash scripts/install.sh --dry-run
```

Packaging verifies asset hashes, sizes, allowlists and notices, builds with SwiftPM's
`--build-system swiftbuild`, copies the app, lints metadata, and ad-hoc signs and
verifies the host-architecture bundle. It **overwrites generated outputs** and
**does not refuse to package while an older app is running**. Quit MDViewer before
rebuilding a bundle you use, then deliberately reopen the intended bundle afterward.
Changing an executable on disk does not replace the live process image.

Packaging does not launch or install the app, explicitly register handlers, change
default preferences, remove quarantine, or weaken Gatekeeper. Ad-hoc signing is
not Developer ID signing or notarization; no universal binary is promised. See the
[packaging guide](Packaging/README.md) for inputs, outputs, and verification details.

## Deliberate launch and optional setup

**Copying or launching a document-type app can affect macOS app discovery and
default resolution even without an explicit default-setting call.** The app's
`LSHandlerRank=Alternate` is not a guarantee against this. Historical launch testing
observed MDViewer as an effective handler without a captured before-state; the
prior default and causality were not established. Review the
[Launch Services caveat](TEST_RESULTS.md#unresolved-launch-services-integration-caveat--do-not-hide)
before opting into actual-app testing.

To deliberately launch a locally built release and open a document, choose its
bundle in Finder or run the following **separately from building**:

```sh
open -a "$PWD/.build/release-package/MDViewer.app" "/absolute/path/to/report.md"
```

The absolute document path is an example; choose your own file. This is an actual
app launch, not an inspection check. Select the intended bundle explicitly when
multiple build or installed copies exist.

Optional installation and default-handler selection are separate user decisions:

1. Build and verify a release, then inspect `bash scripts/install.sh --dry-run`.
   When ready to copy it, run `bash scripts/install.sh --install`. The installer
   targets only `~/Applications/MDViewer.app`, refuses symlink destinations and a
   running MDViewer, verifies the staged copy, and does not launch it. No arguments
   fail closed. Its mutating install/update/rollback paths still require acceptance
   testing; guard and dry-run checks alone do not prove them.
2. Launch the installed copy deliberately. To make it the default, select an `.md`
   file in Finder → **Get Info → Open with → MDViewer → Change All**. Repeat for
   `.markdown` only if desired. Neither building nor installation explicitly sets
   these defaults.
3. An existing system/external-open action, including pi-files' action, can then
   route Markdown to the selected viewer. MDViewer has no pi-files source or
   configuration dependency. Actual pi-files integration remains a manual
   acceptance check, not a verified feature claim about that external tool.

### Update, restore defaults, and remove

- **Update:** quit MDViewer, rebuild and verify the release, then explicitly run
  `bash scripts/install.sh --install --replace`. Existing destinations require
  `--replace`; the installer never terminates the app for you. It stages/verifies
  the replacement and attempts rollback on a final-move failure, retaining the
  previous bundle for recovery if rollback fails. Reopen the intended installed
  bundle afterward, not an older build or already-running process.
- **Restore a preferred default:** Finder → **Get Info → Open with → Sublime Text**
  (or another chosen app) → **Change All**, separately for each chosen extension.
  If macOS retains a stale path, choose **Other…**, select the intended current
  bundle, reopen a source, and verify. No blanket association reset is provided.
- **Uninstall:** quit MDViewer, restore a preferred default first, then move only
  `~/Applications/MDViewer.app` to Trash in Finder. Source documents are not part
  of the app and should not be removed. Generated `.build/` outputs can be removed
  separately. Real install/update/uninstall and association preservation remain
  manual acceptance work.

## Keyboard, display, and refresh

| Shortcut | Action |
| --- | --- |
| Cmd-O | Open a document |
| Cmd-R | Reload source and local raster images |
| Cmd-F | Show native find controls |
| Cmd-+ or Cmd-= | Zoom in |
| Cmd-- | Zoom out |
| Cmd-0 | Reset zoom |
| Cmd-W | Close the document window |
| Cmd-Q | Quit MDViewer |

Text is selectable and can be copied. Styling follows system light/dark mode;
wide tables and code scroll horizontally. Path, status and search controls have
accessibility labels. Human keyboard, copy, layout and VoiceOver acceptance is
still pending despite automated find/zoom/selection coverage.

The app watches the canonical file and parent directory, debounces changes by
about **200 ms**, and retries transient failures. It keeps the last good preview
with a stale warning when reads/renders fail and can recover after recreation.
Generation guards prevent older work from replacing a newer preview. Observed
sub-second updates are dated local-disk measurements, not guarantees on all volumes.

**Asset-only changes need Cmd-R.** A valid partly written or empty file may briefly
display after settling; debounce cannot infer an external writer's intent. An
existing session follows its original canonical target: reopen after retargeting a
symlink. Parent-directory replacement is not automatically rebound.

### Troubleshooting

- **Unexpected behavior after a rebuild or replacement:** quit all MDViewer copies,
  then reopen the intended bundle explicitly. An on-disk executable and a running
  image can differ. A previous refresh incident recovered after reopening, but its
  exact old internal failure was not established; it is not proof of a source bug.
- **No automatic refresh in a symlinked parent directory:** fixed for `/tmp`
  (and analogous `/var`, `/etc` parents) on 2026-10-30. The parent watcher now
  resolves the physical directory with `realpath` while keeping `O_NOFOLLOW` for
  the final component. See the
  [blocker plan](docs/plans/2026-10-29-tmp-parent-watcher-blocker.md). If an older
  build still misbehaves, rebuild, reinstall, or press Cmd-R.
- **Image placeholder:** check the format, document-relative containment and
  resource budgets below. Broader directories and remote images have no opt-in.
- **Stale warning:** check existence, permissions, encoding and size, then retry
  with Cmd-R. A slow or stalled volume can delay all windows' queued reads.
- **Content-process failure:** recovery retries the shell/preview at most twice,
  then asks for Cmd-R. Coverage uses delegate injection, not a real OS process kill.

## Limitations and security

Markdown is untrusted input. Defense in depth includes raw HTML off, HTML-only
DOMPurify string output with named-property isolation, exact native resource
capabilities, bundle allowlists, CSP, deny-network content rules, and an ephemeral
WebKit data store. No document text is logged or intentionally persisted in web
storage. Production request diagnostics are off.

The native host is intentionally **not App Sandbox-enabled**. It has the user's
ordinary filesystem permissions; containment is application-enforced, not an OS
sandbox guarantee. There is no server, CDN, analytics, automatic updater, or runtime
dependency download. Explicit safe link clicks can open external applications.

Image work is bounded to **25 MiB/file, 64 MiB bytes/batch, 256 unique file reads,
2,048 references, 16,384 px/axis, 16 MP/image, 64 MP/batch, and 32 frames/image**.
Descriptor type, size and containment checks precede capped reads; NUL and
nonregular sources are rejected. Device/inode aliases share bytes/capabilities;
rejected reads consume work budgets. Parsing/highlighting remain synchronous in
WebKit; these bounds are not a general CPU/process-memory guarantee. Previously
authorized decoded image memory can survive capability retirement.

All windows share a serial `DocumentIO` actor. Byte-capped synchronous reads run
off the main thread but cannot be interrupted mid-read; cancellation is checked
around them. Slow/stalled I/O can cause head-of-line blocking. Nonblocking/no-follow
watcher opens reject FIFOs and nonregular targets but do not bound metadata latency.

CSP tests and node-free builds are not disconnected-network or packet-level proof.
True offline testing, online packet observation, older-macOS runtime, real WebKit
process termination, human UI and full-app integration checks remain pending.
See [TEST_RESULTS.md](TEST_RESULTS.md) for dated counts and the acceptance matrix;
no historical count represents a fresh test run by this documentation cleanup.

## Development and project documents

[Architecture](ARCHITECTURE.md) explains modules, data flow and security boundaries;
[AGENTS.md](AGENTS.md) holds contributor and coding-agent rules. The
[Development and evidence index](docs/README.md) covers check entrypoints, renderer
regeneration and historical engineering records. The project keeps separate:

- `Package.swift`: native Swift targets; `Sources/` and `Tests/` contain native code.
- Private `package.json` / `package-lock.json`: development-only renderer tooling.
- `web/`: renderer inputs; `Resources/`: vendored runtime assets and full notices.
- `Packaging/`: bundle metadata inputs and the [packaging guide](Packaging/README.md).
- `.build/`: generated apps and local evidence, not source to publish.

The [specification](docs/specs/2026-10-29-mdviewer-v1-design.md) and [implementation plan](docs/plans/2026-10-29-mdviewer-v1.md) retain the original
contract; [test results](TEST_RESULTS.md) track implementation evidence and remaining
gates. Keep dependency pins and asset/notices hashes together when changing the
renderer. Do not equate packaging success with manual acceptance.

## License

MDViewer's own code and authored documentation are licensed under the
[MIT License](LICENSE), copyright 2026 MDViewer contributors. Bundled dependencies
retain their own terms: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[Resources/Notices/](Resources/Notices/). The project license does not replace or
relicense those upstream texts.
