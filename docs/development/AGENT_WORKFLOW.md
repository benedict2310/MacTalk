# Agent workflow and lifecycle governance

This document governs agentic implementation work. It supplements the ownership
rules in [ARCHITECTURE.md](ARCHITECTURE.md); it does not replace product or
release requirements.

## Scope, budgets, and handoffs

A worker receives **one production invariant and its deterministic tests**, not
a multi-invariant plan task. Its assignment names permitted files, the focused
validation command, explicit non-goals, and the lifecycle-contract ID.

Workers report this checkpoint at five minutes and stop at ten minutes. A
coherent, tested slice is handed off at that limit; it never extends the budget:

```text
Invariant: LC-... / I...
Tool progress since start:
RED evidence:
Files touched:
Current hypothesis and next action:
Blocker or residual risk:
```

A worker with no tool progress for five minutes stops investigation and returns
a diagnostic. Between major ownership boundaries, start a fresh session with:

```text
Contract: LC-...
Commits:
Satisfied invariants:
Residual policies:
Commands and results:
Changed ownership/API:
Unresolved risks:
Designated concurrency reviewer:
Next single-invariant assignment:
```

## Lifecycle contract (required before concurrency implementation)

Each concurrency-sensitive plan defines one contract per ownership boundary:

```markdown
Contract: LC-<boundary>-v<N>
Owner and serialization mechanism:
Protected resource and generation identity:
Linearization point:
Terminal outcomes:
Contract owner and designated concurrency reviewer:
```

It then supplies a state/transition table covering `idle`, `starting`,
`active`, `stopping`, and `terminal`, including owner retention, permitted
events, required side effects, forbidden side effects, and a deterministic
acknowledgment for every transition.

Every contract explicitly tests these invariants:

1. **Unique ownership:** only the current generation may mutate or publish.
2. **Replacement ordering:** a replacement claims ownership before cancellation
   or suspension.
3. **Stale isolation:** superseded callbacks cannot affect replacement state,
   waiters, resources, or cleanup.
4. **Idempotent stop and terminal delivery:** repeated stop/failure does not
   duplicate cleanup or terminal publication.
5. **Waiter totality and retention:** every admitted waiter resumes exactly once
   and resources remain retained through their documented consumer boundary.
6. **Cleanup isolation:** cleanup is generation/identity-bound and cannot remove
   a replacement resource.

Required adversarial traces are: replacement while A is suspended; repeated
stop followed by A's delayed terminal event; concurrent waiters during
replacement/cancellation; delayed A cleanup after B is current; and stale or
repeated A failure after B begins.

Ordering tests use a semantic barrier—such as a controlled continuation, actor
probe, manual scheduler, or `DeterministicASRBarrier`—at ownership installation,
replacement, stop claim, terminal publication, or cleanup entry. `Task.yield()`
may create stress/fairness pressure but is never an ordering oracle.

## Review and policy adjudication

Before implementation, the designated concurrency reviewer validates the
contract and traces. The same reviewer confirms the completed implementation
against that contract. A defect finding must cite its invariant ID, observed
trace, expected transition, evidence, and minimal correction boundary.

Reviewers identify contract violations; they do not introduce policy as a
defect. A disputed intended behavior receives one contract-owner or architect
adjudication and is recorded as an amendment or residual policy. Security
review is required only for trust boundaries, filesystem identity, secrets,
networking, provenance, or untrusted bytes; UI review is required only for
observable AppKit behavior.

Use this residual-policy record for intentional behavior:

```markdown
RP-<number>: <short behavior>
Status: accepted | temporary | rejected
Contract/version and scope:
Intentional behavior and rationale:
Permitted observation:
Forbidden consequence:
Ownership/retention rule:
Deterministic evidence:
Owner/approver and recorded date:
Revisit trigger:
Reviewer treatment: do not block unless <boundary> is violated.
```

## Validation ladder

Run the narrowest meaningful check after each behavioral RED/GREEN increment.
Before handoff, select validation by change risk:

| Change | Before handoff |
|---|---|
| Production lifecycle/ownership | Relevant deterministic suite; signed app launch once per coherent runtime batch; TSan for concurrency risk |
| Other production behavior | Focused test and relevant deterministic suite; signed app launch only when runtime behavior needs manual validation |
| Test-only | Focused test and relevant suite; no app restart |
| Documentation | Documentation/static checks; no app restart |
| CI/build/runtime integration | Focused semantic scripts; fresh signed build when build/runtime behavior changed |

Before merging production changes, run `scripts/test-lanes.sh unit`. Run TSan
for synchronization, ownership, audio-pipeline, or concurrency changes; it is
not a routine UI, settings, documentation, or test-only gate. Coverage is
scheduled/manual CI evidence, not a duplicate pull-request gate.
