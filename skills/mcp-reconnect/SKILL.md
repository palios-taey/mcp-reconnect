---
name: mcp-reconnect
description: Reconnect MCP servers in Claude Code tmux sessions after code deployments or server restarts. Use when MCP servers need reconnecting and sessions are running inside tmux.
---

# MCP Reconnect

You have access to the `mcp-reconnect` script that automates MCP server reconnection in Claude Code tmux sessions.

## When to use this

- After deploying new MCP server code
- After MCP server processes are killed or restarted
- When Claude Code sessions show MCP connection errors
- During automated deploy workflows that restart services

## How it works

Claude Code has no programmatic API for MCP reconnect. The only way is through the interactive `/mcp` menu. This skill automates that sequence via `tmux send-keys`:

1. **Escape** — stop any active generation
2. **/mcp + Enter** — open the slash command menu
3. **Enter** — enter the menu
4. **Down + Enter** — select "Reconnect" (2nd option)
5. **Continuation prompt** — tell Claude to resume work

## Usage

Run the script from the plugin's bin directory:

```bash
# Reconnect all local Claude tmux sessions
mcp-reconnect

# Reconnect specific sessions
mcp-reconnect session-name-1 session-name-2

# Reconnect sessions on a remote host
mcp-reconnect --remote hostname

# Delayed start (when calling from within a Claude Code session)
nohup mcp-reconnect --delay 10 &>/dev/null & disown
```

## Critical design constraints

1. **Sequential only** — never run reconnect in parallel across sessions. Parallel instances cause `/mcp/mcp` double-typing and kill sibling sessions.
2. **Detached with delay** — when calling from within a Claude Code session, you MUST use `nohup` + `disown` with `--delay` so the Bash tool returns before Escape hits the calling session.
3. **tmux required** — this only works with Claude Code sessions running inside tmux.
4. **Conservative timing** — the default settle times (5s/2s/5s) are tuned to avoid missed keystrokes. Do not reduce without testing.

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--remote HOST` | — | Reconnect on a remote machine via SSH |
| `--delay N` | 0 | Wait N seconds before starting |
| `--settle-esc N` | 5 | Seconds after Escape |
| `--settle-mcp N` | 2 | Seconds after /mcp submit |
| `--settle-select N` | 5 | Seconds after Reconnect selection |
| `--message MSG` | (default) | Override continuation prompt |
| `--dry-run` | — | Preview without sending keys |
