#!/usr/bin/env python3
"""Negative controls for release checks, including optimized Python interpreters."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / "scripts/verify_assets.py"
MODES = (("default", [], {}), ("-O", ["-O"], {}), ("PYTHONOPTIMIZE=1", [], {"PYTHONOPTIMIZE": "1"}))
failures = []
checks = 0


def check(root, bundle, name, expected_error=None):
    global checks
    for mode, flags, settings in MODES:
        env = dict(os.environ)
        env.pop("PYTHONOPTIMIZE", None)
        env.update(settings)
        result = subprocess.run([sys.executable, *flags, str(VERIFY), str(root), "--bundle", str(bundle)],
                                env=env, text=True, capture_output=True, timeout=10)
        correct = result.returncode == 0 if expected_error is None else result.returncode != 0 and expected_error in result.stderr
        checks += 1
        print(f"{'PASS' if correct else 'FAIL'} {mode}: {name}", flush=True)
        if not correct:
            failures.append(f"{mode}/{name}: rc={result.returncode} {result.stdout} {result.stderr}")


with tempfile.TemporaryDirectory(prefix="release-negative-", dir=ROOT / ".build") as temporary:
    scratch = Path(temporary)
    source = scratch / "source"
    source.mkdir()
    shutil.copytree(ROOT / "Resources", source / "Resources")
    for name in ("vendor-manifest.json", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / name, source / name)
    # Resource-only data: no executable, Info.plist or document type declaration.
    bundle = scratch / "resource-check"
    packaged = bundle / "Contents/Resources"
    shutil.copytree(source / "Resources", packaged)
    shutil.copy2(source / "vendor-manifest.json", packaged / "vendor-manifest.json")
    check(source, bundle, "pristine resources")
    renderer = source / "Resources/Web/renderer.js"
    original = renderer.read_bytes()
    renderer.write_bytes(b"!" + original[1:])
    check(source, bundle, "source checksum tamper", "Checksum mismatch")
    renderer.write_bytes(original + b"!")
    check(source, bundle, "source size tamper", "Size mismatch")
    renderer.write_bytes(original)
    extra = source / "Resources/Web/unlisted.js"
    extra.write_text("unlisted")
    check(source, bundle, "unlisted source resource", "Unlisted resource files")
    extra.unlink()
    manifest_path = source / "vendor-manifest.json"
    original_manifest = manifest_path.read_bytes()
    manifest = json.loads(original_manifest)
    manifest["assets"].append(manifest["assets"][0])
    manifest_path.write_text(json.dumps(manifest))
    check(source, bundle, "duplicate manifest entry", "Duplicate asset inventory")
    manifest["assets"] = manifest["assets"][1:]
    manifest["assets"][0]["path"] = "Resources/Web/unlisted.js"
    manifest_path.write_text(json.dumps(manifest))
    check(source, bundle, "unexpected manifest inventory", "Unexpected asset inventory")
    manifest_path.write_bytes(original_manifest)
    notice = source / "THIRD_PARTY_NOTICES.md"
    original_notice = notice.read_bytes()
    notice.write_bytes(original_notice + b"!")
    check(source, bundle, "source notice mismatch", "Notice mismatch")
    notice.write_bytes(original_notice)
    renderer = packaged / "Web/renderer.js"
    renderer.write_bytes(original + b"!")
    check(source, bundle, "packaged renderer tamper", "Packaged asset mismatch")
    renderer.write_bytes(original)
    extra = packaged / "unlisted.js"
    extra.write_text("unlisted")
    check(source, bundle, "unlisted packaged resource", "Unlisted packaged resources")
    extra.unlink()
    (packaged / "vendor-manifest.json").write_bytes(original_manifest + b" ")
    check(source, bundle, "packaged manifest mismatch", "Packaged manifest mismatch")

asset_checks = checks
with tempfile.TemporaryDirectory(prefix="probe-verification-", dir=ROOT / ".build") as temporary:
    scratch = Path(temporary)
    fixtures = scratch / "Fixtures"
    fixtures.mkdir()
    opened = scratch / "opened"
    opened.mkdir()
    (fixtures / "source.md").write_text("source")
    (opened / "document.md").write_text("opened")
    setup = (
        "import ast, pathlib, runpy; "
        f"p=pathlib.Path({str(ROOT / 'scripts/verify_m0.py')!r}); "
        "ns=runpy.run_path(str(p)); "
        f"ns['verify_source_integrity'].__globals__['ROOT']=pathlib.Path({str(scratch)!r}); "
        f"fixtures=pathlib.Path({str(opened)!r}); source=pathlib.Path({str(fixtures)!r}); "
        "snapshot=ns['hashes'](fixtures); original=ns['hashes'](source); "
    )
    cases = (
        ("explicit guard", "ns['require'](False, 'negative guard')", "negative guard"),
        ("probe document types", "ns['verify_probe_metadata']({'CFBundleDocumentTypes':[]})", "must not declare document types"),
        ("probe imported UTIs", "ns['verify_probe_metadata']({'UTImportedTypeDeclarations':[]})", "must not declare imported UTIs"),
        ("opened fixture integrity", "ns['verify_source_integrity'](fixtures, {}, original)", "Opened document or adjacent asset modified"),
        ("source fixture integrity", "ns['verify_source_integrity'](fixtures, snapshot, {})", "Source fixture modified"),
        ("release gates contain no assert", "\nfor filename in ('verify_m0.py','verify_assets.py'):\n tree=ast.parse((p.parent/filename).read_text())\n if any(isinstance(n,ast.Assert) for n in ast.walk(tree)): raise SystemExit('assert release gate')", None),
    )
    for mode, flags, settings in MODES:
        env = dict(os.environ)
        env.pop("PYTHONOPTIMIZE", None)
        env.pop("MDVIEWER_M0_ALLOW_LAUNCH_SERVICES", None)
        env.update(settings)
        for name, code, error in cases:
            result = subprocess.run([sys.executable, *flags, "-c", setup + code], env=env,
                                    text=True, capture_output=True, timeout=10)
            correct = result.returncode == 0 if error is None else result.returncode != 0 and error in result.stderr
            checks += 1
            print(f"{'PASS' if correct else 'FAIL'} {mode}: {name}")
            if not correct:
                failures.append(f"{mode}/{name}: {result.stdout} {result.stderr}")
        result = subprocess.run([sys.executable, *flags, str(ROOT / 'scripts/verify_m0.py')], env=env,
                                text=True, capture_output=True, timeout=10)
        correct = result.returncode != 0 and "no build/launch/association operations were performed" in result.stderr
        checks += 1
        print(f"{'PASS' if correct else 'FAIL'} {mode}: actual-app approval guard")
        if not correct:
            failures.append(f"{mode}/approval guard: {result.stdout} {result.stderr}")
if failures:
    raise SystemExit("Release verification regressions:\n" + "\n".join(failures))
print(f"PASS optimized release verification: {asset_checks} asset + {checks-asset_checks} probe/integrity/safety controls across 3 Python modes")
