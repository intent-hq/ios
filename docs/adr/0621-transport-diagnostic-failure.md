# ADR-0621: Transport diagnostic failures are closed classifications

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TransportDiagnosticFailure` (`Intent/Services/TransportDiagnosticFailure.swift`)

## Decisions

### 1. Classify, do not redact

Applies to: `TransportDiagnosticFailure.classify(_:)`, `TransportDiagnosticFailure.network(_:origin:)`,
`TransportDiagnosticFailure.probe(_:)`

These functions are boundary classifiers, not string redactors. Associated
hostnames, fingerprints, foreign descriptions, and unknown numeric codes are
discarded.

### 2. WebSocket close codes are a fixed table

Applies to: `TransportDiagnosticFailure.closeCode(_:)`

The close codes come from RFC 6455's fixed protocol code table, not from
application-provided numbers. This is why the `no_magic_numbers` lint rule is
disabled around the table.
