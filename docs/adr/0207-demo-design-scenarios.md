# ADR-0207: Design scenarios are data-only fixtures behind an in-memory daemon

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoDesignScenario`, `DemoDesignFixtures` (`Intent/Demo/DemoFixturesDesign.swift`, `Intent/Demo/DemoFixturesDesignData.swift`)

## Context

Design reviews use `--demo-design-scenario=<name>` to show a conversation in a
specific state. The scenario must not take over the screen's own behavior.

## Decisions

### 1. Scenarios provide data only

Applies to: `DemoDesignScenario`

Appearance, keyboard, expansion, and question layout are still controlled by
the real screen and by user interactions.

### 2. Some scenario contents

Applies to: `DemoDesignScenario.automatedMessages`, `DemoDesignScenario.turnFailure`,
`DemoDesignFixtures.turnFailureText`

`automated-messages` shows an agent-to-agent message and a script-monitor wake.
`turn-failure` shows a usage-limit `turn-failure` notice with a raw JSON-RPC
reason. `turnFailureText` is the raw reason intentd persisted for a Codex
usage-limit turn failure.

### 3. The fixture is an in-memory daemon that sets no view or store state

Applies to: `DemoDesignFixtures`

State changes return ordinary RPC payloads and chat snapshots. No view or store
state is set here.

### 4. Pushes follow the response mutation and precede the acknowledgement

Applies to: `DemoDesignFixtures.subscriptionPush(for:params:)`

It is called after the response mutation and before the acknowledgement is
returned. This exercises the live router's normal early-push buffering.

### 5. The Mermaid fixture is larger than the inline phone viewport on both axes

Applies to: `DemoDesignFixtures.mermaidDiagram`

Four long parallel paths keep both axes larger than the inline phone viewport.
