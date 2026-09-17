## What changed

<!-- One or two sentences. The diff shows what; say why. -->

## Why

<!-- What was wrong, or what this enables. Link the issue if there is one. -->

## How it was verified

- [ ] `make check` passes locally (typecheck · TS tests · Python tests · build)
- [ ] Added or updated tests covering the change
- [ ] Ran `npm run test:ui` (only if `client/src/ui/Workspace/` changed)

## Invariants

Tick anything this PR touches, and explain below — see CONTRIBUTING.md.

- [ ] Adds or changes a write tool that carries note evidence
      (must route through `verifyEvidence`)
- [ ] Changes how state is read or written
      (must go through `packages/storage`)
- [ ] Changes `.env.example`, the rubric tree, or a storage layout
      (affects existing deployments)
- [ ] None of the above

## Notes for the reviewer

<!-- Anything surprising, deferred, or worth a second opinion. -->
