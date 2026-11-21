# ADR-0093: SkillCatalogStore caches successful catalogs per session

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SkillCatalogStore` (`Intent/Services/SkillCatalogStore.swift`)

## Decisions

### 1. Successful catalogs are cached per agent and connection

Applies to: `SkillCatalogStore.CacheKey`, `SkillCatalogStore.cache`

Skills do not change during an app session, so a successful catalog is reused
per agent and connection. Failures are not cached; the next opening retries.

### 2. Offline clears the visible catalog but keeps the cache

Applies to: `SkillCatalogStore.refresh(workspaceId:agentId:connection:)`

When offline, the visible catalog is cleared, so keyboard acceptance cannot
insert a hidden suggestion. The session cache survives and fills the picker
again on reconnect.

### 3. Reset when the composer leaves its workspace

Applies to: `SkillCatalogStore.reset()`

`reset()` clears suggestions and invalidates pending replies when the composer
leaves its workspace.
