# ADR-0608: Inline image requests are size-checked as a full RPC envelope

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `OutgoingImagePayload` (`Intent/Services/OutgoingImagePayload.swift`)

## Decisions

### 1. Validate the serialized envelope against the frame limit

Applies to: `OutgoingImagePayload.validateRequest(method:params:)`

Inline images share the host's 40 MiB frame with text, metadata, and JSON
escaping. The check serializes the whole JSON-RPC envelope the same way as
`ConnectionManager`'s serializer and compares it with
`WebSocketConnection.maximumMessageSize`. The envelope uses `Int.min` as the id
to bound the size of any real RPC id.
