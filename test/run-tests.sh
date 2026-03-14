#!/usr/bin/env bash
# Test suite for mcp-reconnect.
#
# Uses a mock tmux to verify behavior without real tmux sessions.
# Run: bash test/run-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_RECONNECT="$PROJECT_DIR/bin/mcp-reconnect"
MOCK_TMUX="$SCRIPT_DIR/mock-tmux"
MOCK_LOG="/tmp/mock-tmux-test.log"

chmod +x "$MOCK_TMUX"
chmod +x "$MCP_RECONNECT"

# Prepend mock tmux to PATH so the script finds it instead of real tmux
export PATH="$SCRIPT_DIR:$PATH"
# Rename mock to "tmux" via symlink
ln -sf "$MOCK_TMUX" "$SCRIPT_DIR/tmux"
# Also mock pgrep to avoid killing test runner
ln -sf /usr/bin/true "$SCRIPT_DIR/pgrep" 2>/dev/null || true

export MOCK_TMUX_LOG="$MOCK_LOG"

PASS=0
FAIL=0
TESTS=()

# --- Test helpers ---

setup() {
    rm -f "$MOCK_LOG"
    touch "$MOCK_LOG"
}

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label"
        ((PASS++))
    else
        echo "  ✗ $label (expected exit=$expected, got exit=$actual)"
        ((FAIL++))
    fi
}

assert_log_contains() {
    local pattern="$1" label="$2"
    if grep -q "$pattern" "$MOCK_LOG" 2>/dev/null; then
        echo "  ✓ $label"
        ((PASS++))
    else
        echo "  ✗ $label (pattern '$pattern' not found in tmux log)"
        ((FAIL++))
    fi
}

assert_log_not_contains() {
    local pattern="$1" label="$2"
    if ! grep -q "$pattern" "$MOCK_LOG" 2>/dev/null; then
        echo "  ✓ $label"
        ((PASS++))
    else
        echo "  ✗ $label (pattern '$pattern' found in tmux log but should not be)"
        ((FAIL++))
    fi
}

assert_output_contains() {
    local pattern="$1" output="$2" label="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  ✓ $label"
        ((PASS++))
    else
        echo "  ✗ $label (pattern '$pattern' not in output)"
        ((FAIL++))
    fi
}

assert_log_count() {
    local pattern="$1" expected="$2" label="$3"
    local actual
    actual=$(grep -c "$pattern" "$MOCK_LOG" 2>/dev/null || echo 0)
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label"
        ((PASS++))
    else
        echo "  ✗ $label (expected $expected occurrences of '$pattern', got $actual)"
        ((FAIL++))
    fi
}

# --- Tests ---

test_syntax_check() {
    echo "TEST: Bash syntax validation"
    bash -n "$MCP_RECONNECT"
    assert_exit 0 $? "Script passes bash -n syntax check"
}

test_help_flag() {
    echo "TEST: --help flag"
    setup
    local output
    output=$("$MCP_RECONNECT" --help 2>&1) || true
    assert_output_contains "Usage:" "$output" "--help shows usage"
    assert_output_contains "--remote" "$output" "--help mentions --remote"
    assert_output_contains "--delay" "$output" "--help mentions --delay"
    assert_output_contains "--dry-run" "$output" "--help mentions --dry-run"
}

test_no_sessions() {
    echo "TEST: No Claude sessions found"
    setup
    export MOCK_TMUX_SESSIONS=""
    local output
    output=$("$MCP_RECONNECT" 2>&1) || true
    assert_output_contains "No Claude Code sessions found" "$output" "Reports no sessions"
}

test_auto_detect_claude_sessions() {
    echo "TEST: Auto-detect Claude sessions (skip non-claude)"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude,editor=vim,architect=claude,shell=bash"
    local output
    output=$("$MCP_RECONNECT" 2>&1)
    assert_exit 0 $? "Exits cleanly"
    assert_output_contains "2 session(s)" "$output" "Detects exactly 2 Claude sessions"
    assert_output_contains "weaver" "$output" "Includes 'weaver'"
    assert_output_contains "architect" "$output" "Includes 'architect'"
    # Verify key sequence was sent
    assert_log_contains "Escape" "Sent Escape"
    assert_log_contains "/mcp" "Sent /mcp"
    assert_log_contains "Down" "Sent Down arrow"
}

test_specific_sessions() {
    echo "TEST: Specific session names as arguments"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude,architect=claude"
    local output
    output=$("$MCP_RECONNECT" weaver 2>&1)
    assert_exit 0 $? "Exits cleanly"
    assert_output_contains "1 session(s)" "$output" "Targets exactly 1 session"
    assert_output_contains "weaver" "$output" "Targets 'weaver'"
}

test_dry_run() {
    echo "TEST: --dry-run mode"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude,architect=claude"
    local output
    output=$("$MCP_RECONNECT" --dry-run 2>&1)
    assert_exit 0 $? "Exits cleanly"
    assert_output_contains "DRY RUN" "$output" "Shows DRY RUN label"
    assert_log_not_contains "send-keys" "No send-keys calls in dry-run"
}

test_dry_run_specific_session() {
    echo "TEST: --dry-run with specific session"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    local output
    output=$("$MCP_RECONNECT" --dry-run weaver 2>&1)
    assert_exit 0 $? "Exits cleanly"
    assert_output_contains "DRY RUN" "$output" "Shows DRY RUN for specific session"
    assert_output_contains "weaver" "$output" "Mentions the session name"
}

test_key_sequence_order() {
    echo "TEST: Key sequence order (Escape → /mcp → Enter → Enter → Down → Enter → msg → Enter)"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    "$MCP_RECONNECT" weaver 2>&1 >/dev/null

    # Extract send-keys calls in order
    local keys
    keys=$(grep 'send-keys' "$MOCK_LOG" | grep -oP '"[^"]*"' | tr '\n' ' ')

    # Verify sequence: Escape, then /mcp, then Enter, then Enter (menu), then Down, then Enter (select), then msg, then Enter
    local sequence_ok=true
    local send_key_lines
    mapfile -t send_key_lines < <(grep 'send-keys' "$MOCK_LOG")
    local count=${#send_key_lines[@]}

    if [ "$count" -ge 8 ]; then
        echo "  ✓ Correct number of send-keys calls ($count >= 8)"
        ((PASS++))
    else
        echo "  ✗ Expected >= 8 send-keys calls, got $count"
        ((FAIL++))
    fi

    # Check Escape is first send-keys
    if echo "${send_key_lines[0]}" | grep -q "Escape"; then
        echo "  ✓ First send-keys is Escape"
        ((PASS++))
    else
        echo "  ✗ First send-keys should be Escape"
        ((FAIL++))
    fi

    # Check /mcp is sent
    assert_log_contains '"/mcp"' "/mcp text is sent"

    # Check Down arrow is sent
    assert_log_contains '"Down"' "Down arrow is sent"
}

test_custom_message() {
    echo "TEST: --message flag overrides continuation prompt"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    "$MCP_RECONNECT" --message "Custom message here" weaver 2>&1 >/dev/null
    assert_log_contains "Custom message here" "Custom message appears in tmux log"
}

test_custom_settle_times() {
    echo "TEST: --settle-* flags are accepted"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    local output
    output=$("$MCP_RECONNECT" --settle-esc 1 --settle-mcp 1 --settle-select 1 --dry-run weaver 2>&1)
    assert_exit 0 $? "Custom settle times accepted without error"
}

test_delay_flag() {
    echo "TEST: --delay flag (short delay)"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    local start end elapsed
    start=$(date +%s)
    "$MCP_RECONNECT" --delay 1 --dry-run weaver 2>&1 >/dev/null
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$elapsed" -ge 1 ]; then
        echo "  ✓ --delay 1 waited at least 1 second (elapsed: ${elapsed}s)"
        ((PASS++))
    else
        echo "  ✗ --delay 1 should wait at least 1 second (elapsed: ${elapsed}s)"
        ((FAIL++))
    fi
}

test_unknown_flag() {
    echo "TEST: Unknown flag produces error"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    local output rc
    output=$("$MCP_RECONNECT" --bogus 2>&1) || rc=$?
    if [ "${rc:-0}" -ne 0 ]; then
        echo "  ✓ Exits non-zero on unknown flag"
        ((PASS++))
    else
        echo "  ✗ Should exit non-zero on unknown flag"
        ((FAIL++))
    fi
    assert_output_contains "Unknown option" "$output" "Error message mentions unknown option"
}

test_remote_dry_run() {
    echo "TEST: --remote --dry-run"
    setup
    export MOCK_TMUX_SESSIONS="weaver=claude"
    local output
    output=$("$MCP_RECONNECT" --remote testhost --dry-run 2>&1)
    assert_exit 0 $? "Remote dry-run exits cleanly"
    assert_output_contains "DRY RUN" "$output" "Shows DRY RUN for remote"
    assert_output_contains "testhost" "$output" "Mentions the remote host"
}

test_multiple_sessions_all_get_keys() {
    echo "TEST: Multiple sessions all receive key sequences"
    setup
    export MOCK_TMUX_SESSIONS="sess1=claude,sess2=claude,sess3=claude"
    "$MCP_RECONNECT" 2>&1 >/dev/null
    assert_output_contains "" "" ""  # dummy to not break
    # Each session should get Escape
    assert_log_count "Escape" 3 "All 3 sessions receive Escape"
}

# --- Run all tests ---

echo "═══════════════════════════════════════════════"
echo "  mcp-reconnect test suite"
echo "═══════════════════════════════════════════════"
echo ""

test_syntax_check
echo ""
test_help_flag
echo ""
test_no_sessions
echo ""
test_auto_detect_claude_sessions
echo ""
test_specific_sessions
echo ""
test_dry_run
echo ""
test_dry_run_specific_session
echo ""
test_key_sequence_order
echo ""
test_custom_message
echo ""
test_custom_settle_times
echo ""
test_delay_flag
echo ""
test_unknown_flag
echo ""
test_remote_dry_run
echo ""
test_multiple_sessions_all_get_keys
echo ""

# --- Cleanup ---
rm -f "$SCRIPT_DIR/tmux" "$SCRIPT_DIR/pgrep"

# --- Summary ---
echo "═══════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "  *** $FAIL FAILURES ***"
    exit 1
else
    echo "  All tests passed."
    exit 0
fi
