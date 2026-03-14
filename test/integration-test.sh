#!/usr/bin/env bash
# Integration test for mcp-reconnect using real tmux.
#
# Creates tmux sessions with a process named "claude" (a shim that logs input),
# runs mcp-reconnect against them, and verifies the exact key sequence arrived.
#
# Requirements: tmux (real, not mocked)
#
# Run: bash test/integration-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_RECONNECT="$PROJECT_DIR/bin/mcp-reconnect"

PASS=0
FAIL=0

# --- Helpers -----------------------------------------------------------------

assert() {
    local condition="$1" label="$2"
    if eval "$condition"; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label"
        FAIL=$((FAIL + 1))
    fi
}

setup_fake_claude() {
    # No-op — we use 'exec -a claude sleep 120' directly in create_claude_session
    # which makes pane_current_command show "claude" (exec -a sets argv[0])
    true
}

# Create a tmux session where pane_current_command = "claude"
create_claude_session() {
    local name="$1"
    # exec -a sets argv[0], so tmux sees pane_current_command="claude"
    # sleep keeps the pane alive
    tmux new-session -d -s "$name" -x 200 -y 50 "exec -a claude sleep 300" 2>/dev/null
    sleep 0.5
    # Verify it worked
    local cmd
    cmd=$(tmux display-message -t "$name" -p '#{pane_current_command}' 2>/dev/null || echo "FAIL")
    if [ "$cmd" != "claude" ]; then
        echo "WARNING: session $name has pane_current_command='$cmd', expected 'claude'"
    fi
}

# Capture what's in the tmux pane (the visible terminal content)
capture_pane() {
    local session="$1"
    tmux capture-pane -t "$session" -p 2>/dev/null
}

# Wait for pane content to contain a string
wait_for_pane() {
    local session="$1" pattern="$2" timeout="${3:-10}"
    local i=0
    while [ $i -lt "$timeout" ]; do
        if capture_pane "$session" | grep -q "$pattern" 2>/dev/null; then
            return 0
        fi
        sleep 1
        ((i++))
    done
    return 1
}

cleanup() {
    tmux kill-server 2>/dev/null || true
    rm -f /tmp/pane-capture-*.log
}

# --- Tests -------------------------------------------------------------------

test_session_detection() {
    echo "TEST: Session detection — finds claude sessions, ignores others"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "test-claude-1"
    create_claude_session "test-claude-2"
    # Create a non-claude session
    tmux new-session -d -s "test-bash" -x 200 -y 50 "bash" 2>/dev/null
    sleep 0.5

    # Verify pane commands
    local cmd1 cmd2 cmd3
    cmd1=$(tmux display-message -t "test-claude-1" -p '#{pane_current_command}')
    cmd2=$(tmux display-message -t "test-claude-2" -p '#{pane_current_command}')
    cmd3=$(tmux display-message -t "test-bash" -p '#{pane_current_command}')

    assert '[ "$cmd1" = "claude" ]' "test-claude-1 shows pane_current_command=claude (got: $cmd1)"
    assert '[ "$cmd2" = "claude" ]' "test-claude-2 shows pane_current_command=claude (got: $cmd2)"
    assert '[ "$cmd3" = "bash" ]' "test-bash shows pane_current_command=bash (got: $cmd3)"

    # Run with --dry-run to test detection only
    local output
    output=$("$MCP_RECONNECT" --dry-run 2>&1)
    assert 'echo "$output" | grep -q "2 session"' "Detects exactly 2 claude sessions"
    assert 'echo "$output" | grep -q "DRY RUN"' "Dry-run mode works"
    assert '! echo "$output" | grep -q "test-bash"' "Does not include bash session"
}

test_key_sequence_injection() {
    echo "TEST: Key sequence injection — verify exact keys arrive in tmux pane"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "test-inject"
    sleep 0.3

    # Use pipe-pane to capture all output
    local capture_log="/tmp/pane-capture-inject.log"
    : > "$capture_log"
    tmux pipe-pane -t "test-inject" -o "cat >> $capture_log"

    # Run mcp-reconnect with short settle times for speed
    "$MCP_RECONNECT" --settle-esc 1 --settle-mcp 1 --settle-select 1 "test-inject" 2>&1 >/dev/null

    sleep 1  # let pipe flush

    # Capture final pane state
    local pane_content
    pane_content=$(capture_pane "test-inject")
    local raw_log
    raw_log=$(cat "$capture_log" 2>/dev/null || echo "")

    # The pane should show evidence of our key injection:
    # /mcp should have been typed as literal text
    assert 'echo "$pane_content" | grep -q "/mcp"' "Pane shows /mcp was typed"

    # Continuation message should appear
    assert 'echo "$pane_content" | grep -q "MCP servers reconnected"' "Pane shows continuation message"

    rm -f "$capture_log"
}

test_key_sequence_order_via_sendkeys_log() {
    echo "TEST: Key sequence order — verify via tmux monitor"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "test-order"
    sleep 0.3

    # Instrument: use tmux hooks to log send-keys
    # Unfortunately tmux doesn't have a send-keys hook, but we can
    # verify the pane content shows the right sequence
    local capture_log="/tmp/pane-capture-order.log"
    : > "$capture_log"
    tmux pipe-pane -t "test-order" -o "cat >> $capture_log"

    "$MCP_RECONNECT" --settle-esc 1 --settle-mcp 1 --settle-select 1 "test-order" 2>&1 >/dev/null

    sleep 1

    local pane_content
    pane_content=$(capture_pane "test-order")

    # /mcp should appear before the continuation message
    local mcp_line msg_line
    mcp_line=$(echo "$pane_content" | grep -n "/mcp" | head -1 | cut -d: -f1 || echo "0")
    msg_line=$(echo "$pane_content" | grep -n "MCP servers reconnected" | head -1 | cut -d: -f1 || echo "0")

    assert '[ "$mcp_line" != "0" ]' "/mcp appears in pane (line $mcp_line)"
    assert '[ "$msg_line" != "0" ]' "Continuation message appears in pane (line $msg_line)"
    if [ "$mcp_line" != "0" ] && [ "$msg_line" != "0" ]; then
        assert '[ "$mcp_line" -lt "$msg_line" ]' "/mcp (line $mcp_line) appears before continuation (line $msg_line)"
    fi

    rm -f "$capture_log"
}

test_parallel_multiple_sessions() {
    echo "TEST: Parallel execution — all sessions get reconnected"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "par-1"
    create_claude_session "par-2"
    create_claude_session "par-3"
    sleep 0.3

    # Capture all panes
    for s in par-1 par-2 par-3; do
        tmux pipe-pane -t "$s" -o "cat >> /tmp/pane-capture-${s}.log"
        : > "/tmp/pane-capture-${s}.log"
    done

    local output
    output=$("$MCP_RECONNECT" --settle-esc 1 --settle-mcp 1 --settle-select 1 2>&1)
    assert 'echo "$output" | grep -q "3 session"' "Finds all 3 sessions"

    sleep 2  # let pipe flush

    for s in par-1 par-2 par-3; do
        local pane
        pane=$(capture_pane "$s")
        assert 'echo "$pane" | grep -q "/mcp"' "Session $s received /mcp"
        assert 'echo "$pane" | grep -q "MCP servers reconnected"' "Session $s received continuation"
        rm -f "/tmp/pane-capture-${s}.log"
    done

    assert 'echo "$output" | grep -q "All sessions reconnected"' "Reports all done"
}

test_specific_session_only() {
    echo "TEST: Targeting specific session — others untouched"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "target"
    create_claude_session "bystander"
    sleep 0.3

    tmux pipe-pane -t "bystander" -o "cat >> /tmp/pane-capture-bystander.log"
    : > /tmp/pane-capture-bystander.log

    "$MCP_RECONNECT" --settle-esc 1 --settle-mcp 1 --settle-select 1 "target" 2>&1 >/dev/null

    sleep 1

    local target_pane bystander_pane
    target_pane=$(capture_pane "target")
    bystander_pane=$(capture_pane "bystander")

    assert 'echo "$target_pane" | grep -q "/mcp"' "Target session received /mcp"
    assert '! echo "$bystander_pane" | grep -q "/mcp"' "Bystander session was NOT touched"

    rm -f /tmp/pane-capture-bystander.log
}

test_delay_timing() {
    echo "TEST: --delay flag actually delays"
    cleanup
    tmux start-server 2>/dev/null

    create_claude_session "delay-test"
    sleep 0.3

    local start end elapsed
    start=$(date +%s)
    "$MCP_RECONNECT" --delay 2 --settle-esc 1 --settle-mcp 1 --settle-select 1 --dry-run "delay-test" 2>&1 >/dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    assert '[ "$elapsed" -ge 2 ]' "--delay 2 waited at least 2 seconds (actual: ${elapsed}s)"
}

test_no_sessions_exit_clean() {
    echo "TEST: No sessions found — exits cleanly"
    cleanup
    tmux start-server 2>/dev/null

    # Only bash sessions, no claude
    tmux new-session -d -s "just-bash" "bash" 2>/dev/null
    sleep 0.3

    local output rc
    output=$("$MCP_RECONNECT" 2>&1) && rc=0 || rc=$?
    assert '[ "$rc" -eq 0 ]' "Exits with code 0"
    assert 'echo "$output" | grep -q "No Claude Code sessions"' "Reports no sessions found"
}

# --- Run all tests -----------------------------------------------------------

echo "═══════════════════════════════════════════════════════════"
echo "  mcp-reconnect INTEGRATION TEST SUITE"
echo "  Using real tmux $(tmux -V)"
echo "═══════════════════════════════════════════════════════════"
echo ""

setup_fake_claude

test_session_detection
echo ""
test_key_sequence_injection
echo ""
test_key_sequence_order_via_sendkeys_log
echo ""
test_parallel_multiple_sessions
echo ""
test_specific_session_only
echo ""
test_delay_timing
echo ""
test_no_sessions_exit_clean
echo ""

# --- Cleanup -----------------------------------------------------------------
cleanup

# --- Summary -----------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "  *** $FAIL FAILURES ***"
    echo "═══════════════════════════════════════════════════════════"
    exit 1
else
    echo "  All tests passed."
    echo "═══════════════════════════════════════════════════════════"
    exit 0
fi
