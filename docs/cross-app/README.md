# Cross-app shared service: design package (proposal)

**Status: proposal for Group 1 review. Nothing here is an accepted decision.** The in-process runtime (`AGENTS.md`, #26) stays the product boundary until Group 1 decides otherwise.

Prepared by Group 2 (Maxik + Claude) for the task in #13. Base: PR #14 head `772155def9f4baf232f43864a80add7cd3c5192c`.

| File | Content |
|---|---|
| [01-state-and-gates.md](01-state-and-gates.md) | Live PR/CI table (#1–#26), stacks, Issues #13/#15, what is fixed, open or undecided, measurement gates |
| [02-architecture-adr.md](02-architecture-adr.md) | Options O1–O7, recommended O2 (per-user broker), components, lifecycle, cache and failure rules |
| [03-threat-model.md](03-threat-model.md) | Assets, trust boundaries, data flow, threats T-1…T-18 with status, residual risk |
| [04-api-spec.md](04-api-spec.md) | Protocol v1, typed client API, scope/cache/version rules, error codes, manifest |
| [05-memory-methodology.md](05-memory-methodology.md) | Break-even model, experiment design for 1/2/4/8 clients, UI vs data separation, gates |
| [06-implementation-plan.md](06-implementation-plan.md) | Phases P0–P6 with acceptance criteria; blocking questions Q0–Q9 |
| [07-verification-report.md](07-verification-report.md) | Commands, CI runs and actual results for this package |

The prototype is in [`experiments/cross-app-spike`](../../experiments/cross-app-spike/README.md).
