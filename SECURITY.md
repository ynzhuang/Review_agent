# Security & PHI Handling

This platform reads clinical charts. Two classes of sensitive data pass
through it — **protected health information (PHI)** and **model API
credentials** — and the controls for each are different. This document
states where the boundaries are and how they are enforced in code, so a
reviewer can check the claims rather than take them on trust.

## What is in this repository

Everything in `corpus/` is **synthetic**. Patient directories are named
`patient_fake_*` and were generated for development and testing. There is
no PHI in this repository and none in its history.

## Keeping real patient data out of git

Real charts live outside version control. The boundary is a naming
convention enforced by `.gitignore`:

| Pattern | Meaning |
|---|---|
| `patient_fake_*` | synthetic fixture — **tracked** |
| `patient_real_*` | real chart — **ignored**, never committed |
| `patient_private_*`, `patient_phi_*`, `patient_sample_*` | legacy real-data prefixes — **ignored** |

Two derived artifacts are ignored for the same reason:

- `corpus/index.json` — the live corpus index enumerates real patient IDs.
  Only the synthetic seed, `corpus/index.demo.bak.json`, is tracked.
- `.claude/skills/*/sessions/`, `.claude/skills/*/pilots/` — per-session
  runtime state embeds cohort patient IDs. The rubric itself
  (`SKILL.md`, `meta.yaml`, `references/`) is tracked; the runtime state
  under it is not.

All mutable run state (`var/reviews/`, `var/runs/`, `var/exports/`, …) is
ignored wholesale and, in the container, is redirected to a mounted
volume at `/data` so nothing PHI-bearing is ever written into the image
layer.

### Before you point this at real data

1. Name the directories `patient_real_*`. The prefix is the control.
2. Run `git status` and confirm they do not appear.
3. Set `CHART_REVIEW_PHI_MODEL` (see below) **before** the first run.

## The PHI model boundary

Sending a chart to a model endpoint that is not covered by a business
associate agreement (BAA) is the most consequential mistake this system
can make, so it is not left to configuration discipline.

Set `CHART_REVIEW_PHI_MODEL` to an in-BAA deployment — a `gpt-4o`
deployment on your own Azure OpenAI resource, or a genuinely
self-hosted vLLM endpoint. PHI-flagged patients are routed to that model
regardless of the session's default model.

**If `CHART_REVIEW_PHI_MODEL` is unset and a PHI-flagged patient is
submitted, the run fails loudly rather than falling back to the default
model.** Refusing to run is the safe failure mode; silently using the
default would put a chart outside the BAA boundary. This behaviour is
covered by `packages/infra-batch-run/src/phi-model.test.ts`.

The deploy runner applies the same check on cohort runs and warns when
the configured model differs from the one the exported package was
validated against.

## Credentials

- **No secrets are committed.** `.env` and `.env.*` are gitignored;
  `.env.example` documents the contract with placeholder values only.
- `.dockerignore` excludes `.env` from the build context, so keys cannot
  be baked into an image layer.
- Provide secrets at runtime — `docker run --env-file .env`, or your
  orchestrator's secret mechanism. Do not pass them as `--build-arg`.
- The vendored NER proxy (`vendor/bso-ad-sdk/`) reads its key from its own
  `.env`, also ignored.
- Rotate any key that has ever appeared in a shell history, a log, or a
  screen share.

## Model-output integrity

A distinct class of risk: the agent asserting something the chart does not
say. The control is the **faithfulness gate** at the MCP tool boundary
(`packages/faithfulness`, enforced in `packages/mcp-server-stdio`).

Every write that cites note evidence is checked against the note's actual
bytes before it is accepted. If the quote is present but the character
offsets are off, the gate auto-corrects the offsets. If the quote is
**not** present in the note, the write is rejected and the error is
returned to the model as an observation so it can re-quote.

The consequence for a reviewer: a quote rendered in the UI was found in
the chart. Any new write tool that carries note evidence must route
through the same gate — see the contributing guide.

## Threat model — what this does *not* do

Stated plainly, because a research platform overclaiming here would be
worse than saying nothing:

- **No authentication hardening.** Sign-in takes any reviewer ID and is an
  attribution mechanism, not an access control. Do not expose an instance
  to an untrusted network. Put it behind your institution's SSO/VPN.
- **No encryption at rest.** Run state is plain JSON on disk. Use an
  encrypted volume if it will hold real data.
- **No audit-grade tamper protection.** `packages/audit-trail` records
  what happened for research reproducibility; it is not a
  cryptographically sealed log.
- **No multi-tenant isolation.** One deployment serves one team over one
  corpus root.

## Reporting a vulnerability

Open a GitHub issue for anything non-sensitive. For a finding that would
expose patient data or credentials, contact the maintainer directly
rather than filing publicly, and please include reproduction steps and
the commit SHA.
