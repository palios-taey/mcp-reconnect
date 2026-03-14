# mcp-reconnect

Automated MCP server reconnection for Claude Code sessions running in tmux.

Claude Code has no programmatic API for MCP reconnect — the only way is through the interactive `/mcp` menu. This tool automates that entire sequence via `tmux send-keys`, handling single machines, multi-session environments, and remote hosts over SSH.

## The Problem

When you deploy new MCP server code or restart server processes, every active Claude Code session loses its MCP connection. Each session must manually navigate `/mcp` → Reconnect to recover. With multiple sessions across multiple machines, this becomes a significant interruption.

## The Solution

`mcp-reconnect` drives the `/mcp` menu programmatically through tmux:

```
Escape        →  stop active generation
/mcp + Enter  →  submit the /mcp slash command
Enter         →  enter the menu
Down + Enter  →  select "Reconnect" (2nd option)
<prompt>      →  continuation message so Claude resumes work
```

## Install

### Standalone script

```bash
git clone https://github.com/palios-taey/mcp-reconnect.git
cd mcp-reconnect
sudo make install
```

This installs `mcp-reconnect` to `/usr/local/bin`. To customize:

```bash
sudo make install PREFIX=/opt/local
```

### Claude Code plugin

```
/plugin marketplace add palios-taey/mcp-reconnect
/plugin install mcp-reconnect@mcp-reconnect
```

Or test locally:

```bash
claude --plugin-dir ./path/to/mcp-reconnect
```

## Usage

```bash
# Reconnect all Claude Code tmux sessions on this machine
mcp-reconnect

# Reconnect specific sessions by name
mcp-reconnect weaver architect

# Reconnect all sessions on a remote host
mcp-reconnect --remote myserver

# Reconnect a specific session on a remote host
mcp-reconnect --remote myserver weaver

# Preview what would happen (no keys sent)
mcp-reconnect --dry-run
```

### Calling from within Claude Code

When `mcp-reconnect` is called from a Claude Code session itself (e.g., during a deploy script), it must run detached with a delay — otherwise the Escape keystroke kills the calling session before the bash tool returns.

```bash
nohup mcp-reconnect --delay 10 &>/dev/null & disown
```

The `--delay` flag waits N seconds before sending any keystrokes, giving the calling session time to finish its tool execution.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--remote HOST` | — | Target a remote machine via SSH |
| `--delay N` | `0` | Wait N seconds before starting (for detached use) |
| `--settle-esc N` | `5` | Seconds to wait after Escape |
| `--settle-mcp N` | `2` | Seconds to wait after `/mcp` submit |
| `--settle-select N` | `5` | Seconds to wait after selecting Reconnect |
| `--message MSG` | *(built-in)* | Override the continuation prompt |
| `--dry-run` | — | Show actions without sending keys |
| `--help` | — | Show usage information |

## Requirements

- **tmux** — Claude Code sessions must be running inside tmux
- **bash** ≥ 4.0 (for `mapfile` and associative arrays)
- **ssh** — for `--remote` mode, with key-based authentication configured

No other dependencies. No Redis, no Python, no Node.js.

## Design Decisions

These constraints were discovered through extensive production testing:

### Parallel local, sequential remote

Local sessions run in parallel — each targets a different tmux pane, so there's no contention. Remote sessions run sequentially over SSH to avoid connection multiplexing issues.

### Conservative settle times

The default timings (5s after Escape, 2s after `/mcp`, 5s after Reconnect) are deliberately conservative. Faster timings cause missed keystrokes — the menu doesn't render fast enough, or Claude hasn't fully stopped generating. You can tune these down with `--settle-*` flags, but test carefully.

### Stale process cleanup

Consecutive deploys can spawn duplicate reconnect scripts. The script kills prior instances on startup to prevent keystroke collisions. The cleanup logic excludes its own PID and parent PID to avoid killing the calling shell (a subtle bug discovered during testing — `pgrep -f` matches any process whose command line contains the script name, including the parent shell).

### Detached execution

When called from within a Claude Code session — for example, as part of a deploy pipeline — the script must be detached (`nohup ... & disown`) with a delay (`--delay 10`). Without this, the Escape keystroke hits the calling session before its bash tool has returned, breaking the calling session's state.

### Plain Enter, no C-j

Kitty keyboard protocol (`C-j`) was tested and found unnecessary. Plain `Enter` via `tmux send-keys` works reliably across terminal emulators.

## How it works

1. **Session detection**: Lists all tmux sessions, checks each pane's `pane_current_command` for `"claude"`
2. **Stale cleanup**: Kills any prior `mcp-reconnect` processes to prevent duplicates
3. **Key injection**: For each Claude session, sends the exact keystroke sequence to navigate the `/mcp` → Reconnect menu
4. **Continuation**: After reconnect completes, sends a text prompt so Claude knows MCP is back and resumes work

For remote hosts, the same logic runs over SSH with the key sequence inlined as a heredoc.

## Integration examples

### Post-deploy hook

```bash
#!/bin/bash
# deploy.sh — deploy and reconnect

# ... your deploy logic (git pull, kill MCP servers, etc.) ...

# Reconnect all sessions (detached, with delay)
nohup mcp-reconnect --delay 10 &>/dev/null & disown
echo "MCP reconnect scheduled (10s delay)"
```

### Multi-machine deploy

```bash
#!/bin/bash
HOSTS=(server1 server2 server3)

for host in "${HOSTS[@]}"; do
    echo "Deploying to $host..."
    ssh "$host" "cd /path/to/repo && git pull && pkill -f 'python3.*server.py'"
done

# Reconnect all machines sequentially
for host in "${HOSTS[@]}"; do
    mcp-reconnect --remote "$host"
done
```

### Claude Code hook (plugin)

When installed as a plugin, `mcp-reconnect` includes a notification hook that detects MCP disconnection events and prompts Claude to reconnect.

## Testing

The repo includes an integration test suite that runs against real tmux:

```bash
bash test/integration-test.sh
```

Tests cover:
- Session detection (finds Claude sessions, ignores others)
- Key sequence injection (verifies `/mcp` and continuation arrive in pane)
- Key sequence order (`/mcp` before continuation message)
- Parallel multi-session reconnect
- Session targeting (only named session gets keys, bystanders untouched)
- `--delay` flag timing
- Clean exit when no sessions found

The test suite uses `exec -a claude sleep 300` to create tmux panes where `pane_current_command` reports `"claude"` — the same detection mechanism the real script uses.

A mock-based unit test suite is also available at `test/run-tests.sh` for environments without tmux.

## License

[MIT](LICENSE)

## Contributing

Issues and pull requests welcome at [github.com/palios-taey/mcp-reconnect](https://github.com/palios-taey/mcp-reconnect).
