# `mdv` command-line launcher — design

Status: **dropped** (2026-10-30), not implemented. With MDViewer set as the default
Markdown app, `open file.md` already opens it. To view in MDViewer while another app
stays the default, use the shell alias in the README (`alias mdv='open -b de.local.mdviewer'`).
The extra installer surface (packaged launcher, `--cli`/`--replace-cli`, `~/.local/bin`
symlink handling) was not worth its risk. Kept as a record of the proposal.

Original status: proposed (2026-10-30). Feature 8 of the post-v1 round. The v1 specification
(`2026-10-29-mdviewer-v1-design.md:41-49`) deferred a CLI wrapper. This document is
the follow-up decision. pi-files stays unchanged.

## Goals

1. `mdv FILE…` opens one or more Markdown files in MDViewer from a terminal. Relative
   paths work. The existing one-window-per-canonical-file rule applies
   (`AppDelegate.application(_:open:)` already handles several URLs).
2. Installed by an explicit, guarded option, `scripts/install.sh --cli`, as a symlink at
   `~/.local/bin/mdv`. Removed by `scripts/install.sh --uninstall-cli`.
3. Plain POSIX shell (`/bin/sh`), auditable, no compiled code, no network.

## Non-goals

Reading stdin, `--wait` until close, setting default handlers, finding files (globbing
is left to the shell), and supporting other viewers.

## Behavior

```
mdv [-a APP_PATH] [--] FILE...
mdv -h | --help
mdv --version
```

- With no files: prints usage to stderr, exit 64 (`EX_USAGE`).
- Each FILE must exist and be a regular file or a symlink to one, with extension `.md`
  or `.markdown` (case-insensitive). Anything else: message on stderr, exit 66
  (`EX_NOINPUT`). The script opens nothing unless every argument is valid.
- Paths become absolute (`cd "$(dirname -- "$f")" && pwd -P` plus the basename) before
  being passed on. Re-check `[ -f "$absolute" ]` after construction and reject with
  exit 66 if it no longer resolves to a regular file: command substitution around
  `dirname`/`pwd` strips trailing newlines. The app still canonicalizes and validates;
  the script is not a security boundary.
- Opening:
  - default: `open -b de.local.mdviewer -- "$abs"...`
  - `-a APP_PATH` or `MDV_APP` env: `open -a "$APP_PATH" -- …`, to pick a specific
    build when several copies exist (README already warns about multiple copies).
  - The script never passes `-n`, `-g`, `--args`, or `--env`. `--` always precedes
    the file list, so file names starting with `-` are safe.
- Exit status follows `open`. If the bundle ID cannot be resolved, it prints a hint:
  install the app or use `-a`.
- `--version` prints the `CFBundleShortVersionString` of the resolved app if found
  (`mdfind`-free: reads the plist of `-a`/`MDV_APP`, else
  `~/Applications/MDViewer.app`), else `unknown`.

## Packaging and installation

- Source: `scripts/mdv` (executable, `#!/bin/sh`, `set -eu`).
- Packaged into the bundle at `MDViewer.app/Contents/Resources/bin/mdv`. It updates and
  is removed together with the installed app, and does not depend on where the repo is
  checked out. `verify_assets.py` packaged allowlist gains exactly this file with its
  hash and executable mode. Ad-hoc signing seals it as a resource.
- `scripts/install.sh` gains two modes, mutually exclusive with `--dry-run`/`--install`
  except as listed:
  - `--cli`: requires the installed app at `~/Applications/MDViewer.app` (or combines
    with `--install` to install first). Creates `~/.local/bin` if missing and symlinks
    `~/.local/bin/mdv → ~/Applications/MDViewer.app/Contents/Resources/bin/mdv`.
    - Requires `codesign --verify --strict` of the installed app, plist
      `CFBundleIdentifier=de.local.mdviewer`, and a present, executable, nonsymlink
      packaged launcher. Do not compare installed renderer resources with the current
      repository: a renderer rebuild must not prevent linking an older valid installation.
    - Refuses if `~/.local/bin/mdv` already exists and is not a symlink to that exact
      target, unless the separate `--replace-cli` flag is given. This includes the
      unrelated pip `mdv` terminal viewer, which may install at the same path.
      `--replace` remains **app-only** and never authorizes replacing a foreign CLI.
      `--replace-cli` requires `--cli`; combined installs need both flags when replacing
      both a foreign app and a foreign CLI. Directories at the CLI path always refuse.
    - Refuses if either `~/.local` or `~/.local/bin` is itself a symlink, including
      for removal. Same guard style as the Applications symlink refusal.
    - Warns, without failing, if `~/.local/bin` is not on `PATH`.
  - `--uninstall-cli`: removes `~/.local/bin/mdv` only if it is a symlink pointing into
    an `MDViewer.app`. Otherwise it refuses.
  - `--dry-run --cli` prints the intended actions and creates nothing.
- Uninstalling the app (README) gains the step "run `scripts/install.sh --uninstall-cli`
  first". A dangling link is harmless but confusing.

## Tests

- `scripts/test-mdv.py` (new, run by `test-packaging.py` or listed in docs) uses a fake
  `open` on `PATH` that records its argv into a file. It checks:
  - argument validation (no files, missing file, wrong extension, directory, a name
    starting with `-`, spaces/Unicode/`%`/quotes in names)
  - absolute path conversion, including `parent\n/note.md` with an empty `parent`
    sibling directory, so `cd` succeeds but the constructed file fails the final `-f` check
  - `-a` and `MDV_APP` selection
  - `--` placement
  - nothing is opened when any argument is invalid
- Installer tests run with a fake HOME under `.build/` (existing pattern) and a fake
  installed bundle:
  - `--dry-run --cli` creates nothing
  - `--cli` creates the right link
  - an existing foreign file/link (including pip's `mdv`) refuses without
    `--replace-cli`; `--replace` alone never permits CLI replacement
  - each replacement flag grants only its own scope, even on combined installs
  - symlinked `~/.local` and `~/.local/bin` refuse
  - CLI-only preflight accepts a correctly signed older renderer independent of repo
    asset hashes, and rejects invalid signatures, wrong bundle IDs and missing/nonexecutable launchers
  - `--uninstall-cli` removes only an MDViewer link
- `bash -n`/`sh -n` covers `scripts/mdv` explicitly; the `scripts/*.sh` glob misses
  extensionless files.
- No test calls the real `open` or launches the app.

## Acceptance

- C1: `mdv README.md docs/specs/x.md` from any directory issues exactly one
  `open -b de.local.mdviewer -- /abs/README.md /abs/docs/specs/x.md`.
- C2: Invalid input, including a path invalidated by absolute-path construction,
  opens nothing and exits nonzero with a clear message.
- C3: Install and uninstall of the CLI are guarded, idempotent, and do not touch
  anything outside the dedicated `~/.local/bin` directory/link setup. A foreign `mdv`
  requires `--replace-cli`, never app-only `--replace`; symlinked `.local`/`.local/bin`
  refuse. CLI-only preflight verifies the installed signature, ID and launcher without
  requiring its renderer to match the current checkout.
- C4: The packaged bundle passes `verify_assets.py` with the new resource. Tamper tests
  catch a modified `mdv`.
- C5: The actual-app check `mdv` → window opens is manual acceptance, run only with
  user approval.
