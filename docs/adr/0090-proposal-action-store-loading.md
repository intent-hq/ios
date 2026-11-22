# ADR-0090: Proposal action cards reuse settled agent detail

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ProposalActionStore` (`Intent/Services/ProposalActionStore.swift`)

## Decisions

### 1. `loadIfNeeded` does not refresh

Applies to: `ProposalActionStore.loadIfNeeded()`

The view tasks for card appearance and metadata generation call
`loadIfNeeded`, which loads with `refresh: false`, so they reuse agent detail
that has already settled.
