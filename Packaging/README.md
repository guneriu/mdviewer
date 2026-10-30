# Packaging MDViewer

Packaging builds a local macOS app bundle. It is not publication, installation,
Launch Services acceptance, or a notarized distribution process. See the
[main README](../README.md) for deliberate launch, default-handler selection,
updates and removal.

## Inputs and responsibilities

| Path | Responsibility |
| --- | --- |
| `Package.swift` | SwiftPM products, native targets and macOS deployment target. A Swift executable alone is not a Finder app. |
| `Sources/` | AppKit application and core WebKit/document implementation. |
| `package.json`, `package-lock.json` | Private, pinned development tooling for regenerating renderer assets; not a runtime Node app or public npm package. |
| `web/` | Authored renderer inputs. |
| `Resources/Web/`, `Resources/Notices/` | Vendored runtime assets and full upstream license texts. |
| `vendor-manifest.json`, `THIRD_PARTY_NOTICES.md` | Asset/source/version/integrity/license inventory and bundled notices. |
| `Packaging/Info.plist` | Actual app metadata input: identity `de.local.mdviewer`, Viewer document role, Markdown UTI declarations and Alternate handler rank. |
| `Packaging/Integration-Info.plist` | Dedicated integration-probe metadata; intentionally has no document types or imported UTI declarations. |
| `.build/` | Generated binaries, app bundles, test fixtures and local evidence; not authored packaging inputs. |

Paths in this table are relative to the project root. Keep the existing layout;
do not edit generated app resources to make a source validation pass.

## Build outputs

Run from the project root:

```sh
bash scripts/package.sh
# .build/MDViewer.app (debug)

CONFIGURATION=release bash scripts/package.sh
# .build/release-package/MDViewer.app (release)
```

Only `debug` and `release` configurations are accepted. The script:

1. Verifies source asset hashes, sizes, allowlists, manifest and notices with
   Python's standard library.
2. Builds `MDViewer` with `swift build --build-system swiftbuild`, using the chosen
   configuration and host architecture.
3. Copies the executable and metadata to the output bundle, adds the build
   configuration to its plist, replaces Web/Notices resources, and copies the
   vendor manifest.
4. Rechecks packaged resources, lints the plist, ad-hoc signs with `codesign`, and
   verifies the signature strictly.

**Generated outputs are overwritten.** `package.sh` does not guard against a
running app. Quit MDViewer before rebuilding a bundle in use, and reopen the
intended bundle afterward: the on-disk executable and a live image can differ.
Debug and release app locations are separate. A failed packaging step is not a
verified release; inspect its error rather than installing partial output.

No npm, network download, app launch, installation, explicit handler registration,
default preference change, quarantine removal or Gatekeeper weakening is part of
`package.sh`. It uses system AppKit/WebKit at runtime. The app deployment target
is macOS 13, not a tested older-OS guarantee; test-library coverage requires
macOS 14. Ad-hoc signing is not Developer ID signing or notarization, and the script
does not produce a universal binary.

## Inspection without building or launching

These commands inspect existing inputs or a previously built release. The bundle
commands require that release to exist; they do not create it.

```sh
for script in scripts/*.sh; do bash -n "$script" || exit; done
plutil -lint Packaging/Info.plist
PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_assets.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_assets.py --bundle .build/release-package/MDViewer.app
codesign --verify --strict --verbose=2 .build/release-package/MDViewer.app
bash scripts/install.sh --dry-run
```

The asset verifier checks byte-level resources, not full UI behavior. A valid
signature and a dry-run do not prove install/update correctness or acceptance.
See [historical verification evidence](../TEST_RESULTS.md) for what was actually
run and which checks remain pending.

## Installation is separate and explicit

`install.sh --dry-run` verifies the existing release's resources, signature,
identity and release configuration, then prints the intended copy. It creates no
installation. With no arguments the script refuses to proceed.

Only a deliberate `bash scripts/install.sh --install` copies the release to
`~/Applications/MDViewer.app`. The installer rejects symlink installation paths,
refuses a running MDViewer, and requires `--replace` for an existing destination.
It stages and verifies the copy, attempts rollback if the final move fails, and
retains the old app for recovery if rollback fails. The mutating branch has not
completed manual acceptance; dry-run and argument-guard tests are narrower evidence.

Installation does not launch the app or explicitly register/set a default. However,
**copying or launching a document-type app can influence macOS discovery/default
resolution** without those calls. Alternate handler rank does not prevent that.
Choose installation and launch separately from a build; choose Finder's **Change
All** separately from both. The [README](../README.md#deliberate-launch-and-optional-setup)
documents those actions and restoring a preferred handler.

## Test bundles and license boundaries

The WebKit wrapper also packages a dedicated `M0Integration.app` in `.build/`
(debug) or `.build/release-package/` (release). It executes the isolated probe,
not the actual document app. Those tests rebuild/sign outputs and require a
logged-in graphical session; they are not read-only inspection commands. See the
[development guide](../docs/README.md#development-checks) before running them.

MDViewer's own code is under [MIT](../LICENSE). Bundled dependencies retain the
terms in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and
[Resources/Notices/](../Resources/Notices/). Do not alter upstream license text or
hashes merely to align them with the project license.
