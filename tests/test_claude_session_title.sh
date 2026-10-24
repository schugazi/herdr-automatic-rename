#!/usr/bin/env bash
# Drive both snapshot and pane-list naming, including manual ownership.
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
SB=$(mktemp -d "$TMPDIR/hal-claude-title.XXXXXX")
trap 'rm -rf "$SB"' EXIT
export HERDR_BIN_PATH="$here/mocks/herdr"
export HERDR_MOCK_DIR="$SB/fixtures" HERDR_MOCK_LOG="$SB/log"
export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/config.sh"
export HERDR_CONFIG_FILE="$SB/herdr.toml" HERDR_SOCKET_PATH="$SB/herdr.sock"
unset HERDR_TAB_ID HERDR_PLUGIN_CONTEXT_JSON
mkdir -p "$HERDR_MOCK_DIR" "$SB/bin"
# A naming regression must not reach a real API, even from a detached worker.
cat >"$SB/bin/curl" <<'STUB'
#!/bin/sh
printf 'attempt\n' >>"$HERDR_MOCK_DIR/api-attempts"
exit 1
STUB
chmod +x "$SB/bin/curl"
export PATH="$SB/bin:$PATH"
printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
cat >"$HERDR_AUTOMATIC_RENAME_CONFIG" <<'CONFIG'
NAME_TABS=1
NAME_PANES=0
AUTO_INDEX=0
TAB_CONTEXT=0
SHOW_BRANCH=0
MAX_TITLE_LEN=16
TITLE_CONDENSE=1
AI_TITLES=1
ANTHROPIC_API_KEY=
AI_API_KEY_FILE=/nonexistent
AI_API_URL=http://127.0.0.1:9/
PANE_TOPICS=0
AGENT_TRANSCRIPT=0
CONFIG

fixtures() {
  jq -n --arg label "$1" --arg topic "$2" --arg topic2 "$3" --arg agent "${4:-claude}" \
    --arg terminal "${5:-Old terminal task}" '
    {result:{snapshot:{
      workspaces:[{workspace_id:"w1",label:"api"}],
      tabs:[{workspace_id:"w1",tab_id:"w1:t1",label:$label,pane_count:1,focused:true}],
      layouts:[{tab_id:"w1:t1",focused_pane_id:"p1"}],
      panes:[{pane_id:"p1",tab_id:"w1:t1",agent:$agent,focused:true,
        terminal_title_stripped:$terminal,cwd:"/no-project",
        agent_session:{value:"s1"},tokens:{topic:$topic,topic2:$topic2}}],
      agents:[]
    }}}' >"$HERDR_MOCK_DIR/snapshot.json"
  if [ "$path_kind" = list ]; then
    jq '{result:{workspaces:.result.snapshot.workspaces}}' "$HERDR_MOCK_DIR/snapshot.json" >"$HERDR_MOCK_DIR/workspaces.json"
    jq '{result:{tabs:.result.snapshot.tabs}}' "$HERDR_MOCK_DIR/snapshot.json" >"$HERDR_MOCK_DIR/tabs_w1.json"
    jq '{result:{panes:.result.snapshot.panes}}' "$HERDR_MOCK_DIR/snapshot.json" >"$HERDR_MOCK_DIR/panes.json"
    rm "$HERDR_MOCK_DIR/snapshot.json"
  fi
}
run() {
  : >"$HERDR_MOCK_LOG"
  bash "$here/../automatic-rename.sh" "${1:-pane.focused}"
}
label() { awk '$1 == "tab" && $2 == "rename" { $1=$2=$3=""; sub(/^ +/, ""); print }' "$HERDR_MOCK_LOG"; }

for path_kind in snapshot list; do
  export XDG_STATE_HOME="$SB/$path_kind"
  pins="$XDG_STATE_HOME/herdr-automatic-rename/ai-pins"
  mkdir -p "$pins"
  printf 'cached-haiku' >"$pins/s1"
  fixtures 1 "Fix auth" "retry"
  run
  check "$path_kind: session metadata beats terminal and AI pin" "auth-retry" "$(label)"
  fixtures auth-retry "Fix token" "expiry"
  run
  check "$path_kind: a changed session title refreshes immediately" "token-expiry" "$(label)"
  fixtures token-expiry "" ""
  run
  check "$path_kind: absent metadata falls back to terminal" "old-terminal" "$(label)"
  check "$path_kind: Claude created no AI queue or cache" "no" "$([ -d "$XDG_STATE_HOME/herdr-automatic-rename/ai-titles" ] && echo yes || echo no)"
  fixtures keep-this "Fix auth" "retry"
  run
  check "$path_kind: manual tab name survives title changes" "" "$(label)"
  export HERDR_TAB_ID=w1:t1
  run retitle
  check "$path_kind: retitle also preserves manual ownership" "" "$(label)"
  unset HERDR_TAB_ID
done

# Other agents still use their model pin, ignoring Claude-specific metadata.
path_kind=snapshot
export XDG_STATE_HOME="$SB/codex"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename/ai-pins"
printf 'codex-pin' >"$XDG_STATE_HOME/herdr-automatic-rename/ai-pins/s1"
fixtures 1 "Fix auth" "retry" codex
run
check "Codex still uses its AI pin" "codex-pin" "$(label)"
printf '\nAI_TITLES=0\n' >>"$HERDR_AUTOMATIC_RENAME_CONFIG"
export HERDR_TAB_ID=w1:t1
fixtures codex-pin "Fix auth" "retry" codex
run retitle
check_contains "AI-off retitle explains why it cannot generate a name" "$(cat "$HERDR_MOCK_LOG")" "AI tab titles are off"
check_absent "AI-off does not misidentify an automatic tab as manual" "$(cat "$HERDR_MOCK_LOG")" "not an automatically named"

export XDG_STATE_HOME="$SB/untitled"
fixtures 1 "" "" claude "Claude Code"
run retitle
check_contains "untitled Claude reports that no title was available" "$(cat "$HERDR_MOCK_LOG")" "no session title yet"
fixtures 1 "Fix auth" "retry"
run retitle
check "Claude refresh works with AI disabled" "auth-retry" "$(label)"
check_absent "successful Claude refresh has no failure notice" "$(cat "$HERDR_MOCK_LOG")" "Nothing to retitle"
check "no API calls were attempted" "no" "$([ -e "$HERDR_MOCK_DIR/api-attempts" ] && echo yes || echo no)"
t_summary
