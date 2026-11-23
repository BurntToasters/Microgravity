# Critical Information - Do not modify this section. All other sections below may be modified.

- Prefer E2E tests as the primary proof for user-visible behavior. Produce a
  verifiable, repeatable artifact under `test-results/` at the end.
- Write the failure-mode inventory first. If a system must be tested in
  isolation, list the ways it can fail before writing the code.
- Unit tests are for pure logic, parsers, and failure paths the E2E layers
  cannot reach. Author them before the implementation, not as a retrospective
  substitute for E2E coverage.
- Do not add agents as co-authors to commits or PRs.