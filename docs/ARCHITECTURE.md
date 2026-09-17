# Architecture

How the platform is put together, and why the seams are where they are.
`README.md` covers *what* it does; this covers *how*, at the level a new
engineer needs before changing something.

---

## 1. The shape of the problem

Clinical chart review is a human process with three awkward properties:

1. **The output must be defensible.** A reviewer has to be able to point
   at the sentence in the chart that justifies each answer. An LLM that
   returns a plausible answer with no traceable source is unusable for
   research, however accurate it is on average.
2. **The rubric is not known up front.** Methodologists discover what the
   rubric should say by applying a draft to real charts and watching where
   it breaks down. So the rubric has to be a versioned, editable artifact
   inside the loop — not a constant.
3. **The result must reproduce.** "We reviewed 400 charts with an LLM"
   is only a method if someone else can re-run it with the same rubric,
   prompt, and model and get the same answers.

Each maps onto a structural decision: the **faithfulness gate** (§4), the
**rubric-as-git-tree** (§5), and **exported packages + headless deploy**
(§6). Most of the rest of the design follows from these three.

---

## 2. Process topology

Three processes, coordinated through the filesystem rather than shared
memory.

```
┌──────────────────────────────────────────────────────────────────┐
│  Browser — React 18 + Tailwind + Radix                           │
│  Studio: AUTHOR · TRY · JUDGE · VALIDATE · PERFORMANCE · LOCK    │
└───────────────┬──────────────────────────────────────────────────┘
                │  REST  /api/v2/*      +      WebSocket (live run events)
┌───────────────▼──────────────────────────────────────────────────┐
│  Node — Express + ws  (server/)                                  │
│    route modules ── packages/*  (all platform logic)             │
│    packages/agent-provider-deepagents  ──┐                       │
│    packages/mcp-server-stdio  ←──────────┼── MCP over stdio      │
└──────────────────────────────────────────┼───────────────────────┘
                                           │ spawn (subprocess)
┌──────────────────────────────────────────▼───────────────────────┐
│  Python — deepagents sidecar (python/chart_review_deepagents)    │
│    langchain-mcp-adapters: one MCP session per patient run       │
│    model backend: Azure OpenAI | vLLM                            │
│    emits AgentEvent JSONL on stdout                              │
└──────────────────────────────────────────────────────────────────┘
```

**Why a separate Python process.** The agent runtime worth using for this
(`deepagents` + LangChain, and the model clients around it) is Python. The
platform — state machine, storage, review logic, UI — is TypeScript. Rather
than reimplement one in the other's language, the sidecar is a subprocess
with a deliberately narrow contract: it receives a JSON run spec on argv
and emits `AgentEvent` JSONL on stdout. stderr is diagnostics only; stdout
is reserved for the event stream. That contract is the whole interface, and
it's what makes the provider swappable (`packages/agent-provider` defines
`AgentProvider`; `agent-provider-deepagents` implements it).

**Why the filesystem as the coordination medium.** Run and review state
lives in `var/reviews/` and `var/runs/` as atomically-written JSON, not in
a database or in process memory. Three reasons: a run that crashes
mid-cohort leaves inspectable state; a reviewer's validated answers are
plain files a researcher can archive alongside a paper; and the headless
deploy runner reuses the exact same state code with no server running.
All of it goes through `packages/storage` (`atomicWriteJson`,
`readJsonOrNull<T>`) — write-temp-then-rename, so a killed process never
leaves a half-written state file.

**Why MCP for the tool boundary.** The agent's tools (`read_note`,
`set_field_assessment`, `select_evidence`, `read_structured_data`, …) are
served by `packages/mcp-server-stdio` over the Model Context Protocol. This
puts every tool call through one auditable TypeScript chokepoint — which is
precisely where the faithfulness gate sits (§4). The sidecar holds **one
MCP session per patient run**, not per tool call; a session per call adds
roughly a second of handshake latency to every tool invocation.

---

## 3. The review loop

A review is a loop, not a single pass. The methodologist tightens the
rubric until agent and human agree reliably, then freezes it.

```
AUTHOR ──▶ TRY ──▶ [JUDGE] ──▶ VALIDATE ──▶ PERFORMANCE
  ▲                                              │
  │                                        agreement stable?
  └──── REFINE ◀── no ────────────────────────── │
                                                yes
                                                 ▼
                                          LOCK ──▶ DEPLOY
```

| Phase | What happens | Package |
|---|---|---|
| **AUTHOR** | draft/edit the rubric | `workflow-phase-author`, `rubric` |
| **TRY** | agent drafts evidence-cited answers | `workflow-phase-try`, `pipeline-extract*` |
| **JUDGE** | optional LLM triage of disagreements | `workflow-phase-judge` |
| **VALIDATE** | human accepts / corrects / rejects | `workflow-phase-validate`, `domain-review` |
| **PERFORMANCE** | score agent vs. the human's gold | `workflow-phase-decide`, `eval-*`, `kappa` |
| **REFINE** | propose rubric edits, prove on held-out split | `server/lib/refine/`, `domain-proposal` |
| **LOCK / DEPLOY** | freeze rubric, run headless on a cohort | `workflow-phase-lock`, `deploy-runner` |

Phases are declared once in `client/src/ui/Workspace/phases.ts`
(`PHASE_DEFS`); the pill bar, router, headlines, and slugs all derive from
that array. Adding or reordering a phase is a one-place edit.

### Three task kinds, one loop

What differs across task kinds is the *shape of the question*, so the
extract stage and the scorer vary while the loop does not:

| Kind | Question | Extract stage | Scored by |
|---|---|---|---|
| Phenotype | *does the patient have X?* | `pipeline-extract` | per-field accuracy |
| Adherence | *did care follow the guideline?* | `pipeline-extract-adherence` | Cohen's κ (`eval-adherence-iaa`) |
| NER | *which span, which concept?* | `pipeline-extract-ner` | precision / recall / F1 (`eval-span-iaa`) |

---

## 4. The faithfulness gate

The one invariant everything else leans on: **the agent cannot cite
evidence that is not in the chart.**

Implemented in `packages/faithfulness` (`verifyEvidence`) and enforced at
the MCP boundary in `packages/mcp-server-stdio`, so every evidence-bearing
write passes through it before it can reach storage.

The contract is deliberately narrower than "did the model get the offsets
right":

1. Offsets resolve to the quote exactly, or modulo whitespace → **accept**.
2. Offsets are wrong but the quote *is* found in the note → **accept, with
   corrected offsets** written back so the UI highlights the true span.
3. The quote is not in the note at all → **reject**.

Step 2 is the load-bearing design decision. Models copy quoted text
faithfully but routinely miscount character offsets; rejecting a genuine
quote over arithmetic sends the agent into a cite → reject → re-cite loop
that burns the recursion limit without improving anything. Separating
*fabrication* (rejectable) from *bad arithmetic* (correctable) is what
makes the gate strict enough to trust and loose enough to converge.

Rejections are returned to the model as ordinary tool observations rather
than raised as exceptions — the sidecar wraps MCP tools so a gate rejection
is something the agent can respond to by re-quoting, instead of an error
that aborts the patient. The gate is therefore not just a filter; it is a
feedback signal that drives the agent toward real quotes.

**If you add a write tool that carries note evidence, it must route through
`verifyEvidence`.** There is no second enforcement point.

---

## 5. The rubric is a git tree

Rubrics live under `.claude/skills/chart-review-<task-id>/` as
`SKILL.md` + `meta.yaml` + `references/criteria/*.md`, resolved by
`guidelinesRoot()` at `<PLATFORM_ROOT>/.claude/skills`.

This is one tree with a deliberate tracked/ignored split:

- `references/` and promoted `versions/` are **git-tracked** — the rubric is
  reviewable in a diff and citable at a SHA.
- `sessions/<sid>/rubric/` (per-session forks) and `pilots/` are
  **git-ignored** — per-machine runtime state that rebuilds by use.

Storing the rubric as files rather than database rows is what makes "the
rubric locked at a git SHA you can cite" literally true: a methods section
can name a commit, and a reader can read the exact rubric text.

### Self-refinement

When agent and reviewer disagree, `server/lib/refine/` runs an error
analysis — *rubric gap*, *genuine ambiguity*, or *model slip*? Only a
genuine gap becomes a proposed rule; a model slip never does. Each
proposal is then **validated on a held-out split** (cases fixed vs. cases
regressed) and surfaced as a card showing the failing example, the
proposed edit, and the evidence for it.

Nothing is applied automatically. A human applies or discards, every
applied edit is versioned (`rubric-versions`, `version-archive`), and
every edit is revertable. The point is that the rubric changes *because* a
human and an agent disagreed, and the reason is on the record.

---

## 6. Reproducibility and deployment

Once a task agrees reliably with the reviewer, it is exported as a
**package** — rubric, prompt, model identity, and validation stats
together — and that package runs headlessly:

```sh
npm run deploy -- --package var/exports/<task>/<exportId> \
                  --data-dir /path/to/cohort --out /path/to/results
```

`packages/deploy-runner` walks `<patient_id>/notes/*.txt`, runs the same
agent through the same MCP tools and the same faithfulness gate as the UI
path, and writes per-patient JSON answers, a per-patient CSV, and a
manifest recording the model and pass/fail counts. It warns when the
configured model differs from the one the package was validated on —
silently scoring a cohort with a different model than the validation run
would invalidate the result.

The container (`Dockerfile`) builds Node 20 + Python 3.11 into one image,
bakes the app wiring as `ENV`, and redirects every mutable root to `/data`
so run state lands on a mounted volume and never in an image layer. CI
builds the image and boots it against `/api/v2/healthz` on every change.

---

## 7. Package map

`packages/` is an npm-workspace monorepo of ~70 packages, imported as
`@chart-review/<name>`. Grouped by prefix:

| Prefix | Responsibility |
|---|---|
| `agent-*` | agent invocation: `-core`, `-compose`, `-provider`, `-provider-deepagents`, `-specs` |
| `pipeline-*` | the staged pipeline: `-clarify`, `-form-gen`, `-discover`, `-extract`(`-ner`/`-pernote`/`-adherence`), `-validate`, `-correct-log` |
| `workflow-*` | phase orchestration: `-chart-review`, `-lit-extract`, `-phase-*`, `-phases` |
| `domain-*` | review domain model: `-review`, `-iter`, `-cohort`, `-issue`, `-proposal`, `-bundle` |
| `mcp-*` | tool surface: `mcp-core`(`-ner`/`-adherence`), `mcp-server-stdio`, `mcp-server-anthropic` |
| `eval-*`, `kappa` | scoring: span IAA, adherence IAA, Cohen's κ, `contract-eval` |
| infra/core | `storage`, `faithfulness`, `fs-atomic`, `model-config`, `tasks`, `rubric`, `rubric-versions`, `ontology`, `patients`, `audit-trail`, `deploy-runner`, … |

### The four seams to use

| Seam | Where | Use when |
|---|---|---|
| Agent invocation | `packages/agent-provider-deepagents` | spawning the sidecar — go through `runAgent()`, never import the sidecar from server code |
| Workflow phases | `client/src/ui/Workspace/phases.ts` | adding/reordering a Studio phase — edit `PHASE_DEFS` only |
| Filesystem I/O | `packages/storage` | reading/writing state — `atomicWriteJson`, `readJsonOrNull<T>` |
| MCP tools | `packages/mcp-server-stdio` | adding a tool the agent can call — and routing its evidence through the gate |

---

## 8. Testing

| Layer | Runner | Command |
|---|---|---|
| TS unit + React component (~813 tests) | Vitest + Testing Library | `npm test` |
| Python sidecar (63 tests) | pytest | `cd python && pytest` |
| Types across all workspace packages | tsc | `npm run typecheck` |
| Studio UI end-to-end | Playwright | `npm run test:ui` |

The unit suites are hermetic — no model backend, no network. Sidecar tests
drive the agent loop with a scripted fake `astream` rather than a live
model, so the retry/commit logic is tested deterministically. CI runs
typecheck, both unit suites, the client build, and the container boot on
every push and pull request; Playwright is run locally against a live
Studio.

---

## 9. Known rough edges

Honest notes for anyone reading the code:

- `packages/mcp-server-anthropic` is still wired, but only for its
  `buildMcpServersConfig()` helper (which builds the *stdio subprocess*
  config). Its in-process Anthropic-SDK server path is dead code, since
  deepagents always uses subprocess transport.
- The faithfulness gate has no Python-side parity copy. TypeScript is the
  single enforcement point — deliberate, but it means a future non-MCP
  write path would bypass it.
- `.gitignore` contains `/workspace/` **anchored**. The unanchored form
  silently drops `client/src/ui/Workspace/` on case-insensitive
  filesystems. Don't unanchor it.
- Some package descriptions and loader comments still reference a retired
  `.agents/skills` tree. `.claude/skills` is the only rubric tree; that
  text is stale but harmless (`packages/patients` still accepts either as
  a `PLATFORM_ROOT` marker).
- The client builds as a single ~827 kB chunk. It is not code-split.
