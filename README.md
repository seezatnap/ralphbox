# Ralphbox

> **EXPERIMENTAL SOFTWARE - USE AT YOUR OWN RISK**
>
> This tool runs AI agents with elevated permissions in an automated loop. It can and will modify files, execute commands, and make changes to your system. Running this outside of a sandbox may result in unintended modifications, data loss, or other damage. The authors assume no responsibility for any consequences of using this software.

![ralph](https://github.com/user-attachments/assets/e4792d25-6dfe-453e-b1d2-da586f31d343)

An alternating loop runner that orchestrates interactions between Claude and Codex in an iterative workflow, presenting their responses through a split-pane terminal UI.

## Overview

Ralphbox consists of two main scripts:

- **ralph.sh** - A loop runner that alternates between Claude and Codex across multiple iterations, with real-time split-pane terminal display and JSON logging
- **init.sh** - A sandbox initialization script that sets up a secure Docker-based environment using Lima

## Important: Always Use the Sandbox

**Do not run `ralph.sh` directly on your host machine.** The script runs AI agents with dangerous permission flags that allow them to execute arbitrary commands and modify files without confirmation. Running it outside of a sandbox puts your system at risk.

Always use `init.sh` to create an isolated Docker environment first:

```bash
# Set up the sandbox with your project folders
./init.sh ~/Sites/myproject

# The sandbox isolates all AI operations in a container
```

## Requirements

- Lima (`brew install lima`)
- Docker
- Python 3
- [Claude CLI](https://github.com/anthropics/claude-code) (installed and authenticated)
- [Codex CLI](https://github.com/openai/codex) (installed and authenticated)
- Bash, git, jq

## Usage

### 1. Create the Sandbox

```bash
# Basic setup with one project folder
./init.sh ~/Sites/myproject

# With port forwarding for dev servers
./init.sh --ports 3000,5173 ~/Sites/myproject

# Multiple project folders
./init.sh ~/Sites/project1 ~/Sites/project2
```

Inside the container, your folders are mounted at `/work/dir0`, `/work/dir1`, etc.

### 2. Run the Loop (Inside Sandbox)

Once inside the sandbox container:

```bash
# Initialize a new loop project
ralph --init

# Edit the prompt
nano loop/prompt.md

# Run the loop (default: 50 iterations)
ralph

# Run with custom parameters
ralph my-prompt.md 10          # 10 iterations with custom prompt
ralph --start codex            # Start with Codex instead of Claude
```

## Configuration

Environment variables for `ralph.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ITERATION_COUNT` | 50 | Number of iterations |
| `PROMPT_FILE` | loop/prompt.md | Path to prompt file |
| `LOG_FILE` | loop/loop.log | Log file path |
| `ROTATE_LOG` | 1 | Rotate existing logs |
| `CONTINUE_ON_ERROR` | 0 | Set 1 to skip failed iterations |
| `NO_UI` | 0 | Disable TUI |
| `START_ENGINE` | claude | Start with "claude" or "codex" |
| `CODEX_MODEL` | gpt-5.2-codex | Codex model to use |

## Terminal UI

The split-pane interface shows:

- **Status bar** (top): Current iteration, engine, status, elapsed time
- **Top pane**: Filtered important status lines
- **Bottom pane**: Full detailed output

Status icons: `🔄` running, `✅` ok, `❌` fail, `🚀` starting
Engine icons: `🟣` Claude, `🟢` Codex

## License

MIT
