# ADR-0615: RecentRetention keeps recently viewed content for read-only mode

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `RecentRetention` (`Intent/Services/RecentRetention.swift`)

## Decisions

### 1. Fixed capacity, least recently touched first

Applies to: `RecentRetention`

`RecentRetention` is a fixed-capacity store that drops the least recently
touched entry first. It keeps recently viewed content readable during a
connection drop (read-only mode).
