# Agent Workflow Governance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` task-by-task. For lifecycle work, assign one invariant plus its deterministic tests to each worker and use the designated concurrency reviewer at contract and final-confirmation gates.

**Goal:** Reduce agent orchestration and validation waste while making lifecycle-concurrency behavior explicit, deterministic, and reviewable.

**Architecture:** Put the durable workflow contract in one development document, link it from repository instructions and architecture guidance, and make test/CI documentation enforce a risk-based validation ladder. CI retains deterministic unit testing as the PR gate while coverage becomes scheduled/manual so the allowlist is not rerun for every PR.

**Tech Stack:** Markdown documentation, Bash/Ruby semantic workflow tests, GitHub Actions, XCTest/TSan.

---

### Task 1: Define lifecycle and agent-workflow governance

**Files:**
- Create: `docs/development/AGENT_WORKFLOW.md`
- Modify: `AGENTS.md`
- Modify: `docs/development/ARCHITECTURE.md`
- Test: `scripts/ci-docs-checks.sh`

- [ ] **Step 1: Add documentation assertions/fixtures for the workflow document and its required lifecycle terms.**
- [ ] **Step 2: Run `bash scripts/tests/test_ci_docs_checks.sh` and observe failure because the document/terms are absent.**
- [ ] **Step 3: Add the lifecycle-contract template, residual-policy format, single-invariant worker scope, 5/10-minute checkpoints, designated-reviewer protocol, and concise fresh-session handoff format.**
- [ ] **Step 4: Link the guidance from `AGENTS.md` and architecture ownership documentation.**
- [ ] **Step 5: Run `bash scripts/tests/test_ci_docs_checks.sh` and `bash scripts/ci-docs-checks.sh`; expect both to pass.**

### Task 2: Define risk-based validation and remove duplicate PR coverage

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/product/PRD-MacTeach.md`
- Modify: `docs/development/SETUP.md`
- Modify: `docs/testing/TESTING.md`
- Modify: `docs/testing/CI.md`
- Modify: `.github/workflows/tests.yml`
- Modify: `scripts/tests/test_ci_workflow_semantics.sh`

- [ ] **Step 1: Change `scripts/tests/test_ci_workflow_semantics.sh` so it requires unit/lint/security/documentation as PR blocking gates and requires coverage to be scheduled/manual rather than blocking.**
- [ ] **Step 2: Run `bash scripts/tests/test_ci_workflow_semantics.sh` and observe failure against the current workflow.**
- [ ] **Step 3: Move coverage to scheduled/manual execution, preserving pinned toolchain, report artifact upload, and failure behavior when the lane is invoked.**
- [ ] **Step 4: Document the validation matrix: focused RED/GREEN per behavioral increment; unit before production merge; TSan only for concurrency/ownership risk; signed launch once per coherent runtime batch; no app restart for docs/test-only changes.**
- [ ] **Step 5: Run `bash scripts/tests/test_ci_workflow_semantics.sh`, `bash scripts/tests/test_ci_docs_checks.sh`, and `bash scripts/ci-docs-checks.sh`; expect all to pass.**

### Task 3: Final validation and review

**Files:**
- Review: all changed files

- [ ] **Step 1: Run `git diff --check`.**
- [ ] **Step 2: Run the focused workflow/doc semantic tests.**
- [ ] **Step 3: Do not restart the app for this documentation/workflow-only batch; the risk-based validation policy requires documentation/static checks instead.**
- [ ] **Step 4: Request one concurrency/workflow review; correct only confirmed contract violations.**
- [ ] **Step 5: Record validation evidence and close the granular todos.**
