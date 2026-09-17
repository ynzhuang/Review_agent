# Contributing

Thanks for looking at the code. This guide covers getting a working dev
environment, the conventions the codebase actually follows, and the few
invariants that are not negotiable.

Read `docs/ARCHITECTURE.md` first if you are changing anything structural.

---

## Development setup

**Prerequisites:** Node.js ≥ 20, Python ≥ 3.11, and a model backend
(Azure OpenAI or a vLLM endpoint) if you want to run the agent.

```sh
# 1. JS workspace (70+ packages, one lockfile)
npm ci

# 2. Python sidecar
cd python
python3 -m venv .venv          # or: uv venv .venv --python 3.11
./.venv/bin/pip install -e ".[dev]"
cd ..

# 3. Configure
cp .env.example .env           # set AGENT_PROVIDER, the model backend,
                               # and CHART_REVIEW_PLATFORM_ROOT

# 4. Run — Express on :3002, Vite on :5174
npm run dev
```

Open <http://localhost:5174>, sign in with any reviewer ID, and pick the
`cancer-diagnosis` task to walk the loop end to end.

**You do not need a model backend to develop most of the platform.** The
server boots and `/api/v2/healthz` goes green without one, and the whole
unit suite is hermetic. You only need a live backend to exercise TRY.

### Common commands

| Command | What it does |
|---|---|
| `make help` | list every target |
| `npm run dev` | server + client with hot reload |
| `npm test` | Vitest — TS unit + React component tests |
| `npm run typecheck` | tsc across all workspace packages |
| `npm run build:client` | production client bundle |
| `npm run test:ui` | Playwright against a running Studio |
| `cd python && pytest` | sidecar tests |
| `make check` | typecheck + both unit suites + build — what CI runs |

Run `make check` before pushing. It is the same set of gates as CI, so a
green local run means a green pipeline.

---

## Invariants

These are enforced by review, and breaking one is a bug regardless of what
else the change does.

### 1. Evidence goes through the faithfulness gate

Any new write tool that carries note evidence **must** route it through
`verifyEvidence` from `@chart-review/faithfulness`, the same way the
existing tools in `packages/mcp-server-stdio` do. There is one enforcement
point and no second one. A write path that bypasses it silently
reintroduces the possibility of fabricated quotes, which is the one thing
this platform promises cannot happen.

### 2. State writes go through `packages/storage`

Use `atomicWriteJson` and `readJsonOrNull<T>`. Never `fs.writeFile` a state
file directly. The atomic write (temp + rename) is what keeps a killed
process from leaving half-written state behind, and that guarantee is
relied on by the cohort runner.

### 3. Never commit PHI or secrets

Real patient directories are `patient_real_*` and are gitignored;
synthetic fixtures are `patient_fake_*` and are tracked. `.env` is
gitignored — document new variables in `.env.example` with placeholder
values. See `SECURITY.md` for the full boundary, including the
`CHART_REVIEW_PHI_MODEL` routing rule.

### 4. Don't unanchor `/workspace/` in `.gitignore`

The anchored form is deliberate. The unanchored form silently drops
`client/src/ui/Workspace/` on case-insensitive filesystems.

---

## Conventions

**Branches.** `feat/…`, `fix/…`, `refactor/…`, `docs/…`, `test/…`,
`chore/…`.

**Commits.** Conventional commits — `<type>(<scope>): <summary>`, summary
in the imperative mood and under ~72 characters. Use the body for
motivation and context: what was wrong, why this fixes it. The diff shows
*what* changed; the message should explain *why*.

```
fix(faithfulness): accept quotes whose offsets differ only by whitespace

Agents copy quoted text faithfully but miscount offsets, so a strict
offset match sent the run into a cite→reject→re-cite loop that burned
the recursion limit. Locate-and-correct instead, and reject only when
the quote is genuinely absent.
```

**Merges.** `--no-ff`, so a feature keeps its own history.

**Adding a workspace package.** Create `packages/<name>/` with a
`package.json` named `@chart-review/<name>`, follow the prefix convention
(`agent-`, `pipeline-`, `workflow-`, `domain-`, `mcp-`, `eval-`), and
import it by that name — never by relative path across package boundaries.

---

## Testing

Every behavioural change needs a test. Match the existing style — the
suites are small, fast, and hermetic, and they should stay that way.

- **No network, no model backend** in unit tests. The sidecar tests script
  a fake `astream` generator rather than calling a model; do the same for
  new agent-loop logic.
- **Test the boundary, not the mock.** Faithfulness, PHI routing, and
  storage atomicity have direct tests — see
  `packages/faithfulness/`, `packages/infra-batch-run/src/phi-model.test.ts`,
  and `packages/storage/`. Extend those rather than mocking around them.
- Place tests next to the code as `*.test.ts` / `*.test.tsx`.
- Playwright specs live in `e2e/` and run against a live Studio, so they
  are not part of the CI gate — run them locally when touching
  `client/src/ui/Workspace/`.

---

## Pull requests

CI must be green: typecheck, TS unit tests, Python tests, client build,
and the container build + healthcheck boot. Then:

1. Say what changed and why. Link the issue if there is one.
2. Call out anything touching an invariant above, explicitly.
3. Note if you changed `.env.example`, the rubric tree, or a storage
   layout — those affect existing deployments.
4. Keep the diff scoped. A refactor and a behaviour change in one PR is
   two reviews jammed into one.
