# AGENTS.md — rules for contributors and coding agents

Read [ARCHITECTURE.md](ARCHITECTURE.md) first. The product contract is
[docs/specs/2026-10-29-mdviewer-v1-design.md](docs/specs/2026-10-29-mdviewer-v1-design.md).

## Documents

- Specs and designs go in `docs/specs/YYYY-MM-DD-<topic>-design.md`.
- Implementation plans go in `docs/plans/YYYY-MM-DD-<feature>.md`, with checkbox steps and TDD order (failing test → fix → passing test → commit).
- Record dated verification results in `TEST_RESULTS.md`. Scope every claim: an isolated probe passing is not proof that the actual app or Launch Services works.
- When a rendering, image or link feature changes, update `examples/showcase/showcase.md` with a section stating the expected result (see `examples/README.md`). Automated regression fixtures stay in `Fixtures/`.
- Keep `README.md` user-facing (install, use, limitations) and `docs/README.md` developer-facing.

## Commands

```sh
bash scripts/test-swift.sh                      # native unit tests (never bare `swift test`)
swift build --build-system swiftbuild --product M0Integration
python3 scripts/test-watchers.py "$(swift build --build-system swiftbuild --show-bin-path)/M0Integration"
node scripts/test-renderer-assets.mjs && node scripts/test-reference-performance.mjs
python3 scripts/test-release-verification.py
bash scripts/test-webkit.sh                     # isolated debug verification
CONFIGURATION=release bash scripts/test-webkit.sh
CONFIGURATION=release bash scripts/package.sh   # release bundle
```

Set `PYTHONDONTWRITEBYTECODE=1` for Python scripts if you don't want `__pycache__` in the tree.

## Hard rules

- **Do not launch, install, or register the real app** unless the user explicitly asks. That covers `open`, `lsregister`, `scripts/install.sh --install`, and changing `.md`/`.markdown` defaults. Keep `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES` unset. Automated checks use the isolated `M0Integration` probe.
- **Never weaken security protections** without an approved spec change. Protected behavior:
  - `O_NOFOLLOW`/`O_NONBLOCK`/regular-file checks
  - the 10 MiB source cap
  - image containment and budgets
  - CSP, content rules and the ephemeral WebKit store
  - DOMPurify sanitization and raw HTML staying off
  - capability-matched `mdviewer:` URLs
- **The viewer is read-only.** Never write to source documents. Tests write only their own UUID-named fixtures and clean them up; never bulk-delete `/tmp/MDViewer-*` or touch system directories.
- **No network** at build or run time. Changes to vendored renderer assets go through `npm ci --ignore-scripts && npm run build` and must update `vendor-manifest.json` and the notices together.
- **Bound every long-running test.** Watcher and WebKit probes run in child processes with timeouts. Do not raise a timing threshold just to make a test pass; investigate the cause.
- Write the failing test first, and keep the red output as evidence for bug fixes.
- Keep diffs minimal. Stop and ask before broadening a fix beyond its plan's file map.

## Git

- Default branch `main`. Use conventional commit prefixes (`feat:`, `fix:`, `test:`, `docs:`, `chore:`).
- `.build/`, `.swiftpm/`, `node_modules/`, `.idea/` are ignored. Never commit generated apps or evidence.
