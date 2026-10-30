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
    ("--asset-image-events", "ASSET IMAGE EVENTS PASSED: 10 checks"),
    ("--asset-image-directory", "ASSET IMAGE DIRECTORY PASSED: 2 checks"),
    ("--asset-image-filtering", "ASSET IMAGE FILTERING PASSED: 6 checks"),
    ("--asset-tmp-parent", "ASSET TMP PARENT PASSED: 3 checks"),
)
for scenario, marker in scenarios:
    with tempfile.TemporaryDirectory(prefix="MDViewer-watcher-probe-") as temporary:
        env = dict(os.environ, TMPDIR=temporary)
        env.pop("MDVIEWER_M0_ALLOW_LAUNCH_SERVICES", None)
        try:
            result = subprocess.run(
                [str(binary), scenario], env=env, cwd="/private/tmp", text=True,
                capture_output=True, timeout=10)
        except subprocess.TimeoutExpired as error:
            for stream, sink in ((error.stdout, sys.stdout), (error.stderr, sys.stderr)):
                text = stream or b""
                if isinstance(text, bytes):
                    text = text.decode("utf-8", errors="replace")
                print(text, end="", file=sink, flush=True)
            raise SystemExit(
                f"Watcher regression blocked beyond 10s; child killed/reaped: {scenario}"
            ) from error
        print(result.stdout, end="", flush=True)
        if result.returncode or marker not in result.stdout:
            raise SystemExit(f"Watcher regression failed: {scenario}\n{result.stderr}")
print("PASS 8 process-timeout-bounded watcher scenarios / 45 checks")
