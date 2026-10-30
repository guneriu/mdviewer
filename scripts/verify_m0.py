#!/usr/bin/env python3
"""Local verification. Actual-app launches require approval; no installation/default setters."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build"
CONFIG = os.environ.get("CONFIGURATION", "debug")
if CONFIG not in ("debug", "release"):
    raise SystemExit("Invalid CONFIGURATION")
EVIDENCE = BUILD / ("release-evidence" if CONFIG == "release" else "m0-evidence")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_probe_metadata(metadata):
    require("CFBundleDocumentTypes" not in metadata, "Isolated probe must not declare document types")
    require("UTImportedTypeDeclarations" not in metadata, "Isolated probe must not declare imported UTIs")


def verify_source_integrity(fixtures, snapshot, original_hashes):
    require(hashes(fixtures) == snapshot, "Opened document or adjacent asset modified")
    require(hashes(ROOT / "Fixtures") == original_hashes, "Source fixture modified")


def run(args, name, cwd=ROOT, timeout=120):
    print("RUN", " ".join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    (EVIDENCE / name).write_text(result.stdout)
    if result.returncode:
        print(result.stdout)
        raise RuntimeError(f"Command failed ({result.returncode}): {args}; see {EVIDENCE / name}")
    return result.stdout


def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob("*") if p.is_file()}


def prepare_fixtures():
    fixtures = BUILD / "m0-fixtures"
    if fixtures.exists():
        shutil.rmtree(fixtures)
    shutil.copytree(ROOT / "Fixtures", fixtures)
    png = base64.b64decode((fixtures / "Images/pixel.png.base64").read_text())
    (fixtures / "Images/pixel.png").write_bytes(png)
    outside = BUILD / "outside.png"
    outside.write_bytes(png)
    (fixtures / "Images/escape.png").symlink_to(outside)
    (fixtures / "Images/hostile.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
    (fixtures / "canonical alias.md").symlink_to(fixtures / "safe.md")
    (fixtures / "literal '% $(false).md").write_text("# Literal filename fixture\n")
    return fixtures


def inspect_bundle(app, label):
    run(["codesign", "--verify", "--strict", "--verbose=2", app], f"{label}-signature.txt")
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", str(app)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    (EVIDENCE / f"{label}-entitlements.txt").write_bytes(result.stdout + result.stderr)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    require("com.apple.security.app-sandbox" not in entitlements, f"Unexpected App Sandbox entitlement: {entitlements}")
    print(f"PASS {label}: actual entitlements {entitlements}; App Sandbox absent", flush=True)
    run(["codesign", "-dvvv", app], f"{label}-signing-details.txt")
    executable = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    dependencies = run(["otool", "-L", app / "Contents/MacOS" / executable], f"{label}-libraries.txt")
    require(all(".build" not in line for line in dependencies.splitlines()[1:]), "Binary links build-directory dependencies")
    run(["otool", "-l", app / "Contents/MacOS" / executable], f"{label}-load-commands.txt")


def event_rows(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.startswith("{")]


def await_events(path, condition):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        rows = event_rows(path)
        if condition(rows):
            return rows
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for Launch Services events: {event_rows(path)}")


def test_open_events(app, fixtures):
    # Never terminate an unrelated or already-running app to make the cold test pass.
    existing = subprocess.run(["pgrep", "-x", "MDViewer"], capture_output=True, text=True)
    if existing.returncode == 0:
        raise RuntimeError("Close existing MDViewer before running the cold-launch test")
    events = EVIDENCE / "open-events.jsonl"
    errors = EVIDENCE / "open-stderr.txt"
    events.unlink(missing_ok=True)
    errors.unlink(missing_ok=True)
    pid = None
    try:
        run(["/usr/bin/open", "-a", app, "--stdout", events, "--stderr", errors,
             "--env", "MDVIEWER_M0_EVENTS=1", fixtures / "safe.md"], "open-cold-command.txt", cwd=Path("/private/tmp"))
        rows = await_events(events, lambda rows: any(r["event"] == "rendered" for r in rows))
        pid = rows[0]["pid"]
        require([r["windows"] for r in rows if r["event"] == "created"] == [1], "Cold launch must create one window")
        # After the first explicit bundle-path launch, also verify name-based -a resolution.
        run(["/usr/bin/open", "-a", "MDViewer", fixtures / "space ü 日本.markdown"], "open-warm-command.txt", cwd=Path("/private/tmp"))
        await_events(events, lambda rows: sum(r["event"] == "rendered" for r in rows) >= 2)
        run(["/usr/bin/open", "-a", app, fixtures / "hostile.md", fixtures / "literal '% $(false).md"], "open-multiple-command.txt", cwd=Path("/private/tmp"))
        await_events(events, lambda rows: sum(r["event"] == "rendered" for r in rows) >= 4)
        run(["/usr/bin/open", "-a", app, fixtures / "canonical alias.md"], "open-alias-command.txt", cwd=Path("/private/tmp"))
        rows = await_events(events, lambda rows: any(r["event"] == "focus" for r in rows))
        require({r["pid"] for r in rows} == {pid}, "Open events came from multiple processes")
        require([r["windows"] for r in rows if r["event"] == "created"] == [1, 2, 3, 4], "Unexpected canonical window count")
        require(any(r["event"] == "open-event" and r["count"] == 2 for r in rows), "Missing multiple-file open event")
        require(any(r["event"] == "focus" and r["windows"] == 4 and
                    r["canonical"] == str((fixtures / "safe.md").resolve()) for r in rows), "Canonical alias did not focus existing window")
        require(not any(r["event"] == "error" for r in rows), "Open events reported an error")
        print(f"PASS cold/warm/multiple/Unicode/literal/symlink opens; one PID, four canonical windows ({pid})", flush=True)
    finally:
        if pid is None:
            launches = [r for r in event_rows(events) if r["event"] == "launch"]
            pid = launches[0]["pid"] if launches else None
        if pid is not None:
            # This PID came only from this test's launch output.
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)


def main():
    webkit_only = sys.argv[1:] == ["--webkit-only"]
    if sys.argv[1:] not in ([], ["--webkit-only"]):
        raise SystemExit("Usage: verify_m0.py [--webkit-only]")
    if not webkit_only and os.environ.get("MDVIEWER_M0_ALLOW_LAUNCH_SERVICES") != "1":
        raise SystemExit("STOP: macOS open -a can register this app and change the effective handler "
                         "when no explicit default is pinned. See TEST_RESULTS.md. Obtain approval "
                         "before rerunning with MDVIEWER_M0_ALLOW_LAUNCH_SERVICES=1; "
                         "no build/launch/association operations were performed.")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if not webkit_only:
        before_handlers = json.loads(run(["swift", ROOT / "scripts/inspect-handlers.swift"], "handlers-before.json"))
    original_hashes = hashes(ROOT / "Fixtures")
    run(["sw_vers"], "os.txt")
    run(["swift", "--version"], "swift.txt")
    run(["xcode-select", "-p"], "developer-directory.txt")
    run(["xcrun", "--show-sdk-version"], "sdk.txt")
    run(["bash", ROOT / "scripts/test-swift.sh"], "swift-tests.txt")
    run(["bash", ROOT / "scripts/package.sh"], "package.txt")
    app = BUILD / "release-package/MDViewer.app" if CONFIG == "release" else BUILD / "MDViewer.app"
    inspect_bundle(app, "app")
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(metadata["CFBundleIdentifier"] == "de.local.mdviewer", "Unexpected app bundle identifier")
    require(metadata["MDViewerBuildConfiguration"] == CONFIG, "Unexpected app build configuration")
    declaration = metadata["CFBundleDocumentTypes"][0]
    require(declaration["CFBundleTypeRole"] == "Viewer" and declaration["LSHandlerRank"] == "Alternate", "Unexpected app handler role/rank")
    require(set(declaration["CFBundleTypeExtensions"]) == {"md", "markdown"}, "Unexpected app document extensions")
    fixtures = prepare_fixtures()
    snapshot = hashes(fixtures)
    run(["swift", "build", "--build-system", "swiftbuild", "-c", CONFIG, "--product", "M0Integration"], "integration-build.txt")
    binary_directory = Path(subprocess.check_output(["swift", "build", "--build-system", "swiftbuild", "-c", CONFIG, "--show-bin-path"], cwd=ROOT, text=True).strip())
    probe = BUILD / ("release-package/M0Integration.app" if CONFIG == "release" else "M0Integration.app")
    if probe.exists():
        shutil.rmtree(probe)
    (probe / "Contents/MacOS").mkdir(parents=True)
    shutil.copytree(ROOT / "Resources/Web", probe / "Contents/Resources/Web")
    shutil.copy2(binary_directory / "M0Integration", probe / "Contents/MacOS/M0Integration")
    probe_metadata = plistlib.loads((ROOT / "Packaging/Integration-Info.plist").read_bytes())
    verify_probe_metadata(probe_metadata)
    (probe / "Contents/Info.plist").write_bytes(plistlib.dumps(probe_metadata))
    run(["codesign", "--force", "--sign", "-", probe], "integration-sign.txt")
    inspect_bundle(probe, "integration")
    run([sys.executable, ROOT / "scripts/test-watchers.py", probe / "Contents/MacOS/M0Integration"], "fifo-regression.txt", timeout=50)
    output = run([probe / "Contents/MacOS/M0Integration", fixtures], "webkit-integration.txt", cwd=Path("/private/tmp"), timeout=60)
    print(output, flush=True)
    if not webkit_only:
        test_open_events(app, fixtures)
        after_handlers = json.loads(run(["swift", ROOT / "scripts/inspect-handlers.swift"], "handlers-after.json"))
        for extension in ("md", "markdown"):
            require("de.local.mdviewer" in after_handlers[extension]["handlers"], f"Missing .{extension} handler registration")
            if before_handlers[extension]["default"] != after_handlers[extension]["default"]:
                raise RuntimeError(f"Effective .{extension} handler changed: "
                                   f"{before_handlers[extension]['default']} → {after_handlers[extension]['default']}; "
                                   "no restoration attempted; seek user direction")
    verify_source_integrity(fixtures, snapshot, original_hashes)
    (EVIDENCE / "source-hashes.json").write_text(json.dumps({"original": original_hashes, "opened": snapshot}, indent=2, sort_keys=True))
    scope = "NON-LAUNCH-SERVICES" if webkit_only else "AUTOMATED"
    print(f"M0 {scope} CHECKS PASSED; see TEST_RESULTS.md for Launch Services, packet-observation and manual-check limitations.", flush=True)


if __name__ == "__main__":
    main()
