# Microgravity remaining-work plan

Prepared 2026-11-07. This file is a handoff for completing investigations, fixes,
verification, and release-readiness evidence. Read it together with
`docs/UI_ACCEPTANCE.md`, `docs/IMPLEMENTATION_STATUS.md`,
`docs/FAILURE_CASES_CORE.md`, and `docs/RELEASING.md`.

## 1. Starting state and evidence

- Source is based on commit `af1359c2c5c76200bdb481e27a6ed578f2b7bad0` with
  uncommitted work. Preserve all existing edits. Do not reset, stash, stage,
  commit, or push them without authorization.
- The latest complete signed composite run executed 229 native tests:
  207 Core tests passed; 21 UI tests passed; one UI test failed with three
  assertions. No tests were skipped. The full release gate is **failed**.
- The failing test is
  `testVisualAcceptanceCapturesAllPagesAtBothSizesAndAppearances`. Its resize
  gesture left the actual window at 1280 × 820 instead of 960 × 600.
- Node tests passed 32/32. Validation, project/version synchronization, Debug
  build, and unsigned universal Release smoke build passed. These results do
  not prove signing, notarization, distribution, or complete UI acceptance.
- The visual test captured 24 default-size window screenshots across eight
  pages and three appearances. All PNGs measured 2560 × 1640 pixels on the
  tested display. No minimum-size captures exist from this run. Only selected
  screenshots received visual inspection.
- The final result contains 22 runtime warnings. A proven main-thread helper
  signing call was moved to a background task. A separate UI startup warning
  involving a Security.framework callback remains unresolved.
- Host preference audits found zero nonempty fixture preference domains and
  zero fixture-derived keys in the real app preferences.
- An earlier 224-test pass is superseded for the current source. There is no
  reusable release proof for the dirty worktree or the failed composite run.

Preserved local artifacts, if still available:

| Artifact | Location |
| --- | --- |
| Complete final native result | `/private/tmp/microgravity-final-audit-6nwsxljc/final-test-all.xcresult` |
| Summary | `/private/tmp/microgravity-final-audit-6nwsxljc/summary.json` |
| Composite log | `/private/tmp/microgravity-final-audit-6nwsxljc/test-all.log` |
| Build logs | `/private/tmp/microgravity-final-audit-6nwsxljc/debug.log`, `/private/tmp/microgravity-final-audit-6nwsxljc/release.log` |
| Exported attachments | `/private/tmp/microgravity-final-audit-6nwsxljc/attachments/manifest.json` |
| Default capture dimensions | `/private/tmp/microgravity-final-audit-6nwsxljc/default-captures.json` |
| Source comparison and patch | `/private/tmp/microgravity-final-audit-6nwsxljc/final-hashes.json`, `/private/tmp/microgravity-final-audit-6nwsxljc/final.patch` |
| Original task baseline | `/private/tmp/microgravity-ui-coverage-dssu920m/` |
| Warning investigation | `/private/tmp/microgravity-ui-coverage-dssu920m/warning-trace/` |

Temporary artifacts may disappear. Missing evidence must be regenerated, not
reported as verified. The final verification worktree was removed; canonical
source edits remain in this repository.

## 2. Working rules and initial inspection

- [ ] Read applicable `AGENTS.md` instructions and inspect current Git status,
  staged/unstaged diffs, untracked files, and HEAD before editing.
- [ ] Save a fresh baseline patch and tracked-file hashes outside deliverables.
  Distinguish existing user changes from new task changes.
- [ ] Confirm current test names and project scripts; counts may change when
  meaningful regressions are added. Never force historical counts.
- [ ] If delegated execution is requested again, retain the user's requested
  GPT-6 Luna Max workers and maximum two subagents. Apply the oversee skill;
  do not silently substitute models or resume exhausted retries without renewed
  authorization. This document alone does not start another execution attempt.
- [ ] Use one GUI/hosted XCTest session at a time. Separate build-only work may
  use independent source and DerivedData directories.
- [ ] Preserve the UI hard gate, sandboxing, real signing requirements, process
  identity protections, helper policy, and fixture isolation.
- [ ] Do not enable authentication bypasses, grant macOS prompts, install the
  helper, alter login items, reset real history, or publish a release merely
  because this plan lists their verification. Obtain any missing authorization.
- [ ] Keep implementation narrow. Remove diagnostic instrumentation and failed
  experiments before final review. Do not add broad routing or layout frameworks.

## 3. Fix and prove minimum-size window interaction

Relevant files: `Tests/UITests/MicrogravityUITests.swift`,
`Sources/UI/SettingsViewController.swift`,
`Sources/UI/Shell/MainWindowController.swift`,
`Sources/UI/AppShellViewController.swift`, and `Tests/CoreTests/WindowTests.swift`.

- [ ] Reproduce the failed resize alone on an authorized, logged-in GUI host.
  Inspect the actual window frame, accessibility hierarchy, drag coordinates,
  display scale, and failure attachments before changing code.
- [ ] Determine whether the remaining failure is the test gesture or production
  resize behavior. The latest helper used a coordinate near the bottom-right
  edge; moving it from `.99` to `.999` did not produce a proven successful
  minimum-size resize. Do not repeat coordinate guesses without evidence.
- [ ] Use a reliable native resize interaction and verify the measured window
  frame becomes exactly 960 × 600. Keep production minimum/default sizing
  intact. Do not fake dimensions in accessibility metadata or screenshot names.
- [ ] Fail immediately if resize fails, preserving diagnostics instead of
  producing multiple derivative assertions or mislabeled captures.
- [ ] Clarify and consistently test content-size versus outer-frame semantics.
  Do not weaken the documented 1280 × 820 / 960 × 600 acceptance requirement to
  accommodate a title-bar offset accidentally introduced by the test.
- [ ] Verify the user cannot resize below the intended minimum and can expand
  again after reaching it. Preserve normal production frame autosave/relaunch.
- [ ] Verify page navigation and appearance changes preserve default, minimum,
  and custom 1100 × 700 geometry. Cover both native sidebar selection and menu
  navigation, with layout settled before assertions.
- [ ] Keep exact-identity Show in Details, toolbar updates, sidebar collapse,
  controller lifecycle, and last-window-close behavior working.

Known sizing investigation to preserve:

- AppKit's `NSWindow _changeWindowFrameFromConstraintsIfNecessary` initiated
  the earlier Settings shrink from 1100 to 1057 points. This was not a test drag.
- The current Settings fix uses a full-width scroll document wrapper, a capped
  form, and a lower-priority optional width-fill constraint. The custom-frame
  Core regression passed with this configuration.
- Root autoresizing changes alone did not fix the problem. Window wrappers,
  `fittingSize` overrides, preferred-size propagation, async frame resets, and
  temporary minimum-size locks failed or oscillated and were removed.
- Do not reintroduce forced frame restoration that fights AppKit or prevents
  genuine user resizing. Do not claim the exact solver cause solely from the
  720-point cap; that cap was slack in one diagnostic dump.

## 4. Fix remaining readable-value and text-layout defects

- [ ] Make the Settings helper explanation fully readable at both sizes and in
  all appearances: “Lets you quit processes owned by other standard users.
  System and root processes stay protected.” Use an appropriate wrapping layout
  and vertical scrolling. Preserve the helper's actual protection policy.
- [ ] Fix the App History partial CPU total presentation. The narrow column
  currently truncates text such as “Measur… · partial” and hides the numeric
  lower bound. Keep the number and its lower-bound/partial meaning readable.
- [ ] Preserve gap semantics, units, full tooltip/accessibility information,
  and numeric sorting. Missing samples must never become measured zero.
- [ ] Inspect both normal history and the `--ui-test-history-gap` fixture.
  Numeric sort tests passing is not evidence that formatted totals are legible.
- [ ] Check surrounding rows, selection, headers, empty states, badges, and
  scrollers at minimum width. Avoid horizontal scrolling of the page body.
- [ ] Add or adjust only meaningful regression checks for the changed behavior.

## 5. Finish the 48-image visual acceptance matrix

Required pages: Processes, Performance, App History, Startup, Users, Details,
Services, and Settings. Required appearances: System, Light, and Dark. Required
sizes: default 1280 × 820 and minimum 960 × 600.

- [ ] Capture all 8 × 3 × 2 = 48 combinations from the final source.
- [ ] Select appearance through the native Settings menu and record its actual
  selected value. Record effective System appearance and host display scale.
- [ ] Assert actual window geometry before every capture and after navigation
  and appearance changes. Capture the app window, not the entire desktop.
- [ ] Export a manifest mapping page, requested/selected appearance, measured
  point dimensions, PNG pixel dimensions, and attachment filename.
- [ ] Preserve partial manifests on failure so captured evidence remains useful.
- [ ] Inspect all 48 images, not merely their existence or dimensions. Check
  clipped/overlapping text, badges, contrast, heat maps, selection, empty and
  unsupported states, toolbar content, scroll behavior, and color-only status.
- [ ] Inspect the history-gap state separately from the normal matrix.
- [ ] Fix concrete findings, regenerate affected evidence, and run the final
  integration gate on the final app/test bytes. Do not relabel old captures.
- [ ] Store reviewable evidence using repository conventions. Do not commit
  desktop captures, private data, large incidental recordings, or scratch files.

## 6. Complete runtime-warning investigation

Relevant files: `Sources/Integration/NativeSystemIntegrationAPI.swift`,
`Sources/Shared/HelperProtocol.swift`, app startup, and appearance/icon paths.

- [ ] Preserve background helper-signature validation. Both status refresh and
  helper configuration await the background result; MainActor state updates
  and existing trust checks must remain intact.
- [ ] Verify complete signing validation on a background thread, including its
  return. One short focused trace ended before the validation exit was captured.
- [ ] Attribute the remaining warning using signed, controlled reproduction,
  timestamps, source call boundaries, unified logs, and trustworthy stacks.
- [ ] Compare Core-hosted startup and UI fixture startup. A hosted app's global
  activation observer can run even when a Core test injects fake integrations.
- [ ] Preserve uncertainty: UI faults occurred after instrumented appearance
  and icon calls, on a different thread, with private Security/framework frames.
  No app-level triggering API has been established for that UI warning.
- [ ] Do not infer the exact function from a nearest private symbol, suppress
  diagnostics, remove required XCTest MainActor isolation, use unchecked
  sendability, weaken signature validation, or move AppKit calls off main.
- [ ] Avoid the abandoned interposer experiment; it recursed/timed out and was
  never an accepted fix. Keep any new diagnostics in disposable source copies.
- [ ] Fix a proven app cause at its responsible layer. If the issue is external,
  retain a minimal reproduction, exact environment, evidence, and explicit
  unresolved status. A remaining warning is not a zero-diagnostics pass.
- [ ] Report final warning counts and attribution separately from test failures.

## 7. Preserve and recheck sheet coverage and test cleanup

- [ ] Keep Force Quit cancel, successful confirmation, and stale-identity
  rejection passing. Confirm sheet attachment, informative target text, and
  cancel/confirm result states.
- [ ] Fixture success must match the full synthetic PID/start-time identity
  (PID 411, start time 1700000002 seconds + 20000 microseconds), require force,
  and remove only that fixture process. Never signal host PID 410 or 411.
- [ ] Keep Reset History cancel preserving history, and confirm clearing
  history without changing process identities or operating-system state.
- [ ] Keep refresh selection, expansion persistence, duplicate-group identity,
  native header sorting, unavailable metrics, and Show in Details tests passing.
- [ ] Preserve app-owned cleanup on graceful Command-Q. The sandboxed UI runner
  cannot prove host preference cleanup through its own UserDefaults, defaults
  subprocess, or container-relative plist reads.
- [ ] Cleanup must remain Debug/XCTest/fixture gated, validate the exact
  `Microgravity.UITests.test…` suite, remove only derived fixture keys, and
  verify synchronization. Never clear the real app preference domain.
- [ ] Preserve force termination only where the persistence test needs state
  to survive a relaunch; final teardown must still perform graceful cleanup.
- [ ] After the final suite, audit actual host `~/Library/Preferences` outside
  the runner: zero nonempty `Microgravity.UITests.*` domains and zero fixture
  table/window autosave keys in `run.rosie.microgravity.plist`.
- [ ] Ensure fixture appearance and frame behavior do not overwrite normal
  production appearance, table configuration, or saved window frame.

## 8. Final independent automated verification

- [ ] Create a fresh isolated checkout outside Documents to avoid repeated TCC
  prompts. Apply the entire intended working patch and required new files.
  Compare source/test bytes with canonical source before running checks.
- [ ] Check Automation Mode with `automationmodetool` and confirm a logged-in,
  unlocked session. Do not change security settings automatically.
- [ ] Verify the signing identity and team. Prior successful tests used generic
  `Apple Development` with team `FYJZP8B2KG`; the certificate display name's
  account ID `W22N3XDGQU` is not the signing TeamIdentifier. Recheck current
  availability rather than assuming a certificate still exists.
- [ ] Run the documented checks from the isolated checkout:

  ```sh
  npm run project:sync -- --check
  npm run sync-version -- --check
  npm run validate
  npm run test:node
  npm run build:debug
  npm run build:release-smoke
  MICROGRAVITY_UI_SIGNING_IDENTITY='Apple Development' \
    MICROGRAVITY_UI_TEAM_ID=FYJZP8B2KG npm run test:all
  ```

- [ ] Require zero failing or unexpectedly skipped Core/UI tests. Do not skip
  the matrix, disable the UI target, or weaken assertions to make the gate pass.
- [ ] Wait for the actual command exit and a complete `.xcresult`, not an
  intermediate suite summary. Verify result metadata and exported summaries.
- [ ] Do not start another GUI session while an earlier test process remains.
  Preserve terminal results, then clean up only positively identified,
  task-owned residual processes. Never use broad process-name kills.
- [ ] Save the complete result bundle, logs, capture manifest, reviewed source
  hashes, final diff, and warning summary outside temporary worktrees.
- [ ] Recheck staged/untracked/deleted files, scope, and `git diff --check`.
  Verify preservation of the original user edits and absence of scratch files.
- [ ] Verify no app/test source changed after final checks. Repeat relevant
  checks if it did. Documentation-only corrections do not require another UI run.
- [ ] Remove only task-created verification worktrees after saving evidence.
  Leave canonical edits intact. A dirty-tree pass still creates no reusable
  clean-source release proof.

## 9. Manual and live acceptance still needed

Record date, environment, exact procedure, observed result, and reviewer.
Automated fixture tests do not satisfy these checks.

- [ ] Complete all-page visual review at both sizes and three appearances.
- [ ] VoiceOver: sidebar groups/page/selection; Processes row name and PID;
  expand/collapse announcements; selection and keyboard focus through refresh.
- [ ] Verify documented keyboard shortcuts, menu navigation, toolbar actions,
  and sidebar toggle remain usable.
- [ ] With authorization, use an explicitly created throwaway process owned by
  the tester for live Force Quit. Cancel leaves it running; confirmation ends
  that exact process. Never target an arbitrary real process or its children.
- [ ] Verify live Reset History only against disposable or explicitly approved
  history. Cancel preserves records; confirm clears history without changing
  processes. Never reset the user's real history without approval.
- [ ] Verify closing the last window exits; reopening restores production frame.
- [ ] Inspect the icon in the Dock, About panel, and system Force Quit dialog.
  Asset/bundle validation alone does not establish visual correctness.
- [ ] Record any required macOS prompt as a human dependency; do not claim a
  completed check while waiting for its answer.

## 10. CI, live integrations, and distribution follow-up

These are remaining product/release checks, not permission to publish or alter
external services. CI work previously had docs-only/no-push authorization.

- [ ] Inspect `.github/workflows/ci.yml` and confirm its checks match documented
  Node, sync, validation, unsigned Core, Debug, and universal Release checks.
- [ ] With separate authorization, run hosted CI for the exact final source and
  preserve the run URL/results. Runner-label availability is not a successful
  workflow run. Hosted Core-only CI does not replace signed local UI tests.
- [ ] With authorization and a suitable test host, verify real helper setup,
  authorization, fixed-command/XPC behavior, removal, and protected-process
  rejections. Do not widen helper policy to fix a test.
- [ ] Verify live advanced metrics, unavailable/error states, and long-running
  sampling, memory, refresh, and history-write behavior using evidence-based
  acceptance criteria. Report duration and workload; invent no performance pass.
- [ ] Verify login-item changes and undo test changes only with authorization.
- [ ] Handle pre-release CPU history units: document the required reset and use
  disposable history for verification; never silently erase existing records.
- [ ] Before an authorized release, follow `docs/RELEASING.md` for clean-source
  proof, version/build metadata, credentials, Developer ID signing, notarization,
  stapling, archive verification, and a real signed Sparkle appcast/update test.
- [ ] Do not expose secrets or place credentials in this file, logs, or commits.
- [ ] Keep publication, upload, tagging, and pushes as separately authorized
  actions. Unsigned universal compilation is not distribution verification.

## 11. Completion record and handoff

- [ ] Update `README.md`, `docs/IMPLEMENTATION_STATUS.md`, `docs/RELEASING.md`,
  and `docs/UI_ACCEPTANCE.md` with measured final results and evidence links.
- [ ] Distinguish passing tests, reviewed screenshots, manual checks, external
  limitations, unrun CI, and distribution checks. Do not imply completion from
  compilation, screenshot existence, or earlier source revisions.
- [ ] Document unresolved items with reproduction, impact, evidence, and next
  action. A blocked or deferred item remains incomplete, even if documented.
- [ ] Report changes, test/build totals, runtime-warning disposition, remaining
  blockers, and any pending human/external requirements concisely.
- [ ] If work stops because authorization, credentials, environment, or an
  applicable retry limit prevents progress, preserve this plan and the evidence.
  Do not delete the plan or declare the project finished.

## Final instruction to the completing agent

After all applicable work above is actually complete, all required checks pass,
and the completion evidence has been recorded in the permanent documentation,
delete this repository-root `plan.md` file. Do not delete it while required work
is unfinished, blocked, or merely deferred. Mention its deletion in your final
handoff.
