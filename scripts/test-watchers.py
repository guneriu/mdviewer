#!/usr/bin/env python3
"""Bound FIFO regressions in independent isolated-probe processes (never the actual app)."""
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
for scenario in ("--fifo-initial", "--fifo-replacement"):
    with tempfile.TemporaryDirectory(prefix="MDViewer-FIFO-probe-") as temporary:
        env = dict(os.environ, TMPDIR=temporary)
        try:
            result = subprocess.run([str(binary), scenario], env=env, cwd="/private/tmp", text=True,
                                    capture_output=True, timeout=10)
        except subprocess.TimeoutExpired as error:
            raise SystemExit(f"FIFO regression blocked beyond 10s; child killed/reaped: {scenario}") from error
        print(result.stdout, end="", flush=True)
        if result.returncode or "FIFO REGRESSION PASSED: 6 checks" not in result.stdout:
            raise SystemExit(f"FIFO regression failed: {scenario}\n{result.stderr}")
print("PASS 2 process-timeout-bounded FIFO scenarios / 12 checks")
