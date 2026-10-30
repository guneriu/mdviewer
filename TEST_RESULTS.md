# MDViewer verification evidence — implementation continuation

> Historical implementation evidence recorded on 2026-10-29; no build, app/probe launch, npm command or behavioral test was rerun by the GitHub-preparation cleanup. Counts and timings below describe those dated runs, not a current universal guarantee. Local `.build/` artifact names identify untracked original-machine logs, not committed files promised in a fresh checkout. Preserve the blocker and manual acceptance gaps when interpreting older passing results.

## Round-two final fixes — historical local gate (2026-10-29)

**PASS: 16 Swift tests / 5 suites, 81 real-WebKit checks, 12 FIFO checks in two
process-timeout-bounded scenarios, and 51 Python release-verification controls.**
Round-two independent static review closed both original M1/M2 P1s. Round-three
review closed the FIFO/integrity/reload fixes but found a **new blocking P1**:
`O_NOFOLLOW` rejects the symlink parent `/tmp` (also relevant to `/var` and `/etc`),
so documents directly in those folders lose automatic refresh. Parent reproduced
`/tmp` watcher failure with `ELOOP` (errno 62). Fix and direct-`/tmp` atomic-save
regression coverage remain outstanding; paused at the three-review-round limit
for user direction. Human/approval-blocked gates also remain pending.
**No formal milestone or v1 acceptance is claimed.**
Earlier-stage counts below are historical, not the latest verification.

### Before/after regression evidence

- **FIFO P1:** built the new isolated-probe FIFO entrypoints against the original
  watcher before changing it. Both actual `DocumentRefresh` paths (FIFO at initial
  open; regular document replaced with FIFO) blocked. Independent subprocesses were
  killed/reaped at **3.003/3.006 s**, `.build/round2-fifo-before.log`; build output
  `.build/round2-fifo-before-build.log`. No writer or actual-app launch was used.
  The watcher now opens `O_EVTONLY | O_NONBLOCK | O_NOFOLLOW`, checks the opened
  descriptor with `fstat`, accepts only regular file/directory, closes on rejection
  and preserves useful POSIX errors (`EINVAL` for unsupported descriptor type).
  The two regression processes have **10 s kill/reap timeouts each**, with the
  wrapper itself bounded at 30 s. Initial/start calls took **0.000125/0.000104 s**
  (<0.5 s asserted). Both scenarios reject FIFO descriptors, surface the expected
  initial/stale warning, retain last-good preview, recover after valid recreation
  and handle a subsequent atomic save: **6 checks each**,
  `.build/release-evidence/fifo-regression.txt`. Two new Swift tests cover normal
  file/directory watches and symlink rejection/preserved `ENOENT` errors.
- **Python release integrity P2:** before changes, all nine negative asset cases
  rejected under default Python. Under both `-O` and `PYTHONOPTIMIZE=1`, **eight
  cases incorrectly returned success**; unexpected manifest inventory instead
  failed incidentally with `FileNotFoundError`, not the intended inventory guard.
  `.build/round2-python-before.log` records these **18 failed negative assertions**.
  `scripts/verify_assets.py` and `scripts/verify_m0.py` now use explicit actionable
  guards, not optimizer-removable assertions. **51 controls PASS** under three
  interpreter modes: 30 asset controls (3 pristine + 27 negative) and 21 probe,
  fixture-integrity, assertion-free-source and actual-app approval-guard controls;
  `.build/round2-python-after.log`. Scratch data contains resources only, no app
  executable/Info.plist. Negative probe metadata includes both document-type and
  imported-UTI declarations; fixture hash and launch opt-in guards remain enforced.
- **Content-rule P2:** every accepted shell-rule compilation now removes installed
  lists immediately before adding the deny-network list and before shell load.
  Four additional bounded real-WebKit reloads retain renderer readiness and exact
  native CSP; existing gateway/CSP/network-denial checks still pass. This is a
  reload-behavior/source-order regression, **not an API-observed rule-list count**
  (WebKit exposes no public list-count accessor here).
- **Optional mismatch regression:** the disposable probe temporarily overrides the
  template DOM setter to append one stray anchor, then restores it in `finally`.
  Actual bundled rendering exercises token/DOM count mismatch: all links/images
  remain present but **every href/src/srcset capability is removed**. No production
  test hook, additional renderer API or renderer/resource-byte change was added.

### Recorded commands and local artifacts (2026-10-29)

| Command | Result |
| --- | --- |
| `CONFIGURATION=release bash scripts/test-webkit.sh` | PASS **16 Swift / 81 WebKit / 12 FIFO**; `.build/round2-release-webkit.log`, `.build/release-evidence/{swift-tests,webkit-integration,fifo-regression}.txt`. Actual app packaged/inspected only. |
| `python3 scripts/test-release-verification.py` | PASS **51 controls**, including all default/`-O`/`PYTHONOPTIMIZE=1` cases; `.build/round2-python-after.log`. |
| `npm test` | PASS **4 assets / 12 production license records / 2 byte-identical regenerations / 6 bounded advisory cases**; `.build/round2-assets.log`. |
| `python3 scripts/test-packaging.py` | PASS release signature/resources, **3 tamper rejections / 4 install guards**, dry-run without Applications creation and shell syntax; `.build/round2-packaging.log`. No mutating install branch executed. |
| `python3 [-O] scripts/verify_assets.py --bundle .build/release-package/MDViewer.app`; `PYTHONOPTIMIZE=1 python3 scripts/verify_assets.py --bundle .build/release-package/MDViewer.app` | PASS against the actual release in all three modes; `.build/round2-final-safety.log`. `[-O]` here denotes the two separately executed default and optimized invocations. |
| `codesign --verify --strict --verbose=2 .build/release-package/MDViewer.app`; `bash scripts/install.sh --dry-run` | PASS valid signature/designated requirement and verified dry-run only; `.build/round2-final-safety.log`. |
| `bash -n scripts/package.sh scripts/install.sh scripts/test.sh scripts/test-swift.sh scripts/test-webkit.sh`; Python AST/local-link/metadata/hash checks | PASS all Python script syntax, local doc links, probe isolation, original fixtures unchanged and no `.git`/staged files; `.build/round2-final-safety.log`. |

Fresh real-WebKit measurements: shell/first raster **0.208 s**; direct/truncate/
atomic refresh **0.268/0.298/0.216 s**; warm **1,026,025-byte** report **0.160 s**.
These are local measurements, not general timing guarantees. Compiler warnings
about unavailable CLT framework search paths and test-library macOS 14 deployment
remain as before; application target stays macOS 13, runtime untested there.

**Known limitation:** all windows share one serial `DocumentIO` actor. Bounded-byte
synchronous source/image reads cannot be interrupted mid-read, so slow/stalled
volume I/O can delay other windows' work. Cancellation/generation guards prevent
stale commits, not kernel I/O stalls; nonblocking FIFO handling is not a filesystem
metadata deadline. No scheduling redesign or slow-volume guarantee was introduced.

Changed in this final round: `Sources/MDViewerCore/{DirectoryWatcher,RenderHost}.swift`,
`Tests/MDViewerCoreTests/DirectoryWatcherTests.swift`,
`Tests/M0Integration/{Probe,WatcherProbe,HardeningProbe}.swift`,
`scripts/{verify_assets,verify_m0,test-release-verification,test-watchers}.py`,
`README.md`, `TEST_RESULTS.md`. No actual-app launch, Launch Services, installation,
defaults, pi-files, Git, sudo or network changes. Source fixture hashes remain
unchanged. Pending manual/approval gaps and historical M0 caveats below are retained.

---

## Review-fix stage (2026-10-29 continuation)

Independent review **blocked M2 acceptance** on two P1 defects. Both reproduced
before changes: `.build/review-p1-image-before.log` accepts a 27,262,976-byte
sparse PNG; `.build/review-p1-alt-before.log` fails image-alt capability discovery.
Fixed consistent exclusion of image-alt children and fail-closed DOM/token count
alignment. Trusted Docs-after-alt clicks now focus intro, and nested image aliases
retain correct capabilities. Fragment lookup tries exact duplicate IDs first,
then NFC/lowercase slug fallback. Vacuous image assertion replaced by DOM observation.

Image defaults: 25 MiB/file, 64 MiB bytes/read batch, 256 unique file reads,
2,048 reference resolutions, 16,384 px/axis, 16 million pixels/image (all frames),
64 million pixels/batch and 32 frames/image. `fstat` precedes bounded read;
identity de-duplicates device/inode (including hardlinks); rejected reads consume
byte/read budgets too. Blocked limits use placeholders. NUL is rejected before
POSIX path use. Request diagnostics default off; explicit probe diagnostics retain
at most 256 requests and 256 served URLs. Source reads use nonblocking/no-follow
open, descriptor regular-file/size checks, capped reads and before/after metadata
checks, preventing FIFO swaps from blocking. Package now verifies asset SHA-256,
sizes, allowlist and full notices with Python stdlib (no Node/network).

Review-fix automated gate: **PASS 10 Swift tests / 44 real-WebKit checks**;
`npm test` PASS (4 assets/12 licenses/two regenerations/6 bounded timing cases).
Logs `.build/review-fixes-webkit-final.log`, `.build/review-fixes-assets.log`.
M2 is **not formally accepted**: independent re-review and original human/
approval-blocked rows remain pending. M3 implementation follows only this local
automated gate, under the explicit continuation authorization.

---

## M3 live-refresh stage

Automated local gate PASS: `bash scripts/test-webkit.sh` (13 Swift tests / 59
real-WebKit checks), `npm test` (4 assets/12 licenses/two regenerations/6 bounded
advisory cases). Logs `.build/m3-webkit-final.log`, `.build/m3-assets.log`.
Main-thread session state uses one serial off-main DocumentIO actor for bounded
source/image reads; canonical parent+file vnode watchers compare inode/mtime/size,
rebind after replacement, debounce 200 ms, retry at 80/160/240 ms and cancel on
new generations/close. Unrelated sibling saves are filtered. A missing/invalid
source retains last-good DOM and shows a stale warning; recreation clears it.

Observed actual DOM updates: direct 0.213 s, truncate/rewrite 0.295 s, atomic
replacement 0.268 s; final rapid-save update <1 s. Deletion/recreation, invalid
UTF-8 recovery, watcher cleanup and pre-shell queuing PASS. Deterministic delayed
read completions, delayed WebKit prepare/stage/commit and close invalidate stale
work. JavaScript checks generation immediately before detached staging and final
DOM replacement; native checks each async continuation. Image/link capabilities
are staged transactionally: failure/cancellation retains committed capabilities,
and successful replacement retires them without deleting concurrent stages.
Actual-WebKit failure injection and practical scroll restoration PASS.

Limitations: valid partially written UTF-8/empty files can be displayed after
settling; debounce cannot infer writer intent. Asset-only changes need Cmd-R.
Reopening resolves retargeted symlinks; existing sessions follow their originally
canonical path. Parent-directory removal/replacement is not automatically rebound.
No formal M3 acceptance: independent review/manual app scenarios remain pending.
M4 local hardening follows this automated gate only.

## M4 local hardening stage

Local automated gate PASS: **14 Swift tests / 76 real-WebKit checks** in
`.build/m4-webkit-full.log`. New hostile fixture covers scripts/events/SVG/meta/
forms/objects/frames, remote and encoded/absolute/NUL/symlink image references,
unsafe/executable/credential links and all eight explicit highlight grammars.
No hostile image bytes were served; no document text entered local/session
storage/cookies, and the ephemeral store reports no website records. A dynamic
frame emits enforced `frame-src`; object `contentDocument` remains null and
popup adds no native window. **WebKit emitted no `object-src` event even with an
explicit HTML type**, so that stronger assertion was rejected as unsupported;
object absence in sanitized source, `object-src 'none'`, deny-network rules and
null embedded document are the actual evidence, not packet-level proof.
Unsolicited same-shell navigation is now denied except during native shell load.

Metadata regression verifies actual ImageIO-recognized 20,000-pixel PNG width is
rejected, and a generated valid 33-frame GIF exceeds the 32-frame cap. The
attempted 5,000x5,000 forged PNG was rejected by ImageIO itself (missing width
metadata); it is not misrepresented as a valid pixel-budget fixture.

Full bundled native/WebKit parse → tasklist → highlighting → sanitize → detached
stage → guarded DOM commit timings: title payloads 200,009/400,009/800,009 bytes
**0.098/0.165/0.316 s**; label payloads 10,001/20,001/40,001 bytes
**0.006/0.009/0.015 s**. Each asserts <5 s; outer probe has a 60 s timeout.
A representative **1,026,025-byte** report rendered in **0.171 s** warm (<1 s
planning target observed, not a universal bound). Direct/truncate/atomic refreshes
in this run were **0.263/0.300/0.215 s**. Hardware: Apple M4 Max, 36 GiB RAM (`sysctl` observed).

The native content-process termination delegate is tested by deterministic
callback injection against actual WebKit: two shell/preview reloads succeed,
the third stops with Cmd-R retry guidance, manual retry succeeds and resets the
budget, and closed hosts ignore callbacks. **No WebKit process was actually
killed**; real OS process termination remains a manual/reviewer gate. Recovery
retires capabilities, invalidates the shell epoch and fences pending callbacks.

Probe development failures are preserved in `.build/m4-webkit-*.log`. Missing
trusted-click events were diagnosed with `key=false, active=false` even when
DOM hit-testing was correct: another application could steal focus between
asynchronous operations. The isolated probe now waits for its own active key
window immediately before each native mouse event (no click retries, synthetic
DOM events or weakened routing assertion). Source/fixture hashes remain unchanged.

Independent review, true disconnected-network rendering, online packet observation,
human keyboard/copy/light-dark/VoiceOver and full-app multiwindow workflows are
still pending/approval-blocked. No formal M4/v1 acceptance is claimed. M5 local
release packaging/docs/install-script-only work follows this automated gate.

## M5 local release packaging, documentation and safety gate

Local automated gate PASS; **formal M5/v1 acceptance is not claimed**.
`CONFIGURATION=release bash scripts/test-webkit.sh` passes **14 Swift tests in
4 suites / 76 real-WebKit checks**, `.build/m5-release-webkit-final.log`; raw
release build, signing, system dependencies, deployment target, probe and source
hash records are in `.build/release-evidence/`. Actual MDViewer is inspected only.
Release app: `.build/release-package/MDViewer.app`; isolated release probe:
`.build/release-package/M0Integration.app` (no document types/imported UTI declarations).
Debug outputs remain separate. Native code is release-optimized; the CLT Swift
Testing wrapper deliberately still runs its reliable debug test configuration.

Fresh release observations (Apple M4 Max / 36 GiB): isolated WebKit construction
→ shell → first raster preview **0.217 s**; **not actual-app cold launch**.
Warm 1,026,025-byte report **0.159 s**; direct/truncate/atomic updates
**0.267/0.296/0.269 s**. Bundled unclosed-title timings at 200,009/400,009/800,009
bytes **0.099/0.165/0.301 s**; labels 10,001/20,001/40,001 bytes
**0.005/0.009/0.015 s**. These are measurements, not universal bounds.

`npm test` PASS: 4 emitted assets, 12 production source/SRI/license records,
two byte-identical regenerations and six bounded advisory cases;
`.build/m4-m5-assets.log`. Node-free **release** packaging with
`PATH=/usr/bin:/bin:/usr/sbin:/sbin CONFIGURATION=release bash scripts/package.sh`
PASS, `.build/m5-node-free-release-package.log`. The node-free verifier checks
source hashes/size/allowlists/notices **and** exact packaged resource/manifest
copies. No runtime Node/npm or renderer download is needed.

`python3 scripts/test-packaging.py` PASS repeatedly: release signature/resources,
three negative resource cases (tampered renderer, unlisted file, missing notice),
four fail-closed install argument guards, and dry-run without creating Applications.
Only resources, no executable or Info.plist, are copied into temporary validation
data. Logs `.build/m5-packaging-checks-current.log` (latest),
`.build/m5-packaging-checks-final.log`, `.build/m5-packaging-checks-repeat.log`.
Final Python syntax/local-document-link checks and release manifest/probe metadata
checks PASS; the source evidence still reports 14 Swift / 76 WebKit. All shell
syntax checks pass; `.git` is
absent and no files are staged. The first test incorrectly required fake HOME
itself to stay absent (`.build/m5-packaging-checks.log`); its exact producer was
not reproduced on isolated rechecks. The test now asserts the real installation
contract, **no Applications directory**, and reports any other HOME entries.
The parent was told the initial cache explanation was unconfirmed; no default or
installation action was used to diagnose it.

`scripts/install.sh` is authored but its mutating branch is **NOT RUN**. It requires
`--install`, verifies release identity/signature/resource bytes, targets only
`~/Applications/MDViewer.app`, refuses symlink destinations/running app and requires
`--replace` for existing installs. It stages/verifies, attempts rollback on final
move failure, retains the previous bundle if rollback fails, and never invokes
launch/registration/default/quarantine commands. Dry-run/guard checks do not prove
actual install/update/rollback correctness. README now documents explicit future
setup, Finder defaults/restoration to Sublime, pi-files system-open, updates,
uninstall, stale app paths and known limitations with approval caveats.

**Pending:** independent re-review, real installation/update/uninstall/rollback,
Finder/default and actual pi-files → actual-app cold/warm/multiwindow/Sublime flows,
human keyboard/copy/layout/light-dark/VoiceOver, disconnected-network rendering,
online packet observation, actual OS WebKit process kill and macOS 13 runtime.
No blocked human row was relabeled PASS. Historical M0 evidence is preserved below.

### Changed paths in this continuation (not a Git diff)

There is intentionally no Git repository. This inventory is implementation-source
provenance, not a claim that every original M0/M1 file is newly changed here.

- `web/renderer.js`, `Resources/Web/renderer.js`, `vendor-manifest.json`.
- `Sources/MDViewerCore/DocumentLocation.swift`, `Sources/MDViewerCore/AssetGateway.swift`,
  `Sources/MDViewerCore/DocumentIO.swift`, `Sources/MDViewerCore/DocumentRefresh.swift`,
  `Sources/MDViewerCore/DirectoryWatcher.swift`, `Sources/MDViewerCore/RenderHost.swift`.
- `Sources/MDViewer/DocumentWindow.swift`.
- `Tests/MDViewerCoreTests/AssetPolicyTests.swift`, `Tests/MDViewerCoreTests/DocumentLocationTests.swift`,
  `Tests/MDViewerCoreTests/DocumentRefreshTests.swift`, `Tests/M0Integration/Probe.swift`,
  `Tests/M0Integration/RefreshProbe.swift`, `Tests/M0Integration/HardeningProbe.swift`.
- `Fixtures/hardening.md`, `scripts/package.sh`, `scripts/verify_assets.py`,
  `scripts/verify_m0.py`, `scripts/install.sh`, `scripts/test-packaging.py`,
  `README.md`, `TEST_RESULTS.md`.

## Implementation outcome and scope recorded on 2026-10-29

Observed 2026-10-29 on arm64 macOS 26.7.1 (25G241), Swift 6.4/CLT SDK 27,
Node v25.8.2/npm 11.11.1. Application deployment target remains macOS 13;
actual macOS 13 runtime is untested. Initial invocation implemented M1/M2;
authorized continuation fixes the independent review and implements M3 onward. M0 review fixes and the safe 20-check rerun were supplied by the parent.

| Milestone | Current status |
| --- | --- |
| M0 | Prior feasibility PASS; parent security/test fixes retained. Historical Launch Services caveat is unresolved and preserved below. |
| M1 | Implemented; automated asset reproducibility, inventory, reference-rule investigation and real-WebKit renderer checks PASS. Independent review required. |
| M2 | Implemented and review fixes locally PASS; independent re-review and human/approval-blocked checks remain pending. |
| M3 | Implemented; historical 13 Swift / 59 WebKit checks passed for covered fixtures. Round-three review found the direct-`/tmp` symlink-parent refresh blocker described above. Not formal acceptance. |
| M4 | Round-two local hardening evidence: 16 Swift / 81 WebKit + 12 bounded FIFO checks passed. Round-three review identified the unresolved symlink-parent watcher blocker; human/real-crash/network-observation gates remain pending. |
| M5 | Local release packaging/probe/resources/install guards/docs PASS; mutating install/update/uninstall and defaults/pi-files/human acceptance NOT RUN. |

**Not v1 acceptance.** No actual MDViewer launch, `open`, registration/unregistration,
installation, default setter, Git initialization/commit/push, pi-files changes,
global tool installation, sudo or network configuration change was performed in
this invocation. Development-only registry requests/local npm installs were used.
Only the isolated no-document-type integration probe was directly executed.

## Automated verification recorded on 2026-10-29

Commands were run from the project root during the recorded implementation work.

| Command/action | Observed result and evidence |
| --- | --- |
| `npm ci --ignore-scripts --no-audit --no-fund` | PASS; 14 local host-platform packages installed. No lifecycle scripts/global installs. `.build/m1-npm-ci.log`. |
| `npm test` | PASS: 4 emitted asset hash/size records, 12 locked production package source/SRI/license records, complete license texts, offline shell/CSS references and **two byte-identical regenerations**; valid reference syntax and **6 bounded timing cases**. Latest `.build/round2-assets.log`; earlier `.build/m4-m5-assets.log`, `.build/m1-renderer-tests-final.log` retained. |
| `npm audit --omit=dev --json` | Exit 0; registry snapshot reports 0 vulnerabilities. `.build/renderer-audit.json`. Not an exhaustive security proof. |
| `CONFIGURATION=release bash scripts/test-webkit.sh` | Current PASS: **16 tests in 5 Swift suites / 81 real-WebKit checks / 12 process-bounded FIFO checks**, `.build/round2-release-webkit.log`. Historical debug/release 14/76, M3 13/59, review-fix 10/44 and M1/M2 7/40 logs retained. Actual app is packaged/inspected only, never launched. |
| `PATH=/usr/bin:/bin:/usr/sbin:/sbin bash scripts/package.sh` | PASS without Node/npm in PATH. Uses vendored assets, plist lint and strict ad-hoc signature verification pass. `.build/m1-offline-input-package.log`. This did not disconnect networking or measure packet traffic. |
| Python package/resource checks | PASS: all four manifest assets (including full notices) byte-match packaged resources and SHA-256; packaged manifest byte-matches source; probe metadata has neither `CFBundleDocumentTypes` nor `UTImportedTypeDeclarations`. |
| `bash -n scripts/package.sh scripts/test.sh scripts/test-swift.sh scripts/test-webkit.sh`; Python `ast.parse` of `scripts/verify_m0.py` | PASS. |
| `bash scripts/test.sh` with Launch Services opt-in removed | Expected STOP/nonzero, empty stdout, no build/launch operations; protective guard PASS. |
| Fixture SHA-256 before/after safe suite | PASS, original fixtures and generated opened copies/assets unchanged. `.build/m0-evidence/source-hashes.json`. `.git` absent, so no staged files. |

Package inspections still report actual entitlements `{}` (App Sandbox absent),
only system-library dependencies, ad-hoc signing and no notarization. The safe
suite packages the actual app for inspection but executes only
`.build/M0Integration.app/Contents/MacOS/M0Integration` (debug) or
`.build/release-package/M0Integration.app/Contents/MacOS/M0Integration` (release)
from `/private/tmp`. Legacy `M0Integration`/`m0-evidence` names remain deliberately;
current logs end `M0-M4 WEBKIT INTEGRATION PASSED: 81 checks`; FIFO child processes separately report 12 checks.

### Renderer and link coverage in actual WebKit

- Retained M0 shell/custom-scheme/CSP/data-store/navigation/gateway/watch checks.
  The full parser now discovers all real image tokens, replacing the M0 regex:
  inline, angle-delimited, titled and reference images decode via native opaque
  capabilities. The eight unsafe fixture images are six placeholders plus two
  parser-rejected inert forms, rather than assuming all parse identically.
- Representative fixture `Fixtures/renderer.md`: headings/emphasis/strike,
  inline/fenced code, quotes/rules/ordered/unordered lists/tables, disabled labeled
  checked/unchecked tasks, JavaScript highlighting, escaped Mermaid and hostile
  unknown-language fallback. Unique duplicate/collision/Unicode heading IDs are
  stable across rerenders; empty source has an explicit state.
- Script delimiters, template-looking text, raw scripts/events/SVG/frames remain
  literal. Only native-approved opaque link URLs reach the DOM; executable and
  custom-scheme targets have no href. Untrusted synthetic clicks are blocked.
- Real AppKit mouse events produce WebKit `isTrusted` clicks. A Unicode fragment
  scrolls/focuses the correct heading; five explicit clicks produce native local
  Markdown (including parent directory), https, mailto and reveal classifications.
  Shell never navigates. The probe records targets rather than invoking external
  apps, Finder or the real document coordinator/window UI.
- Native WebKit find finds known text and rejects missing text. Zoom increases,
  clamps at 0.5 and resets to 1. Selected heading text is readable; code/table
  computed overflow is horizontal scrolling. Native menu/status/path/accessibility
  wiring compiles but human interaction/VoiceOver is not asserted by this probe.
- Security regressions retain native raster type/descriptor containment, blocked
  traversal/symlink/out-of-root/data/file/remote resources, CSP events for image,
  script and connection policies, rejected fetch and no extra gateway bytes.
  Previously authorized decoded raster memory can still be reused by WebKit after
  gateway retirement; no immediate in-memory revocation claim is made.

During test development, a real-click assertion exposed fixed 150 ms timing as
flaky: the last observed click could still be the preceding label while DOM hit
coordinates remained correct. Replaced that delay with a bounded 5-second poll
for the expected trusted event (no click retries or weakened routing assertions).
Three complete safe reruns then passed. Initial diagnostic failures remain in
`.build/m1-m2-webkit-diagnostic.log`; they were test synchronization findings,
not evidence that external applications were launched.

## Renderer security investigation

Pins: markdown-it **15.0.3**, DOMPurify **3.4.17**, highlight.js **11.12.0**,
`@mdit/plugin-tasklist` **1.1.4**, helper override **1.1.3**; build-only esbuild
**0.28.2**. All transitives are locked. `vendor-manifest.json` records exact registry
source URLs/SRI, license hashes, language list and emitted SHA-256. Full production
notices are copied into `Resources/Notices/` and the app. Conservative inventory
includes 12 production packages, including non-browser CLI/type portions.

### GHSA-gfr2-rv44-r23c — investigated, not waived

The handoff research could not establish whether selected markdown-it 15.0.3
fixed the reported quadratic **unclosed multiline reference label/title** rule in
15.0.2. Inspected the actual integrity-locked npm 15.0.3 distribution (it ships
`dist/markdown-it.mjs`, not the upstream source/changelog layout):

- `node_modules/markdown-it/dist/markdown-it.mjs:1991–2059`: reference label
  `MAX_LABEL_LENGTH = 999`; early bound
  `if (rawLabel.length + pos - segmentStart > MAX_LABEL_LENGTH * 2) return false;`
  and final code-point check enforce the CommonMark label limit, not a feature
  disable. Scanning works on source positions instead of repeatedly rebuilding
  and rescanning the entire accumulated text.
- `node_modules/markdown-it/dist/markdown-it.mjs:354–389,2089–2096`: multiline
  title continuation carries parser state into
  `parseLinkTitle(src, pos, max, titleRes)` and advances source positions per line,
  rather than restarting title parsing at offset zero for every added line.
- `scripts/test-reference-performance.mjs` keeps default block-reference syntax
  enabled and asserts a reference link with title renders. Each adversarial input
  runs in its own child: **5 s process timeout, 4 s render ceiling**.

Final fresh 15.0.3 observations (`.build/m1-renderer-tests-final.log`):

| Case/source formula | Lines/bytes | Render ms |
| --- | --- | --- |
| `'[a]: /u "' + 'x\n'.repeat(n)` | 100,000 / 200,009 | 75.00 |
| Same unclosed title | 200,000 / 400,009 | 143.88 |
| Same unclosed title | 400,000 / 800,009 | 295.93 |
| `'[' + 'a\n'.repeat(n)` | 5,000 / 10,001 | 8.36 |
| Same unclosed label | 10,000 / 20,001 | 11.92 |
| Same unclosed label | 20,000 / 40,001 | 18.78 |

Negative control: locally installed 15.0.2 **only under ignored `.build/`**, with
scripts disabled; matching 800,009-byte title exceeded the **5 s child timeout**
(`ETIMEDOUT`, killed, no unbounded run). Its 400,009-byte title completed in
3,948.61 ms on this host. `.build/reference-negative-control.log` records the
final bounded negative-control case. Early exploratory comparison commands used
an incorrect nonexistent `index.mjs` package entry; the valid comparison imports
`dist/markdown-it.mjs`. No shipped pin was downgraded or patched.

Conclusion: actual pinned 15.0.3 source and bounded behavior avoid this reported
quadratic reference-rule failure; no CommonMark rule was disabled. This clears
this specific M1 blocker, **not all resource exhaustion or future advisories**.
Highlighting/parsing are still synchronous; 10 MiB source cap is not a general
CPU/image-memory bound. Local M4 stress/race/resource checks now pass as recorded
above; independent review and packet-level/real-crash gates remain pending.

Other researched constraints retained: `html:false` avoids the HTML-enabled
markdown-it advisory precondition; DOMPurify uses HTML-only string output with
`SANITIZE_NAMED_PROPS:true`, no SVG/MathML/XHTML, hooks, `IN_PLACE` or
`SAFE_FOR_TEMPLATES`. DOMPurify 3.4.17 was selected over the earlier versions in
research; Apache-2.0 and alternative MPL license texts are included. Highlight.js
uses only eight explicitly registered grammars and no autodetection. Native code
validates original URLs, then post-sanitization trusted code restores **only exact
native-generated opaque capabilities**, never the original untrusted href/src.
The registry audit reports zero known entries, not a vulnerability-free guarantee.

## Acceptance matrix recorded on 2026-10-29 (not full v1 acceptance)

| ID | Status | Current evidence / remaining gate |
| --- | --- | --- |
| A01 | NOT RUN / M5 | No defaults or pi-files integration authorized. |
| A02 | HISTORICAL PASS, current MANUAL | M0 cold/warm `open -a`/extension evidence below; no actual-app rerun after M2 because launch/registration prohibited. Finder UI untested. |
| A03 | HISTORICAL PASS + unit PASS | M0 canonical-window behavior; current canonical/symlink path tests pass. Current full-app multiwindow check remains approval-gated. |
| A04 | AUTOMATED PASS | Full renderer fixture and safe URL/image behavior in actual WebKit; human layout review pending. |
| A05 | MANUAL PENDING | Fully local resource build/render passes; networking was NOT disconnected. Do not equate CSP or node-free packaging with this scenario. |
| A06 | BLOCKED for symlink parents; covered fixtures AUTOMATED PASS, app MANUAL | Historical WebKit direct/truncate/atomic/rapid settled saves <1 s for covered fixtures. Round-three review reproduced watcher startup failure for documents directly in `/tmp` (`ELOOP`); the separate blocker plan remains unimplemented. |
| A07 | AUTOMATED PASS, app MANUAL | Bounded retries, missing/invalid UTF-8 warnings, last-good DOM/capabilities and delete/recreate recovery pass. |
| A08 | AUTOMATED PASS + current app MANUAL | Literal/canonical/BOM/encoding tests and earlier M0 opens; current full-app UI not rerun. |
| A09 | AUTOMATED LOCAL PASS, REVIEW/MANUAL PENDING | Full bundled hostile/advisory pipeline, resource caps, storage, navigation and deterministic race checks pass; actual process kill, true online packet observation and independent re-review remain pending. |
| A10 | AUTOMATED ROUTING PASS, MANUAL PENDING | Trusted events invoke exact native target classifications without leaving shell; actual external browser/mail, coordinator window creation and Finder confirmation intentionally not invoked. |
| A11 | AUTOMATED PARTIAL, MANUAL PENDING | Native WebKit find/zoom/selection/overflow pass; menus/accessibility labels compile. Human keyboard/copy/layout/light-dark/VoiceOver still required. |
| A12 | AUTOMATED PASS | Empty state, escaped unknown/Mermaid fences, readable >10 MiB rejection in input tests. |
| A13 | SCRIPT/DOCS AUTOMATED PARTIAL; REAL ACTIONS NOT RUN | Release resources/signature/tamper checks, install guards/dry-run and README instructions pass; no actual install/update/default/pi-files action authorized. |
| A14 | AUTOMATED PASS | All four emitted assets and notices inventoried, reproducible and packaged byte-for-byte; no Node/npm required for app packaging. |

No new permission, code, architecture or milestone expansion was used to bypass
these pending gates. Independent re-review and the remaining acceptance checks
are required before formal milestone/v1 acceptance.

---

# Historical M0 feasibility evidence (preserved)

The following records the earlier M0 run, not actions repeated in this invocation.
Its pre-M1 scope and deferred-feature descriptions are historical. The current
status and commands above supersede those descriptions; the Launch Services and
packet-observation caveats remain applicable.

## Historical outcome and scope

**Technical M0 feasibility: PASS on this host. Historical final acceptance was
review-required with the unresolved Launch Services integration caveat below.
The parent subsequently fixed review findings and authorized M1/M2.**

Only M0 of PLAN.md was implemented. A real locally packaged AppKit/WKWebView app
receives URL-based open events, renders an inert local fixture and an allowed
raster, enforces the tested resource/CSP boundaries, and supports a viable
parent-directory watch under its inspected non-sandbox configuration. Swift
Testing and real WebKit integration both ran under Command Line Tools alone.
This is not v1 acceptance, full Markdown rendering, installation or notarization.

## Host and toolchain

Observed 2026-10-29 (host clock):

| Observation | Result |
| --- | --- |
| `sw_vers` | macOS 26.7.1, build 25G241 |
| `swift --version` | Apple Swift 6.4, swiftlang-6.4.0.34.1; clang-2100.3.34.1; arm64-apple-macosx26.0 |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` |
| `xcrun --show-sdk-version` | 27.0 |
| App Mach-O and minimum | Thin arm64; `LC_BUILD_VERSION minos 13.0` |
| Framework/API baseline | Application compiles targeting macOS 13; no newer-API availability errors. Actual macOS 13 runtime NOT tested. |

No full Xcode, new tool, Node package or renderer library was installed.
SwiftPM uses its supplied `swiftbuild` engine, not a different app architecture.

### CLT test-framework finding and workaround

Plain `swift test --disable-xctest --enable-swift-testing` was not reproducible
after rebuilding tests: `external macro implementation type 'TestingMacros.TestDeclarationMacro' could not be found for macro 'Test'; plugin for module 'TestingMacros' not found`.
The installed plugin exists at
`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`.
Loading it explicitly succeeds:

```sh
swift test --build-system swiftbuild --disable-xctest --enable-swift-testing \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
# 4 tests in 2 suites passed (Testing Library Version 2084).
```

`scripts/test-swift.sh` discovers that installed toolchain path through `xcrun`.
The alternative deprecated `--build-system native` failed with `no such module 'Testing'`;
it is not used by the final scripts. No Xcode-only test runner is required.
CLT emits harmless missing `Developer/usr/lib` / `Developer/Library/Frameworks`
search-path warnings. Its **test** framework links with a macOS 14 minimum warning;
this does not verify running these tests on macOS 13 and does not change the app's
proposed deployment target. Raw diagnostic logs: `.build/m0-evidence/swiftbuild-test-failure.txt`,
`.build/m0-evidence/native-test-failure.txt`, `.build/m0-evidence/testing-plugin-probe.txt`.

## Verification actually run

From the project root during the historical M0 run:

```sh
bash scripts/test.sh
```

The full suite completed successfully **before the later Launch Services safety
guard was added**. No further app launches were performed after discovering the
handler caveat. The same guard now requires explicit approval/opt-in before this
entrypoint can rerun its GUI/Launch Services portion. Its new before/after handler
comparison has only been statically checked, not exercised through another launch.

Successful full-suite stages (individual logs in `.build/m0-evidence/`):

| Stage / exact command family | Observed result |
| --- | --- |
| `bash scripts/test-swift.sh` | 4/4 Swift Testing tests, two suites; canonical/literal paths and BOM; invalid UTF-8/oversize/empty input; component/symlink containment; 13 forbidden reference forms; actual raster type validation. |
| `bash scripts/package.sh` | SwiftPM build; explicit `.app` executable, Info.plist and three Web resources; plist lint; ad-hoc signing and strict signature verification pass. |
| `codesign --verify --strict --verbose=2 .build/MDViewer.app` | `valid on disk`, `satisfies its Designated Requirement`. |
| `codesign -d --entitlements - .build/MDViewer.app` (and packaged probe) | Exit 0, no entitlement payload; effective dictionary `{}`. `com.apple.security.app-sandbox` absent in BOTH signed executables. This is intentionally not an OS sandbox guarantee for host filesystem reads. |
| `codesign -dvvv .build/MDViewer.app` | `Identifier=de.local.mdviewer`, `Signature=adhoc`, `TeamIdentifier=not set`. Not notarized. |
| `otool -L` / `otool -l` on app and probe | System libraries/frameworks only; no build-tree dylib dependency. Build-tree/CLT search rpaths exist but are not required dependencies. App target minimum 13.0, runtime tested only on this host. |
| `swift build --build-system swiftbuild --product M0Integration` | Builds the real AppKit/WebKit integration executable without XCTest/Xcode GUI. |
| `.build/M0Integration.app/Contents/MacOS/M0Integration <absolute .build/m0-fixtures path>` from `/private/tmp` | **20/20 checks pass**, real window/WKWebView, not a JavaScript-only mock. |
| `/usr/bin/open -a <absolute .build/MDViewer.app path> ...` and `open -a MDViewer ...` from `/private/tmp` | Cold/warm/multiple/literal/Unicode opens and canonical alias focus pass; details below. |
| SHA-256 snapshots before/after | Source `Fixtures/` plus opened copies and adjacent assets unchanged; no sidecar HTML/source writes. |

### Final non-launch verification after the safety amendment

- `bash scripts/test-swift.sh` rerun: **4/4 pass**, two suites, build exit 0.
  Fresh raw log: `.build/m0-evidence/final-swift-tests.txt`.
- `bash -n scripts/package.sh scripts/test.sh scripts/test-swift.sh` and Python
  `ast.parse` of `scripts/verify_m0.py`: pass.
- `bash scripts/test.sh`, invoked via Python with
  `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES` removed: expected nonzero STOP exit,
  empty stdout and no build/launch operations; protective guard **PASS**.
  Exact stderr: `.build/m0-evidence/default-guard.txt`.
- Python SHA-256 comparison against `.build/m0-evidence/source-hashes.json`:
  **4 original fixtures and 9 opened copies/assets unchanged**. `.git` absent.
- Python byte comparisons: packaged Info.plist and all three Web resources
  exactly match their source files.
- `codesign --verify --strict --verbose=2 .build/MDViewer.app` and the same command
  for `.build/M0Integration.app`: both valid on disk/designated requirement satisfied.
- `plutil -lint Packaging/Info.plist`: OK. Retained real-WebKit log has all 20 checks.

No app process was launched in these final checks. The opted-in before/after
handler-comparison branch remains unexecuted after its addition.

### Real WKWebView observations (20 checks)

- Bundled shell, JS and CSS load via `mdviewer://bundle/`; actual heading text
  equals `M0 safe fixture`. Native `callAsyncJavaScript` transfers source as an
  argument, never string-concatenated code. Nonpersistent WebKit data store verified.
- Response CSP and shell meta CSP agree. A 1×1 in-root PNG actually decodes in
  WebKit after being rewritten to an opaque session/generation/random asset URL.
- Hostile source containing `<script>`, `</script>`, quotes, backticks and `${...}`
  remains literal DOM text. All eight Markdown image references (remote,
  javascript, traversal, encoded traversal, symlink escape, data, file and SVG)
  produce blocked placeholders; no document script execution.
- A test-only injection from native code adds adversarial DOM resources to bypass
  the tiny renderer deliberately: HTTPS/HTTP images, file/data images, forged and
  traversal gateway URLs, inline and remote script elements, an unallowlisted
  bundled script, and `fetch`. No forbidden image decodes or inline script execution;
  `fetch` rejects. Real `securitypolicyviolation` events report `img-src`,
  `script-src-elem` and `connect-src` with the attempted URLs.
- Gateway served-resource count is unchanged during forbidden requests; the
  unallowlisted script reaches the handler and is denied. No arbitrary path URL is
  mapped to a filesystem read. Raster policy validates canonical root containment,
  actual opened descriptor path, regular-file status and image type before reading/serving.
- Native navigation delegate cancels an unsolicited web-link navigation; the
  main URL remains the trusted shell. `javascript:` navigation does not execute.
  A deny-external-URL WebKit content rule list is an additional backstop.
- **Cache finding:** a previously authorized image can be decoded again from
  WebKit memory after its gateway capability is retired, despite `no-store`.
  Observed `cachedPreviousRaster=1`, `forbiddenDecoded=0`, `inline=0`, `fetchBlocked=1`.
  No new bytes were served. This is cached authorized data, not an out-of-root read.
  New renders issue fresh versioned URLs; no claim of immediate cache revocation.
- The signed packaged probe watches a temporary parent directory and detects
  create, atomic replacement, deletion and recreation. Adjacent image and watch
  access succeed under its inspected actual non-sandbox entitlements. This is the
  M3 primitive only, not a working live-reload/debounce/retry state machine.

The initial integration run exposed a test expectation of nine blocked images
where the fixture has eight; corrected after inspecting the fixture. Another
initial expectation incorrectly treated WebKit's cached authorized image as a
new forbidden read; corrected to test forbidden resources separately and record
the cache limitation (raw `.build/m0-evidence/webkit-cache-observation.txt`).

### Actual URL open-event evidence

All emitted events in the successful run came from the same application process,
through the sole `application(_:open:)` callback:

1. Cold launch: `safe.md` → one window and successful render.
2. Warm name-based `open -a MDViewer` with `space ü 日本.markdown` → two windows,
   literal Unicode/space path and successful render.
3. One two-file request for `hostile.md` and `literal '% $(false).md` → callback
   `count=2`, windows three and four; both rendered without shell interpolation.
4. Open `canonical alias.md` symlink to `safe.md` → focus existing canonical window;
   still four windows. The test stops only its own logged PID afterward.

Complete JSON event stream: `.build/m0-evidence/open-events.jsonl`.
`MDVIEWER_M0_EVENTS=1` explicitly opts into path/event-only stdout for this test;
normal launches do not log source or paths. No Markdown contents are logged.
Both extensions resolve to `net.daringfireball.markdown`; Info.plist declares
Viewer/Alternate and imports that UTI with `.md` and `.markdown`. Read-only handler
queries show MDViewer among eligible handlers for both. Finder's UI is not tested.

## Unresolved Launch Services integration caveat — do not hide

After the successful explicit `open -a` tests, a read-only query reported:

```text
.md       net.daringfireball.markdown → effective default de.local.mdviewer
.markdown net.daringfireball.markdown → effective default de.local.mdviewer
```

`swift scripts/inspect-handlers.swift` uses only `LSCopyDefaultRoleHandlerForContentType`
and `LSCopyAllRoleHandlersForContentType`; Sublime (`com.sublimetext.4`) is also eligible.
A narrow read of
`~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`
found 17 explicit `LSHandlers` entries but **none** for Markdown, plain text, or MDViewer.
This supports a derived association rather than an explicitly stored default
preference. **There is no captured before-state, so causality/prior default cannot
be proven.** `LSHandlerRank=Alternate` is not a guarantee against macOS selecting a
registered app when no explicit default is pinned.

No default-setting API, Finder Change All, setter command, explicit registration,
unregister, restoration, quarantine removal or installation was used. Launching
an app nevertheless lets macOS register it and may influence a derived handler.
After this discovery: no further app launches/registration operations; supervisor
authorized read-only inspection only. Restoration must await user approval, not
an assumed previous Sublime setting. Evidence:
`.build/m0-evidence/effective-handlers.json` and `.build/m0-evidence/explicit-handlers.json`.

The full-suite entrypoint now stops BEFORE operations unless
`MDVIEWER_M0_ALLOW_LAUNCH_SERVICES=1` is deliberately supplied after approval;
it also snapshots handlers before/after and fails on a change without restoration.
Swift-only tests remain independently available. This caveat prevents an
unqualified claim that all system associations are known to be unchanged.

## Network-observation limitation and remaining manual checks

CSP enforcement events, rejected `fetch`, zero forbidden gateway bytes, native
URL policy and WK content rules establish the tested in-WebKit boundaries.
They are **not packet-level evidence of zero network attempts**. Tested external
URLs use the reserved `.invalid` domain; failure to load alone is not the proof.

An unprivileged packet-observation attempt was denied:

```text
/usr/sbin/tcpdump -i pktap,all -n 'host 192.0.2.1'
tcpdump: ioctl(SIOCIFCREATE): Operation not permitted
```

No sudo, privilege change, system installation, network server or general network
capture followed. The full separately observed online/offline network audit is
still M4/manual work, requiring an approved observation method. No claim that
networking was disconnected or that packet silence was measured.

Still unverified/deferred: human-visible window layout, menu shortcuts/copy,
Finder Open With for both extensions, true offline run and packet observation,
macOS 13 runtime, VoiceOver, full Markdown/highlighting/sanitization, find/zoom,
link routing, reload reliability and resource-exhaustion hardening, installation,
default selection/rollback, pi-files and Sublime integration. A01/A04–A07/A10–A14
are NOT accepted; M0 gives partial feasibility evidence for A02/A03/A08/A09 only.

No Git metadata was created; no files were staged, committed or pushed. No
pi-files files, system tools or `~/Applications` contents were changed.
