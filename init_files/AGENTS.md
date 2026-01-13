This is the operational guide for working in an unfamiliar repository.
Goal: discover how to build, test, lint, and run validations, then use those gates every iteration.

## Golden rules
- Do not assume the stack. Discover it from files and existing automation.
- Prefer existing scripts and tools already used by the repository.
- Do not add new dependencies unless required by the current task.
- Do not commit secrets. Do not print tokens. Do not modify lockfiles unless necessary.

## First 5 minutes (orientation)
1) Inspect the root:
   - ls
   - git status
2) Read the obvious docs if present:
   - README*, CONTRIBUTING*, docs/*, DEVELOPMENT*, RUNBOOK*
3) Identify automation that defines “truth”:
   - .github/workflows/*
   - Makefile
   - package.json scripts
   - pyproject.toml / tox.ini / noxfile.py
   - go.mod
   - Cargo.toml
   - composer.json
   - build.gradle / pom.xml
   - justfile / taskfile.yml

## Determine the primary command entrypoint (pick ONE)
Use the first that exists:
- Makefile: `make help` (or `make -n <target>` to preview)
- Justfile: `just --list`
- Taskfile: `task -l`
- Node: `cat package.json` and use `npm|yarn|pnpm run <script>`
- Python: prefer `uv` or `poetry` if configured; otherwise `python -m ...`
- Go: `go test ./...` and `go build ./...`
- Rust: `cargo test` and `cargo build`

## Install dependencies (only if required)
- Node: use the lockfile’s package manager:
  - pnpm-lock.yaml → `pnpm install`
  - yarn.lock → `yarn install`
  - package-lock.json → `npm ci` (or `npm install` if ci is unavailable)
- Python:
  - uv: `uv sync`
  - poetry: `poetry install`
  - pip: `python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`
- Other ecosystems: follow repository docs or workflow files.

## Fast validation gate (run before every commit)
Run the repository’s equivalent of:
- Lint
- Type check (if applicable)
- Unit tests (targeted when possible)

Find the exact commands by looking in (in order):
1) CI workflows
2) Makefile / task runner
3) package.json scripts / tool config files
If no explicit commands exist, default to ecosystem norms (examples above).

## Full validation gate (run when relevant)
Run when you touch build, packaging, or deployment paths:
- Production build (or compile)
- Integration tests / end-to-end tests (if present)

## Targeted testing (preferred)
- Run the smallest test set that proves the change.
- If the repository supports test selection by path or pattern, use it.

## If something fails
- Read the error carefully and fix the smallest change that makes the gate pass.
- Re-run the failing command.
- If requirements are unclear or the plan is stale, switch to planning and regenerate the plan.

## Commit discipline
- One task per commit.
- Commit only after the Fast validation gate passes.
- Commit message should explain what changed and why (brief, factual).

Once you have completed ONE task, stop. Only try to accomplish a singular task.