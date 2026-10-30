#!/usr/bin/env python3
"""Exercise release resource checks and install guards without installing or launching."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / "scripts/verify_assets.py"
RELEASE = ROOT / ".build/release-package/MDViewer.app"


def run(arguments, *, env=None, passed=True):
    result = subprocess.run(arguments, cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)
    assert (result.returncode == 0) == passed, result.stdout + result.stderr
    return result


def verify(bundle, *, passed=True):
    return run(["python3", str(VERIFY), "--bundle", str(bundle)], passed=passed)


verify(RELEASE)
run(["codesign", "--verify", "--strict", str(RELEASE)])
with tempfile.TemporaryDirectory(prefix="packaging-validation-", dir=ROOT / ".build") as temporary:
    scratch = Path(temporary)
    # Resources only: deliberately no executable or Info.plist/document declarations.
    package = scratch / "resource-check"
    shutil.copytree(RELEASE / "Contents/Resources", package / "Contents/Resources")
    verify(package)
    renderer = package / "Contents/Resources/Web/renderer.js"
    original = renderer.read_bytes()
    renderer.write_bytes(original + b"\n/* changed */")
    assert "Packaged asset mismatch" in verify(package, passed=False).stderr
    renderer.write_bytes(original)
    extra = package / "Contents/Resources/Web/unlisted.js"
    extra.write_text("unlisted")
    assert "Unlisted packaged resources" in verify(package, passed=False).stderr
    extra.unlink()
    notices = package / "Contents/Resources/Notices/THIRD_PARTY_NOTICES.md"
    notices.unlink()
    verify(package, passed=False)
    env = dict(os.environ, HOME=str(scratch / "never-created-home"))
    for arguments in ([], ["--replace"], ["--unknown"], ["--dry-run", "--dry-run"]):
        run(["bash", "scripts/install.sh", *arguments], env=env, passed=False)
    dry_run = run(["bash", "scripts/install.sh", "--dry-run"], env=env)
    assert "DRY RUN ONLY" in dry_run.stdout
    assert not (Path(env["HOME"]) / "Applications").exists(), "Dry-run/guards must not create the installation directory"
    if Path(env["HOME"]).exists():
        print("OBSERVED non-installation HOME entries:", sorted(str(path.relative_to(env["HOME"])) for path in Path(env["HOME"]).rglob("*")))
for path in ROOT.joinpath("scripts").glob("*.sh"):
    run(["bash", "-n", str(path)])
assert not ROOT.joinpath(".git").exists(), "No Git initialization/staging authorized"
print("PASS release signature/resources, 3 tamper rejections, 4 install guards, dry-run without Applications creation, shell syntax; no staged files")
