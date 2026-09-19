# Routing policy proposal

確認日: 2026-09-18。これは MVP 前の policy proposal である。runtime facts と限界は [research.md](research.md)、構成は [architecture.md](architecture.md) を正本にする。

## Priority order

Every turn resolves in this order:

1. **Explicit override** — one-shot `/route <route>` wins for the next task; session `/route pin <route>` wins until reset.
2. **Valid session pin** — retain it when its model/auth/thinking capability remains valid.
3. **Deterministic hard gates** — security-sensitive changes, production migrations, destructive commands, or explicit “deep investigation” never receive a LIGHT route. They select HARD/VERY_HARD or require confirmation according to existing safeguards.
4. **Availability and effort validation** — a candidate must be in the current model scope, authenticated, text/image-capable as needed, and support the requested effective thinking level.
5. **Budget state** — MVP uses `unknown` plus optional local thresholds; it must not claim subscription quota visibility.
6. **Jev classification** — only when no higher-priority decision applies.
7. **Fallback** — choose NORMAL, or preserve the current Pi selection if NORMAL is invalid.

Jev cannot authorize an action, remove an existing confirmation, or override a deterministic safety gate.

## Initial classes

| Class | Typical task shape | Proposed effort | Policy outcome |
|---|---|---:|---|
| LIGHT | search, formatting, docs-only edit, simple test/type fix | low | lowest calibrated available Codex route |
| NORMAL | bounded feature, several-file edit, routine tests/refactor | medium | current baseline route |
| HARD | ambiguous bug, broad refactor, architecture, sensitive code | high | strong configured Codex route |
| VERY_HARD | migration, security-impacting change, difficult diagnosis with high blast radius | highest supported | strongest configured Codex route plus existing confirmation/review rules |

These categories are examples for Jev criteria, not literal keyword routing. The policy must start conservatively: ambiguous requests map to NORMAL; a deterministic hard gate maps upward.

## Jev question shape

Use one Choice question with `light`, `normal`, `hard`, `very_hard`, and `unclear`; optionally independent Nouls for `security_sensitive`, `migration`, and `ambiguous_requirements`. Supply only the redacted bounded synopsis.

Use `unclear` or low confidence as NORMAL. Confidence is distribution concentration, not evidence that an expensive route is warranted. Record answer probabilities if returned, but do not select on a single arbitrary global threshold before calibration.

## Candidate models and calibration

The present Pi catalog contains `openai-codex` models only. The enabled scope presently includes `gpt-5.6-terra`, `gpt-6-astra`, `gpt-5.6-sol`, and `gpt-5.6-luna`; default is Terra at medium. Pi runtime must determine which thinking levels each candidate actually supports.

Do not encode assertions such as “Astra is always strongest” or “Sol is cheapest.” Define route candidates in configuration, test them on a labeled task set, then assign names. The first practical baseline should preserve Terra/medium as NORMAL, so a router failure does not make normal work weaker.

`gpt-5.3-codex-spark` and `gpt-5.4-mini` are visible in the catalog but outside the current enabled scope. They cannot be automatic candidates until the user intentionally adds them to scope and validates their capability/quality.

## Overrides and UX

Proposed extension commands:

- `/route status` — current pin, effective model/thinking, budget state, and latest decision.
- `/route auto` — clear user pin; next eligible prompt gets one routing decision.
- `/route pin light|normal|hard|very-hard` — pin a validated class for this session.
- `/route once light|normal|hard|very-hard` — affects only the next eligible prompt.
- `/route reset` — clear pin and pending one-shot override.
- `/route explain` — show the latest recorded reason, never hidden prompt text.

The built-in `/model` and `/thinking` remain authoritative manual controls. On a manual model/thinking change, the extension records `manual_override` and does not silently reverse it. This is more predictable than attempting to infer an override from free text.

## Budget policy

No public API was confirmed for an individual ChatGPT/Codex subscription's remaining five-hour/weekly allowance or reset time. Therefore MVP policy has only these valid states:

- `unknown` — default for subscription quota.
- `manual` — user-configured soft budget/reset information.
- `estimated` — local provider-reported token/request rolling totals; labelled non-authoritative.

Budget policy may nudge an unpinned, low-risk task down only when a configured local estimate crosses a soft threshold. It must never interrupt a user override or downgrade a hard-gated task. A future API-key provider fallback can implement the same interface without changing routing semantics.
