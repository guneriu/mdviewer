# Temporary-Directory Parent Watcher Blocker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Follow the operator's parent-driven, single-writer delegation rules rather than scripted workflows.

**Goal:** Restore automatic refresh for Markdown files directly inside `/tmp`, without weakening the no-follow, nonblocking-open, regular-file, or source-read-only protections.

**Architecture:** Resolve only the parent-directory watch URL with POSIX `realpath` before constructing its existing `DirectoryWatcher`. Leave canonical document identity, asset containment, source reads, and file-watcher rebinding unchanged. Prove the fix with native tests and separate timeout-bounded integration-probe processes, not the actual application.

**Tech Stack:** Swift 6.4 toolchain, Swift Testing, Foundation, Darwin/POSIX, Dispatch filesystem sources, Python 3, the existing isolated `M0Integration` executable.

**Repository:** standalone `mdviewer/` project; commands are relative to its root.

**Authorization:** This document is a plan, not implementation approval. Do not execute it until the user authorizes implementation. During execution, do not install the application, launch the actual `MDViewer` application, invoke `open` or `lsregister`, change `.md`/`.markdown` defaults, initialize Git, or commit anything. This checkout is not a Git repository. Building/signing local artifacts and directly executing the dedicated isolated probe are the verification scope described below, not Launch Services acceptance.

---

## Evidence and scope

The existing round-three blocker was reproduced before this planning task:

1. `Sources/MDViewerCore/DocumentLocation.swift:8,15` derives `assetRoot` from `url.standardizedFileURL.resolvingSymlinksInPath()`. On this Mac, Foundation returns `/tmp` as the parent even for the corresponding `/private/tmp` input.
2. `/tmp` is itself a symlink to `/private/tmp`.
3. `Sources/MDViewerCore/DirectoryWatcher.swift:8-22` opens its argument using `O_EVTONLY | O_NONBLOCK | O_NOFOLLOW`, then validates the descriptor with `fstat`.
4. `Sources/MDViewerCore/DocumentRefresh.swift:29-34` passes `location.assetRoot` directly to that initializer. A document directly under `/tmp` therefore throws `POSIXError(.ELOOP)` before either watcher is established.
5. `Sources/MDViewer/DocumentWindow.swift:74` catches the startup failure and requests a one-off reload. That can display the document, but it does not restore automatic refresh.

**Chosen approach:** Obtain the physical parent path with `Darwin.realpath`, use that path only for the parent-directory watcher, and keep `O_NOFOLLOW` everywhere it exists today. This is narrower than changing document canonicalization, and it avoids relaxing the generic watcher initializer's documented final-symlink rejection.

**Important fixture detail:** `/tmp/<unique-directory>/document.md` does **not** reproduce this failure. `O_NOFOLLOW` rejects the final component of the path being opened; the final watch component in that fixture would be an ordinary directory. Use unique filenames directly under `/tmp` and `/private/tmp`. Never remove either system directory.

**Out of scope:** redesigning watcher recovery/status UI, changing debounce/retry/generation logic, changing duplicate-window identity or image roots, renderer changes, dependency upgrades, generalized protection against all ancestor-directory replacement races, installation, or full M5 acceptance.

## File map

| Path | Planned responsibility/change |
| --- | --- |
| `Sources/MDViewerCore/DocumentRefresh.swift:29-34` | Resolve the physical parent watch URL before opening the directory watcher; add one private helper. |
| `Tests/MDViewerCoreTests/DocumentRefreshTests.swift` | Add real-start/live-refresh cases for both temporary-directory spellings and an error-propagation case. |
| `Tests/MDViewerCoreTests/DirectoryWatcherTests.swift` | Explicitly retain final-directory-symlink rejection. |
| `Tests/M0Integration/WatcherProbe.swift` | Add isolated temporary-parent refresh, deletion/recreation, and close-cleanup coverage. |
| `Tests/M0Integration/Probe.swift:258-278` | Dispatch two new probe modes without invoking the normal WebKit scenario. |
| `scripts/test-watchers.py` | Run four independent, ten-second-bounded watcher scenarios. |
| `scripts/verify_m0.py:192` | Raise the outer watcher-runner timeout to accommodate four bounded children. |
| `TEST_RESULTS.md` | After execution only, record fresh red/green evidence and distinguish isolated checks from unperformed actual-app acceptance. |

**Keep unchanged:** `Sources/MDViewerCore/DirectoryWatcher.swift`, `Sources/MDViewerCore/DocumentLocation.swift`, `Sources/MDViewer/DocumentWindow.swift`, `Sources/MDViewerCore/AssetGateway.swift`, `docs/specs/2026-10-29-mdviewer-v1-design.md`, `docs/plans/2026-10-29-mdviewer-v1.md`, packaging/association declarations, and existing vendored renderer assets.

## Task 1: Add failing native regressions

**Files:** Modify `Tests/MDViewerCoreTests/DocumentRefreshTests.swift` and `Tests/MDViewerCoreTests/DirectoryWatcherTests.swift`.

- [x] **Step 1: Add the following test inside `DocumentRefreshTests`.** Reuse its existing `wait(_:)` helper and imports. Each parameter gets a distinct UUID filename, so parallel test execution does not share a document.

```swift
@Test(arguments: ["/tmp", "/private/tmp"])
@MainActor
func temporaryParentSupportsLiveRefresh(parent: String) async throws {
    let file = URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent("MDViewer-watch-\(UUID().uuidString) 雪 % '.md")
    try Data("initial".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    var generation = 0, displayed = "", warning = ""
    let refresh = DocumentRefresh(
        location: try DocumentLocation(file),
        invalidate: { generation += 1; return generation },
        render: { source, _ in displayed = source })
    defer { refresh.close() }
    refresh.onState = { state in
        if case .warning(let message) = state { warning = message }
        if case .displayed = state { warning = "" }
    }

    try refresh.start()
    try await wait { displayed == "initial" && warning.isEmpty }
    try Data("direct".utf8).write(to: file)
    try await wait { displayed == "direct" && warning.isEmpty }
    try Data("atomic".utf8).write(to: file, options: .atomic)
    try await wait { displayed == "atomic" && warning.isEmpty }

    try FileManager.default.removeItem(at: file)
    try await wait { !warning.isEmpty }
    #expect(displayed == "atomic")
    #expect(warning.hasPrefix("Preview is out of date"))

    try Data("recreated".utf8).write(to: file)
    try await wait { displayed == "recreated" && warning.isEmpty }
    #expect(refresh.hasGoodPreview)
}
```

- [x] **Step 2: Add a missing-parent error test in the same struct.** Do not create the UUID directory. This ensures the new resolver preserves a real POSIX error rather than falling back to an unresolvable watch URL.

```swift
@Test @MainActor
func missingWatchParentPreservesENOENT() throws {
    let missing = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("MDViewer-missing-\(UUID().uuidString)")
        .appendingPathComponent("document.md")
    var generation = 0
    let refresh = DocumentRefresh(
        location: try DocumentLocation(missing),
        invalidate: { generation += 1; return generation },
        render: { _, _ in })
    defer { refresh.close() }
    do {
        try refresh.start()
        Issue.record("Missing parent directory must fail watch startup")
    } catch let error as POSIXError {
        #expect(error.code == .ENOENT)
    }
}
```

- [x] **Step 3: Add final-directory-symlink rejection inside `DirectoryWatcherTests`.** Retain all existing regular-file, missing-target, and final-file-symlink tests.

```swift
@Test func rejectsFinalDirectorySymlink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MDViewer-watch-link-\(UUID().uuidString)")
    let target = root.appendingPathComponent("physical")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    do {
        let watcher = try DirectoryWatcher(directory: alias, onChange: {})
        watcher.stop()
        Issue.record("Generic watcher must not follow a final directory symlink")
    } catch let error as POSIXError {
        #expect(error.code == .ELOOP)
    }
}
```

- [x] **Step 4: Run the native suite before changing production code.** From the repository root:

```bash
bash scripts/test-swift.sh
```

Expected red evidence: `temporaryParentSupportsLiveRefresh` fails at `refresh.start()` with `.ELOOP` on this Mac. The missing-parent and symlink-rejection guards should pass. Record the actual failure; if the expected reproduction is absent, stop and inspect the fixture's parent using `lstat` instead of changing the fix speculatively. The existing wrapper loads the installed Swift Testing macro plugin; do not substitute a bare unsupported `swift test` invocation.

## Task 2: Resolve only the directory watch endpoint

**File:** Modify `Sources/MDViewerCore/DocumentRefresh.swift`.

- [x] **Step 1: Change only the parent-watcher construction in `start()`.** Preserve snapshotting, `rebindFile()`, and `reload()` order.

```swift
public func start() throws {
    guard !isClosed, directoryWatcher == nil else { return }
    let parent = try Self.physicalParentDirectoryURL(location.assetRoot)
    directoryWatcher = try DirectoryWatcher(directory: parent) { [weak self] in self?.changed() }
    snapshot = FileSnapshot(location.canonicalURL)
    rebindFile()
    reload()
}
```

- [x] **Step 2: Add this private helper inside `DocumentRefresh`.** `Darwin` and `Foundation` are already imported. Do not run `standardizedFileURL` or `resolvingSymlinksInPath()` on the resulting URL; that would risk recreating the `/tmp` spelling.

```swift
private static func physicalParentDirectoryURL(_ directory: URL) throws -> URL {
    guard let physicalPath = Darwin.realpath(directory.path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.free(physicalPath) }
    return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
}
```

The allocation is freed on every successful-resolution path. An error is captured immediately after a failed `realpath`. The existing watcher still performs `open`/`fstat`, so a final-component symlink introduced after resolution is rejected rather than deliberately followed. This is not a claim that `realpath` plus `open` eliminates every ancestor-directory race.

- [x] **Step 3: Rerun `bash scripts/test-swift.sh`.** All native tests must pass, including both temporary-parent cases, missing-parent `.ENOENT`, and both final-symlink guards. Verify that `rebindFile()` still opens `location.canonicalURL` directly with the unchanged strict watcher initializer.

## Task 3: Add bounded, process-isolated regressions

**Files:** Modify `Tests/M0Integration/WatcherProbe.swift`, `Tests/M0Integration/Probe.swift`, `scripts/test-watchers.py`, and `scripts/verify_m0.py`.

- [x] **Step 1: Add this method to the existing `M0Integration` extension in `Tests/M0Integration/WatcherProbe.swift`.** The extension inherits the main-actor isolation on `M0Integration`. Reuse `check` and `waitUntil`; do not create an actual app window.

```swift
static func testTemporaryParentRefresh(parentPath: String) async throws {
    let file = URL(fileURLWithPath: parentPath, isDirectory: true)
        .appendingPathComponent("MDViewer-watch-\(UUID().uuidString) 雪 % '.md")
    try Data("initial".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    print("FIXTURE temporary-parent: \(file.path)")
    fflush(stdout)

    var generation = 0, displayed = "", warning = ""
    let refresh = DocumentRefresh(
        location: try DocumentLocation(file),
        invalidate: { generation += 1; return generation },
        render: { source, _ in displayed = source })
    defer { refresh.close() }
    refresh.onState = { state in
        if case .warning(let message) = state { warning = message }
        if case .displayed = state { warning = "" }
    }

    let started = Date()
    try refresh.start()
    try check(Date().timeIntervalSince(started) < 0.5,
              "temporary-parent startup returns within 0.5 seconds")
    try await waitUntil("temporary-parent initial preview") {
        displayed == "initial" && warning.isEmpty
    }

    try Data("direct".utf8).write(to: file)
    try await waitUntil("temporary-parent direct write") {
        displayed == "direct" && warning.isEmpty
    }
    try check(refresh.hasGoodPreview, "direct-write refresh retains good-preview state")

    let atomicStarted = Date()
    try Data("atomic".utf8).write(to: file, options: .atomic)
    try await waitUntil("temporary-parent atomic replacement") {
        displayed == "atomic" && warning.isEmpty
    }
    let atomicElapsed = Date().timeIntervalSince(atomicStarted)
    print("TIMING temporary parent \(parentPath) atomic save: \(atomicElapsed) s")
    try check(atomicElapsed < 1.0, "atomic replacement refresh completes within 1 second")

    try FileManager.default.removeItem(at: file)
    try await waitUntil("temporary-parent missing warning") { !warning.isEmpty }
    try check(displayed == "atomic" && warning.hasPrefix("Preview is out of date"),
              "deletion preserves the last good preview with a warning")

    try Data("recreated".utf8).write(to: file)
    try await waitUntil("temporary-parent recreation") {
        displayed == "recreated" && warning.isEmpty
    }
    try check(refresh.hasGoodPreview, "recreation clears warning and resumes preview")

    let completed = refresh.completedGeneration
    refresh.close()
    try Data("after close".utf8).write(to: file)
    try await Task.sleep(nanoseconds: 350_000_000)
    try check(refresh.isClosed && displayed == "recreated" &&
              refresh.completedGeneration == completed,
              "closed session cannot publish another preview")
    print("TMP REFRESH REGRESSION PASSED: \(checks) checks")
}
```

The 350 ms observation window is specifically for the existing 200 ms debounce after closing; readiness otherwise uses condition-based waits. If a valid refresh misses the one-second target under contention, preserve the timing and investigate rather than silently increasing the acceptance threshold. The test writes only its own UUID fixture; the viewer remains a read-only consumer.

- [x] **Step 2: Add two branches between the existing `--fifo-replacement` branch and the `else { try await run() }` fallback in `Tests/M0Integration/Probe.swift`.** Keep the `count == 2` guards and all existing FIFO modes.

```swift
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--tmp-refresh" {
    try await testTemporaryParentRefresh(parentPath: "/tmp")
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--private-tmp-refresh" {
    try await testTemporaryParentRefresh(parentPath: "/private/tmp")
```

- [x] **Step 3: Update `scripts/test-watchers.py` to this complete content.** Each mode executes in a fresh process, so the existing global check counter starts at zero. Retain the dedicated-binary restriction and the existing ten-second subprocess timeout.

```python
#!/usr/bin/env python3
"""Bound watcher regressions in independent isolated-probe processes, never the app."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    raise SystemExit("Usage: test-watchers.py /absolute/path/to/M0Integration")
binary = Path(sys.argv[1]).resolve()
if binary.name != "M0Integration":
    raise SystemExit("Only the dedicated isolated probe may be executed")
scenarios = (
    ("--fifo-initial", "FIFO REGRESSION PASSED: 6 checks"),
    ("--fifo-replacement", "FIFO REGRESSION PASSED: 6 checks"),
    ("--tmp-refresh", "TMP REFRESH REGRESSION PASSED: 6 checks"),
    ("--private-tmp-refresh", "TMP REFRESH REGRESSION PASSED: 6 checks"),
)
for scenario, marker in scenarios:
    with tempfile.TemporaryDirectory(prefix="MDViewer-watcher-probe-") as temporary:
        env = dict(os.environ, TMPDIR=temporary)
        try:
            result = subprocess.run(
                [str(binary), scenario], env=env, cwd="/private/tmp", text=True,
                capture_output=True, timeout=10)
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            print(output, end="", flush=True)
            raise SystemExit(
                f"Watcher regression blocked beyond 10s; child killed/reaped: {scenario}"
            ) from error
        print(result.stdout, end="", flush=True)
        if result.returncode or marker not in result.stdout:
            raise SystemExit(f"Watcher regression failed: {scenario}\n{result.stderr}")
print("PASS 4 process-timeout-bounded watcher scenarios / 24 checks")
```

The two new modes deliberately ignore `TMPDIR` for fixture placement. The old FIFO modes retain their isolated temporary directories and existing six checks, including FIFO rejection and recovery. If a timeout kills a child before Swift cleanup runs, report any printed UUID fixture path and remove only that confirmed fixture after the child has been reaped; never bulk-delete `/tmp/MDViewer-*`.

- [x] **Step 4: Change the watcher-runner call in `scripts/verify_m0.py:192` from `timeout=30` to `timeout=50`.** Keep the existing `fifo-regression.txt` evidence filename to avoid unrelated report-path changes. Four children can each consume ten seconds; the outer timeout must not interrupt cleanup before the inner timeout can report the scenario.

- [x] **Step 5: Build and execute only the dedicated probe, from the repository root.**

```bash
swift build --build-system swiftbuild --product M0Integration
BIN_DIR="$(swift build --build-system swiftbuild --show-bin-path)"
python3 scripts/test-watchers.py "$BIN_DIR/M0Integration"
```

Expected: all four children exit zero; both FIFO sentinels still report six checks; both temporary-parent sentinels report six checks; the runner ends with `PASS 4 process-timeout-bounded watcher scenarios / 24 checks`. Nothing invokes the actual `MDViewer` binary or Launch Services.

## Task 4: Run full local verification and record the boundary

**Files:** Update `TEST_RESULTS.md` after fresh verification; build evidence belongs under the existing `.build` evidence directories.

- [x] **Step 1: Run native and renderer checks.**

```bash
bash scripts/test-swift.sh
node scripts/test-renderer-assets.mjs
node scripts/test-reference-performance.mjs
python3 scripts/test-release-verification.py
```

Expected: zero exit status for every command; no renderer/vendor changes; existing source, symlink-escape, FIFO, cancellation, and generation protections remain passing. Do not infer success from historical test totals.

- [x] **Step 2: Run the isolated debug and release verification entry points.**

```bash
bash scripts/test-webkit.sh
CONFIGURATION=release bash scripts/test-webkit.sh
```

These entry points build/sign local artifacts, inspect packaging, and directly execute a dedicated probe whose metadata has no document-type/UTI declarations. They do not install or launch the actual app, invoke `open`/`lsregister`, or set associations. Keep `MDVIEWER_M0_ALLOW_LAUNCH_SERVICES` unset and do not run the full Launch Services branch of `scripts/verify_m0.py`.

Expected: both suites pass including four bounded watcher scenarios, existing real-WebKit assertions, runner guards, and unchanged original-fixture hashes. Inspect `.build/m0-evidence/fifo-regression.txt` and `.build/release-evidence/fifo-regression.txt` for new scenario/timing evidence. A native test run in the current verifier remains the wrapper's default configuration; the release claim specifically applies to the release-built integration probe and package, not an independently release-configured Swift Testing suite.

- [x] **Step 3: Check the change boundary before reporting completion.** Confirm `O_EVTONLY | O_NONBLOCK | O_NOFOLLOW` and descriptor-type checks are unchanged in `Sources/MDViewerCore/DirectoryWatcher.swift`; source reading still uses `O_RDONLY | O_NONBLOCK | O_NOFOLLOW` in `Sources/MDViewerCore/DocumentLocation.swift`; file rebinding, canonical identity, and asset containment are unchanged. Stop and ask the user if completing this fix appears to require broader changes.

- [x] **Step 4: Append a dated blocker-resolution entry to `TEST_RESULTS.md`.** Record the pre-fix `.ELOOP` reproduction, actual native and isolated-probe results, observed atomic-refresh timings, and exact debug/release evidence paths. State that actual-app launch, Finder/pi-files/default-handler acceptance, VoiceOver/manual checks, network packet observation, and installation were not performed by this fix. Do not label all of M5 or all acceptance criteria complete.

## Acceptance and self-review checklist

- [x] Native regressions demonstrably fail before the production change and pass afterward.
- [x] Documents directly under `/tmp` and `/private/tmp` start successfully and refresh after direct writes and atomic replacement without a manual reload.
- [x] Delete/recreate preserves the last good preview, reports a warning, then clears it on recovery.
- [x] Closing a session prevents later preview publication.
- [x] Missing parent preserves `.ENOENT`; final file and directory symlinks remain rejected by the generic watcher.
- [x] Both initial-FIFO and replacement-FIFO children remain nonblocking and recover after valid recreation.
- [x] Debug and release isolated verification pass with recorded timings and unchanged original fixture hashes.
- [x] No changes to canonical document identity, image-root policy, no-follow/nonblocking flags, source limits, dependencies, defaults, Git state, or installed applications.

**Contract mapping:** This addresses the `/tmp` blocker in `docs/plans/2026-10-29-mdviewer-v1.md` M3 and the tested refresh/deletion portions of `docs/specs/2026-10-29-mdviewer-v1-design.md` A06/A07. Literal filename coverage contributes to A08. Keeping canonical identity and asset policy unchanged protects A03/A09; it does not replace their wider existing tests. The remainder of A06/A07 and manual product acceptance continue to rely on their existing dedicated evidence and outstanding acceptance work.

**Handoff:** After user approval, execute Tasks 1–4 in order with one writer. Capture the red test before applying Task 2; retain all timeout guards; stop on a new blocker rather than broadening the patch. No implementation or verification commands were executed as part of creating this plan.
