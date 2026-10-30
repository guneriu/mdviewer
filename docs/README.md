# Development and evidence index

Start with the [user README](../README.md) for behavior and setup, and the
[packaging guide](../Packaging/README.md) for build inputs, generated bundles,
inspection and installation boundaries. This index keeps contributor commands
and historical engineering records out of the landing page.

## Project contract and history

- [Specification](specs/2026-10-29-mdviewer-v1-design.md): original product/security requirements and A01–A14 criteria.
- [Implementation plan](plans/2026-10-29-mdviewer-v1.md): original M0–M5 implementation sequence and acceptance gates.
- [TEST_RESULTS.md](../TEST_RESULTS.md): dated implementation observations, historical
  test counts, unresolved Launch Services caveat and remaining manual acceptance.
  Local `.build/` log paths in that record identify untracked evidence from the
  original machine, not files promised to exist in a fresh source checkout.
- [Implementation continuation](implementation-continuation.md): historical scope,
  dependency decisions and first-review findings.
- [Round-two fixes](round-two-fixes.md): historical FIFO, optimized-Python verifier
  and content-rule regression work.
- [Temporary-parent watcher blocker](plans/2026-10-29-tmp-parent-watcher-blocker.md):
  executed; direct-`/tmp` documents now live-refresh.
- Post-v1 round (2026-10-30), shipped: [scroll anchoring and Follow Changes](specs/2026-10-30-scroll-anchor-follow-changes-design.md)
  ([plan](plans/2026-10-30-scroll-anchor-follow-changes.md)) and
  [image auto-refresh](specs/2026-10-30-image-auto-refresh-design.md)
  ([plan](plans/2026-10-30-image-auto-refresh.md)).
- Post-v1 round, parked: [Quick Look extension](specs/2026-10-30-quick-look-extension-design.md)
  ([plan](plans/2026-10-30-quick-look-extension.md)); the spike extension was not discovered by macOS.
- Post-v1 round, dropped: [mdv CLI](specs/2026-10-30-mdv-cli-design.md); a shell alias covers it.
- [GitHub preparation plan](plans/2026-10-29-github-preparation.md): focused
  documentation/license cleanup, not authorization to publish or fix the watcher.

Historical implementation instructions are records, not blanket permission to run
app launches, install tools, change defaults, or resume unfinished milestones.
The specification's deployment target is not a tested compatibility promise.

## Development checks

Run commands from the project root and understand their side effects first.
These contributor entrypoints are not a claim that the latest checkout passes
them; use dated verification evidence and preserve outstanding acceptance gaps.

### Read-only source checks

```sh
for script in scripts/*.sh; do bash -n "$script" || exit; done
plutil -lint Packaging/Info.plist
PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_assets.py
```

### Native, WebKit and packaging checks — rebuilds or test execution

```sh
bash scripts/test-swift.sh
bash scripts/test-webkit.sh
CONFIGURATION=release bash scripts/test-webkit.sh
python3 scripts/test-packaging.py
python3 scripts/test-release-verification.py
```

The Swift wrapper explicitly loads the installed CLT Swift Testing macro plugin;
plain `swift test` was unreliable on the recorded toolchain. Tests require macOS
14 even though the app targets macOS 13.

The WebKit wrapper packages/signs the real app for inspection but directly executes
only a dedicated isolated integration probe whose metadata has no document types
or imported UTI declarations. It needs a logged-in graphical session, does not
invoke `open`, launch the actual document app, or call external applications, and
writes local logs under `.build/m0-evidence/` or `.build/release-evidence/`. It also
runs the separate FIFO scenarios with child-process kill/reap timeouts. Its current
coverage does **not** close the symlink-parent watcher blocker.

Packaging checks use resource-only scratch data and install guards/dry-run, not a
mutating installation. Release-verification controls exercise pristine/tampered
resources and probe guards under default Python, `python3 -O` and
`PYTHONOPTIMIZE=1`; release trust checks must not depend on removable assertions.

`bash scripts/test.sh` is a different, historical full open-event suite. It stops
before operations unless `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES` is explicitly supplied.
Do not enable it without separate approval for actual-app/Launch Services effects.
Its before/after handler comparison does not automatically restore associations.

Automated probe results do not replace human keyboard/VoiceOver/layout checks,
actual Finder/pi-files/Sublime workflows, true offline and online packet
observation, real process termination, install/update/rollback or older-OS testing.
Preserve those distinctions when reporting results.

## Renderer pins and regeneration

Normal packaging consumes vendored assets. Only deliberate renderer development
needs an existing Node **>=22** and local npm. These commands install local
packages, regenerate assets and run JavaScript tests; the optional audit contacts
the registry. They are not read-only inspection or runtime requirements.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm test
# Optional development-only registry advisory snapshot:
npm audit --omit=dev --json
```

Exact pins are markdown-it **15.0.3**, DOMPurify **3.4.17**, highlight.js **11.12.0**,
`@mdit/plugin-tasklist` **1.1.4**, helper override **1.1.3**, and build-only esbuild
**0.28.2**. Keep the tooling package private. Lifecycle scripts are disabled; the
locked platform esbuild optional package supplies its binary. No global installation
is needed. `package-lock.json` locks transitives; `vendor-manifest.json` records
source URLs/SRI, license hashes, language list, and emitted asset SHA-256.

The asset tests cover hashes, lock/license completeness, local shell/CSS references,
two byte-identical regenerations, enabled CommonMark reference syntax and bounded
advisory cases. The
[renderer security investigation](../TEST_RESULTS.md#renderer-security-investigation)
records the actual pinned-source analysis and timed-out 15.0.2 negative control for
GHSA-gfr2-rv44-r23c. A zero-entry registry snapshot is not a vulnerability-free claim.

## Contribution boundaries

- Preserve the native offline/read-only model and security policy. Do not solve a
  fixture failure by allowing raw HTML, broad filesystem reads or remote resources.
- Edit authored inputs, not `.build/`, `node_modules/` or generated app bundles.
  Renderer changes must regenerate assets, inventory and notices coherently, with
  exact pins and byte/hash checks. Preserve full upstream license texts.
- Add source-named regressions for behavioral changes. Record the command, fixture,
  expected/observed result, OS/toolchain and remaining limitations; date test counts
  rather than presenting old local evidence as new acceptance.
- Keep personal document paths, account identifiers, agent-session locations and
  process identifiers out of authored public documentation. Technical examples
  such as `/tmp`, `/private/tmp`, `~/Applications` and toolchain paths are meaningful
  constraints, not private account data.
- Keep app launch, installation and association changes explicit and separate from
  building. Quit/reopen the intended bundle after rebuild/replacement. Do not
  remove quarantine or weaken system security to make a check pass.

Project terms are [MIT](../LICENSE); bundled dependency terms remain in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and
[Resources/Notices/](../Resources/Notices/). Git setup, hosting, CI and public
release/notarization are separate owner decisions; this documentation invents no
repository URL or passing CI status.
