# Report contract

Read when writing artifacts. Use the timestamped filenames required by `CONTRIBUTING.md` and keep all ten dimensions. These templates are self-contained; do not depend on a missing `codebase-audit` skill. Adapt prose to the evidence; empty sections should say "None identified within reviewed coverage" or "Not assessed" with the relevant limitation.

## Evidence layout

```text
_dev/reviews/
  critical_analysis_<YYYYMMDD_HHMMSS>.md
  improvements_<YYYYMMDD_HHMMSS>.md
  evidence_<YYYYMMDD_HHMMSS>/
    ci.log
    commands.md
    ...focused logs, scratch reproducers and results as needed
```

`commands.md` records actual commands, cwd, relevant non-secret overrides, start time/duration, exit code, outcome and log/result links. Distinguish **Passed**, **Failed**, **Not run**, and **Blocked by environment**. Record the inspected source snapshot and hashes of reproduction inputs/binaries where applicable. Do not silently edit a failed run's log to resemble a later successful run; give subsequent evidence a distinct filename.

## critical_analysis_<YYYYMMDD_HHMMSS>.md

Use this structure:

```markdown
# Critical Analysis

**Date:** {timestamp with timezone}
**Commit:** {full HEAD}
**Branch observed:** {branch or detached}
**Working tree:** {clean/dirty; changed paths and snapshot evidence}
**Reviewer:** {host agent} (automated)
**Model:** {exposed model identity/ID, otherwise unknown}
**Provider:** {exposed provider, otherwise unknown}
**Thinking level:** {exposed setting, otherwise unknown}
**Platform/toolchain:** {host OS/architecture; actual and pinned Zig versions}
**Scope:** {current working tree; any user-requested bounds}
**Assessment:** {complete/partial; material limits}

## Composite Score: {X.X} / 10 — {N}/10 dimensions assessed

{Arithmetic mean of numeric scores. If none are assessable, write "Not assessed".
A partial score must be labeled partial. Summarize the practical readiness result.}

| Dimension | Score | Highest confirmed severity | Coverage/confidence |
| --- | --- | --- | --- |
| 1. Safety & Correctness | {n/10 or Not assessed} | {severity or None} | {scope/strength} |
| 2. Error Handling | ... | ... | ... |
| 3. API Design | ... | ... | ... |
| 4. Concurrency | ... | ... | ... |
| 5. Testing | ... | ... | ... |
| 6. Performance | ... | ... | ... |
| 7. Documentation | ... | ... | ... |
| 8. CI/CD & Release | ... | ... | ... |
| 9. Dependency Hygiene | ... | ... | ... |
| 10. Conventions | ... | ... | ... |

## Top Blockers

{Confirmed blockers only: finding ID, reachable trigger, consequence and evidence.
If empty, say "No confirmed production blockers" and state any verification limits.}

## Coverage

| Subsystem | Files/entry points | Behavior traced | Evidence | Gaps |
| --- | --- | --- | --- | --- |
| {subsystem} | {paths} | {flow/error cases} | {tests/logs} | {unread/untested areas} |

## Dimension Findings

### 1. Safety & Correctness — {score}

{Verified strengths, limitations and rationale for the score.}

#### CR-001 — {concrete failure}

- **Severity / Priority:** {Critical/High/Medium/Low} / {P0/P1/P2/P3}
- **Location:** {current repo-relative file:line; related callers if needed}
- **Trigger and impact:** {supported input/state → consequence}
- **Evidence:** {code trace or reproduction; expected/actual result; log link}
- **Confidence:** {evidence strength and reproduction limits}
- **Correction:** {smallest fix addressing the cause}
- **Acceptance check:** {observable behavior/regression verification}

{Repeat the dimension section for all ten dimensions. Describe each root cause
once under its primary dimension; other dimensions can reference its ID.}

## Verified Requirements

| Requirement and source:line | Applicability | Status | Evidence |
| --- | --- | --- | --- |
| {actual rule} | {scope} | {Met/Violated/Not verified/Not applicable} | {trace/output} |

{If no contributor-specific rules exist, say so; still check documented product
contracts. Do not invent missing-policy requirements.}

## Validation Results

| Command/stage | Outcome | Exit | Evidence | Limits |
| --- | --- | --- | --- | --- |
| {actual command} | {status} | {code or not run} | {relative link} | {coverage} |

{Identify just ci, ci-extended, ci-full, and canary results separately, including
stages not reached/skipped, tests actually executed, native vs compiled-only
targets, and synthetic protocol fixtures vs authorized live CLI evidence.
Quote short decisive output excerpts; link full logs instead of pasting them.}

## Open Questions and Limitations

{Unconfirmed hypotheses with the missing evidence/next check; inaccessible
upstreams, unavailable platforms/tools, sampling, concurrent source changes.
These are not confirmed findings or blockers.}

## Cross-check

{Optional, only after independent findings/scores: prior report paths consulted,
independently re-verified adopted IDs, or "Not performed". No trajectory scoring.}
```

Use source lines from the reviewed snapshot, and relative links for saved evidence. A source citation must support the asserted consequence; a search hit or missing test alone is insufficient.

Report metadata comes only from exposed session/runtime information. Do not dump environment variables, read API keys or inspect unrelated personal configuration to guess the model/provider/reasoning setting.

## improvements_<YYYYMMDD_HHMMSS>.md

Each confirmed finding ID appears exactly once, under one priority, with a concrete correction and an acceptance check. Separate root causes stay separate; shared symptoms do not create duplicate tasks. Do not add unverified suggestions merely to fill tiers.

```markdown
# Improvements Checklist

**Generated from review:** [critical_analysis_<YYYYMMDD_HHMMSS>.md](critical_analysis_<YYYYMMDD_HHMMSS>.md)
**Date:** {timestamp}
**Snapshot:** {HEAD plus dirty-tree evidence if applicable}

## P0 — Blockers

- [ ] **CR-001 [Safety & Correctness]** {action addressing the root cause} — `path:line` — Effort: {S|M|L}
  - Acceptance: {specific observable success condition or targeted regression check}.

{If empty: "None identified." Use the same item shape below.}

## P1 — Before next release

{confirmed items or "None identified."}

## P2 — Planned release cycle

{confirmed items or "None identified."}

## P3 — Optional improvements

{confirmed items or "None identified."}

## Progress

**Total unique findings:** {n}
**P0:** {n} | **P1:** {n} | **P2:** {n} | **P3:** {n}
```

Effort estimates: **S** under 1 hour, **M** 1–4 hours, **L** over 4 hours; state uncertainty for work that needs investigation. Keep all boxes unchecked for a review-only request. Include existing tests/probes where they verify the outcome; do not prescribe implementation-mirroring tests for low-impact wording/style changes.

Before delivery, reconcile unique IDs, primary dimensions, blocker membership, priorities, checklist counts, numeric scores and citations. A dimension with no confirmed issue can still have limited coverage; say that directly instead of inventing a defect.
