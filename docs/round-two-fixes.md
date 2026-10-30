# Round-two final hardening fixes

> Historical review-driven work direction from 2026-10-29, not authorization to rerun commands or resume implementation. [TEST_RESULTS.md](../TEST_RESULTS.md) preserves outcomes, counts and limitations; the [separate blocker plan](plans/2026-10-29-tmp-parent-watcher-blocker.md) remains unexecuted.

This historical work used PLAN.md, SPEC.md, docs/implementation-continuation.md and TEST_RESULTS.md. Its implementation authorization excluded app installation, actual-app launch, Launch Services, handler/default changes, Git, pi-files edits, global tools, privilege escalation and network alterations.

## Review evidence
The historical independent review closed both prior M1/M2 P1s. It identified a new P1 at `Sources/MDViewerCore/DirectoryWatcher.swift:9`, independently confirmed: subprocess `os.open(fifo, os.O_EVTONLY)` on a FIFO with no writer timed out at 2 seconds, blocking the main actor during initial start or replacement rebind. Before/after regression evidence is preserved in [TEST_RESULTS.md](../TEST_RESULTS.md#beforeafter-regression-evidence), not a machine-local agent report.

## Required changes and regression evidence
1. Test FIFO-at-open and regular-document -> FIFO replacement -> valid-document recreation through DocumentRefresh/watchers. Regression harness must be process-timeout bounded; demonstrate old behavior fails without hanging the supervisor. Then use O_EVTONLY | O_NONBLOCK (consider O_NOFOLLOW), fstat descriptor and accept only regular file/directory, close on reject and preserve useful POSIX error. Verify start returns <0.5s, warning/last-good behavior and recovery, normal directory/file/atomic-save watchers still work.
2. scripts/verify_assets.py currently uses assert for security checks. Reproduce tampered assets/extra resources/manifest rejection under default Python, python3 -O and PYTHONOPTIMIZE=1; replace assertions with explicit checks raising actionable errors and automate negative controls. Check scripts/verify_m0.py security/probe/source-integrity assertions too so optimized invocation cannot silently skip invariants. Test-only assertions elsewhere may stay if not used as release trust gates.
3. Sources/MDViewerCore/RenderHost.swift:52 adds the content rule list on every reload/recovery. Make installation idempotent (remove prior lists immediately before add, or install once). Add a bounded probe/regression check if possible; keep deny-network rule present before shell load.
4. If feasible without production test-only injection hooks, add a direct deterministic check of renderer mismatch fail-closed behavior; otherwise explain why not exercised. Do not introduce unsafe production hooks or broaden renderer surface solely for a test.
5. Document shared serial DocumentIO head-of-line blocking risk on slow volumes (bounded but synchronous reads cannot be interrupted) in known limitations; keep manual acceptance gaps precise.

## Historical verification
Historical verification included CONFIGURATION=release bash scripts/test-webkit.sh (isolated no-document-type probe only), npm test, Python asset tests with optimization variants, signature and install dry-run guards, and script syntax checks. The recorded pre-fix state was 14 Swift tests/76 WebKit checks; see TEST_RESULTS.md for subsequent dated counts, before/after reproduction and remaining acceptance gaps. Detailed logs were local, untracked .build/ evidence. Independent verification and a third review followed this historical work; their remaining blocker is recorded in TEST_RESULTS.md.
