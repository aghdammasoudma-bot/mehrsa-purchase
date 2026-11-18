# CMMS V1 P1 business-rule hardening — review notes
Date: 2026-11-18
Scope: draft-only changes on `feature/cmms-v1`; Production and Staging were not modified.

## Changes prepared
1. Asset retirement is blocked while nonterminal work orders or active PM plans exist. Users must close/cancel work orders and deactivate PM plans first.
2. Meter readings are rejected for retired assets; values must be finite and non-negative.
3. PM plan creation and update are rejected for retired assets. The linked asset row is locked to serialize with retirement.
4. PM scheduler excludes retired assets and locks both plan and asset rows to serialize with retirement.
5. Failure triage rechecks the asset's current status; conversion to a work order is denied after retirement.
6. Work-order action duration, quantity and meter reading reject negative values; numeric NaN and infinities are rejected. Zero remains valid.

## Concurrency approach
Operations that add meter/PM work or convert a failure acquire a shared lock on the asset row. Retirement acquires an update lock. This prevents retirement from racing past a concurrent operation. The scheduler similarly locks eligible assets while generating tasks.

## Not changed / unresolved
- Meter readings are not forced to be monotonic. Meter rollover, replacement, reset, and multi-counter semantics are not specified; enforcing monotonicity without those business rules could reject valid readings.
- PM plan deactivation behavior with already-open PM tasks is unchanged.
- Attachment path validation and purchase-request linkage authorization remain separate P1 work.
- The scheduler's locking syntax and all replaced function bodies require compilation against the exact Staging schema before any execution.
- The existing acceptance test script contains pre-existing signature/fixture inconsistencies and must be reconciled before claiming a passing integration test.

## Safety status
- No SQL was executed on Production or Staging.
- No migration was applied.
- No deployment or merge to `main`.
- This is a reviewable Staging-only draft, not a production-ready release.
