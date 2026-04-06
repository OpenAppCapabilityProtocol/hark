# OACP v0.4 Tool-Calling Runtime

Status: Implemented in Hark

This note describes the `v0.4` runtime milestone for Hark.

`v0.4` is not a new manifest format for third-party apps.
It changes how Hark consumes discovered OACP capabilities with the local model.

## Summary

Before `v0.4`, Hark mostly used:

- metadata-driven ranking
- a plain-text shortlist prompt
- a plain-text model response containing an `actionKey`
- a second plain-text parameter-extraction step

With `v0.4`, Hark now primarily uses:

- discovered OACP capabilities
- metadata-driven shortlist ranking
- dynamic runtime `Tool` definitions built from discovered OACP actions
- native local-model tool calling for action selection and initial structured arguments
- deterministic and schema-driven fallback when tool calling fails or underfills parameters

## What Changed In Hark

Hark now:

1. discovers OACP apps
2. builds a runtime action catalog
3. ranks likely actions from metadata
4. turns the shortlist into local-model tools
5. asks the model to call exactly one tool
6. validates and coerces returned arguments against OACP-derived parameter metadata
7. dispatches the selected OACP action

This keeps the assistant runtime generic while reducing plain-text parsing fragility.

## Two-Tier Context Optimization

The original v0.4 design sent all tool metadata in a single model call:
aliases, examples, entity snapshots, and disambiguation hints per tool.
For a typical shortlist this produced ~3,350 tokens of tool context —
well beyond the ~2K effective context window of FunctionGemma 270M.

The two-tier optimization splits tool calling into two focused steps
so that each stays within the model's context budget.

### Tier 1 — Lean Action Selection (~500 tokens)

The model receives only:

- tool name
- one-line description
- parameter names and types (no examples, no aliases, no hints)

This is enough for the model to pick the right tool from the shortlist.

### Tier 2 — Parameter Extraction (~400 tokens)

After a tool is selected, a second call sends only:

- the action description
- full parameter definitions for that single tool

Because it covers one tool instead of the whole shortlist,
the prompt stays small and focused.

### Deterministic-First Resolution

When the heuristic metadata scoring produces a clear winner
(high confidence, large gap to the second-best candidate),
the model call is skipped entirely.
Tier 2 still runs for parameter extraction,
but Tier 1 is replaced by a zero-cost deterministic pick.

This means the model is only consulted when the shortlist is genuinely ambiguous.

### Result

- Every model call stays within the ~2K context budget of FunctionGemma 270M.
- Clear matches resolve faster because the model is bypassed.
- Ambiguous matches still get model-quality selection, just with a leaner prompt.
- `OACP.md` context is reserved for future BYOK cloud models with larger context windows;
  local models rely entirely on `oacp.json` metadata (aliases, examples, keywords).

## What Did Not Change For App Developers

Third-party OACP app developers still only need to provide:

- `oacp.json`
- optional `OACP.md`
- exported discovery provider
- exported Android execution surface

They do not need to:

- add Hark-specific code
- register tools manually in Hark
- understand Hark's Dart resolver internals

The runtime tools are generated dynamically from discovered OACP metadata.

## Why This Matters

Compared to plain-text action selection, native tool calling gives Hark:

- a structured action-selection response
- structured initial arguments
- less brittle parsing
- better alignment with richer OACP metadata
- a cleaner path for future stronger local models

This is especially important as more third-party OACP apps are installed at once.

## Relationship To Other Versions

- `v0.2` improved OACP metadata for routing quality
- `v0.3` improved protocol depth, entities, confirmation semantics, and generic resolution
- `v0.4` improves Hark's local-model runtime by making discovered OACP capabilities first-class tools
- `v0.4` two-tier optimization makes tool calling viable on FunctionGemma 270M's limited context

So:

- `v0.2` and `v0.3` are mostly about protocol expressiveness
- `v0.4` is mostly about runtime execution architecture

## Current Shape

The `v0.4` runtime intentionally keeps:

- metadata-driven shortlist ranking
- deterministic/schema-aware fallback
- generic parameter coercion

It does not assume the local model is perfect.

The design goal is:

- let OACP metadata do as much work as possible
- let the model choose among discovered runtime tools
- keep Hark generic enough that new apps do not require app-specific patches
- stay within the context budget of small on-device models today,
  scale to larger BYOK models tomorrow
