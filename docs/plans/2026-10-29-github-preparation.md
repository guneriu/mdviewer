# GitHub Preparation Implementation Plan

> **For agentic workers:** Follow this plan task-by-task using the executing-plans process. The parent coordinates one worker and independent validation/review; do not launch children or perform Git operations.

**Goal:** Prepare the accepted MDViewer source tree and documentation for a future GitHub push without changing app behavior or publishing anything.

**Architecture:** Keep the existing source, documentation, and packaging layout. Replace work-session prose in the landing page with durable user guidance, sanitize authored documentation, explain packaging responsibilities, and add the owner-selected MIT license. Keep historical acceptance evidence separate from current feature claims.

**Tech Stack:** Markdown documentation, SwiftPM/AppKit/WebKit app, shell packaging, Python validation, private npm renderer tooling.

## Approved boundaries

- Focused cleanup only; no broad directory moves or app feature changes.
- License: standard MIT, copyright 2026 MDViewer contributors. Third-party licenses remain unchanged.
- No Git initialization, commits, pushes, repository URL invention, CI setup, network access, package installation, rebuilds, app launches/restarts, installation, or file-association changes.
- Preserve all dependency versions, renderer assets, source/tests, scripts, bundle identity, signing behavior, and packaging output locations.
- Keep the known `/tmp` parent-symlink watcher limitation visible; the separate blocker plan is not implemented by this task.

## Task 1: Restructure the landing page

**Modify:** `README.md`.

- [x] Lead with what MDViewer is: a local, offline, read-only macOS Markdown viewer, not an editor, browser service, or Node runtime.
- [x] Explain supported Markdown, explicit syntax highlighting, plain-code Mermaid fallback, local-image restrictions, native links, search/zoom, and live refresh.
- [x] Give build requirements accurately: deployment target is not a tested compatibility guarantee; Node/npm are only needed to regenerate renderer assets.
- [x] Separate building/verification, deliberate app launch, optional installation, and explicit default-handler selection. Preserve the warnings about macOS app discovery and unsigned/not-notarized distribution.
- [x] Explain quitting and reopening the intended app after rebuilding/replacing it: changing a binary on disk does not update an already-running process. Do not claim the old live-reload incident proved a particular source-code defect.
- [x] Explain updates, removal, manual Reload for asset-only changes, relevant security limits, and current known limitations without milestone-gate prose dominating the landing page.
- [x] Link to specification, implementation plan, historical acceptance results, packaging guide, and licenses. No fabricated GitHub owner/repository URL or passing CI badge.

## Task 2: Publication hygiene and supporting documentation

**Modify as needed:** `.gitignore`, `PLAN.md`, `SPEC.md`, `TEST_RESULTS.md`, authored Markdown under `docs/`.
**Create:** `Packaging/README.md`; add a small documentation index or contributor guide only if it meaningfully avoids README duplication.

- [x] Replace personal absolute paths, account identifiers, agent-session paths, temporary evidence locations, and private machine-specific workflow references with portable examples or repository-relative links.
- [x] Preserve technical findings, historical test counts, unresolved limitations, security constraints, and meaningful acceptance history. Label dated evidence as historical rather than current universal guarantees.
- [x] Keep existing document locations and repair relative links and cross-document references affected by editing.
- [x] Keep `.build/`, `.swiftpm/`, and `node_modules/` ignored; add justified Python/cache/local-artifact ignores without hiding vendored runtime assets or dependency locks.
- [x] In `Packaging/README.md`, distinguish `Package.swift` (Swift targets), private `package.json` (renderer regeneration), `Packaging/Info.plist` (app metadata), and generated app bundles. Document debug/release outputs, signing, safe verification, and explicit installation boundaries.
- [x] State that packaging overwrites generated outputs and that app installation is a separate opt-in operation. Do not imply package.sh refuses a running app; only the installer has that guard.

## Task 3: Owner-selected license

**Create:** `LICENSE`.
**Modify:** `package.json` and the root package entry in `package-lock.json` for license metadata only.

- [x] Add the complete standard MIT text with `Copyright (c) 2026 MDViewer contributors`.
- [x] Add `"license": "MIT"` to the private renderer-tooling manifest and matching lockfile root entry; retain `"private": true` and every dependency, override, version, integrity value, and third-party license.
- [x] Explain MDViewer's MIT license separately from bundled third-party terms in `THIRD_PARTY_NOTICES.md` and `Resources/Notices/`. Do not modify verified third-party notice files or their hashes.

## Task 4: Safe verification and independent review

- [x] Check authored Markdown relative links and publication-sensitive path patterns. Report intentional exceptions; do not scan generated build outputs or dump minified assets.
- [x] Run `for script in scripts/*.sh; do bash -n "$script" || exit; done` and `plutil -lint Packaging/Info.plist` without executing packaging/install/test wrappers.
- [x] Run `PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_assets.py`; verify license JSON consistency and unchanged dependency data.
- [x] Confirm protected source/test/resource/script/metadata fingerprints are unchanged, generated app outputs were not rebuilt, and Git metadata remains absent.
- [x] Give the parent exact changed paths, concise validation results, any unresolved owner decisions, and an external review artifact. The parent performs fresh verification and independent review before final acceptance.

## Acceptance

The repository is cleaner and documented for a future push, not declared a notarized or fully accepted release. Existing app behavior and packaging remain intact; known limitations and the historical nature of acceptance evidence are clear. Publishing, Git setup, and fixing the separate watcher blocker remain outside this task.
