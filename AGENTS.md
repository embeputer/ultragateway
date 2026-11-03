# Agent instructions (ultragateway)

Cursor IDE agents and cloud agents should behave as an **autonomous engineer**: take each task from understanding through verification and shipping—do not stop at plans or partial diffs.

## Autonomous workflow

1. **Own end to end** — Understand the ask, sketch a brief plan, implement, verify, ship. Keep iterating (long runs are fine) until the task is actually done.
2. **Decide without blocking** — Do not pause for reversible choices; make reasonable assumptions and record them in the PR. Only ask the user for: secrets/credentials, destructive or irreversible actions (deleting data, force-pushing shared branches, production deploys, spending money), or genuinely ambiguous product decisions.
3. **Verify for real** — Use the commands in [Project facts](#project-facts). Install deps, run builds/checks that apply on your platform, fix failures, and re-run until green. For UI/menu bar changes, build on macOS and exercise the app when possible.
4. **Tests** — This repo has no automated test suite. When you change behavior, add tests if you introduce a test harness; otherwise rely on build/syntax checks and manual verification described below.
5. **Ship** — Open a PR with what changed, why, how you verified, assumptions, and follow-ups. Watch CI and fix failures until checks pass.
6. **Leave code clean** — No debug leftovers or commented-out code; match existing bash/Swift/Node style in the tree.
7. **Final report** — Concise summary, verification evidence, and anything still open.

## Project facts

Verified from this repository (Nov 2026).

| | |
|---|---|
| **What** | macOS background service: Supergateway + **cua-driver** MCP over SSE, exposed via tunnel for remote clients (e.g. Poke). Optional menu bar app (`ultragateway.app`). |
| **Stack** | Bash (`install.sh`, `scripts/`), Swift 5.9 menu bar (`macos-app/`), small Node ESM MCP bundle (`native-mcp/`), Python 3 helper (`scripts/generate-appcast.py`). |
| **Key paths** | `LaunchAgents/` — plist templates; `scripts/` — gateway, tunnel, auto-update; `macos-app/` — Swift package + `build.sh`; `ultragateway.app/` — app bundle; `native-mcp/` — composite MCP server; `config.env.example` — config reference. |
| **Primary docs** | `README.md`, `POKE.md` |

### Setup

```bash
# Node deps for native-mcp (also done by install.sh into Application Support)
npm install --prefix native-mcp --no-save --no-package-lock
```

Full local install is macOS-only: `chmod +x install.sh uninstall.sh scripts/*.sh macos-app/build.sh && ./install.sh`

### Build

```bash
# macOS + Xcode Command Line Tools (swift) required
./macos-app/build.sh              # native arch
./macos-app/build.sh --universal  # arm64 + x86_64 (matches CI)
```

GitHub Actions (`.github/workflows/release.yml`) runs `./macos-app/build.sh --universal` on `macos-15` and packages releases (Sparkle signing needs `SPARKLE_PRIVATE_KEY` secret).

### Lint / typecheck / tests

- **No** root `package.json` scripts, Makefile, Cargo.toml, or pyproject test/lint targets.
- **No** automated test files in the repo.
- **Shell syntax** (works on Linux/macOS agents):

```bash
bash -n install.sh uninstall.sh macos-app/build.sh
for f in scripts/*.sh; do bash -n "$f"; done
```

- **`scripts/generate-appcast.py`** — run only in release context with env vars documented in the script header (used by CI).

Cloud/Linux agents cannot compile the Swift app; still validate shell/Node/Python edits with `bash -n` and `npm install` as above, and note macOS build verification in the PR.
