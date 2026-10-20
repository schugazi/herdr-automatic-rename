#!/usr/bin/env bash
# Integration tests for the CONTEXT half of a label: the directory a pane sits
# in, the branch it has checked out, and the machine it reached over ssh -- plus
# the transcript an agent names its own session in. Same fake-herdr harness as
# tests/test_reconcile.sh, kept in its own file because these scenarios all turn
# on what a pane's DIRECTORY says rather than on numbering or ownership.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

SEP=$(printf ' \342\200\272 ')   # the CONTEXT_SEP default, U+203A

setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-ctx.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"
  export SHELL_NAME=zsh
  export NAME_TABS=1 AUTO_INDEX=0
  unset HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION HERDR_MOCK_FAIL_RENAME
  unset HIDE_SHELL AUTO_INDEX_WORKSPACES AUTO_INDEX_TABS AUTO_INDEX_AGENTS
  unset AGENT_TITLES SHOW_PROGRAM_ARGS TAB_CONTEXT MAX_CONTEXT_LEN
  unset SHOW_BRANCH MAX_BRANCH_LEN AGENT_TRANSCRIPT
  export CLAUDE_CONFIG_DIR="$SB/claude"   # never the real one
  unset HERDR_TAB_ID HERDR_PANE_ID HERDR_PLUGIN_CONTEXT_JSON
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: the directory names the tab, and the workspace name does not
#   repeat itself.
#   t1 sits in a directory of its own      -> "web › nvim"
#   t2 sits in the workspace's directory   -> "nvim" alone
#   t3 sits at $HOME                       -> "zsh" alone (home says nothing)
# ======================================================================
setup
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/web"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,"cwd":"/home/u/dev/api"},
    {"pane_id":"p3","tab_id":"w1:t3","focused":true,"cwd":"/home/u"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"},
    {"tab_id":"w1:t3","focused_pane_id":"p3"}
  ]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim main.go"}]}}}
JSON
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the pane's directory leads the label" "$out" "tab rename w1:t1 web${SEP}nvim"
check_contains "the workspace's own directory is not repeated" "$out" "tab rename w1:t2 nvim"
check_contains "the home directory says nothing" "$out" "tab rename w1:t3 zsh"
teardown

# ======================================================================
# Scenario 2: TAB_CONTEXT=0 names by the program alone, as before the context
#   existed. Same fixtures as Scenario 1's t1.
# ======================================================================
setup
export TAB_CONTEXT=0
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/web"}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"}]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "TAB_CONTEXT=0 names by the program alone" "$out" "tab rename w1:t1 nvim"
check_absent   "TAB_CONTEXT=0 adds no separator"          "$out" "$SEP"
teardown

# ======================================================================
# Scenario 3: the per-list fallback path (no snapshot.json) carries the context
#   too. The lists are what an older herdr answers with, and a tab named there
#   must read the same as one named from a snapshot.
# ======================================================================
setup
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/web"}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the list path names the context too" "$out" "tab rename w1:t1 web${SEP}nvim"
teardown

# ======================================================================
# Scenario 4: the shell hook. It renames the tab on every command, so it has to
#   reach the SAME label the reconcile does -- a hook that dropped the context
#   would flip the tab on every prompt, which is the flicker the fast path
#   exists to avoid.
#
#   Its directory is the shell's own $PWD (the hook backgrounds the engine from
#   the pane), and the workspace name it dedupes against is the one the last
#   reconcile recorded on the tab.
# ======================================================================
setup
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename" "$SB/dev/web" "$SB/dev/api"
printf '{"t1":{"auto":"zsh","enabled":true,"ws":"api"}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"zsh"}}}
JSON
( cd "$SB/dev/web" && /usr/bin/env bash "$ENGINE" precmd zsh )
out=$(log)
check_contains "the hook names the context from \$PWD" "$out" "tab rename t1 web${SEP}zsh"
: >"$HERDR_MOCK_LOG"
( cd "$SB/dev/api" && /usr/bin/env bash "$ENGINE" precmd zsh )
out=$(log)
check_absent "the hook dedupes the workspace it was told" "$out" "api${SEP}"
teardown

# ======================================================================
# Scenario 5: the workspace a tab dedupes against is recorded on the tab, so the
#   hook can read it back without a herdr call of its own.
# ======================================================================
setup
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"[1] api"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/web"}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"}]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HOME=/home/u run_event tab.focused
got=$(jq -r '."w1:t1".ws' "$XDG_STATE_HOME/herdr-automatic-rename/state.json" 2>/dev/null)
# Recorded WITHOUT the numbering prefix: it is compared against a directory name,
# and "[1] api" is not one.
check "the workspace base is recorded on the tab" "api" "$got"
teardown

# ======================================================================
# Scenario 6: a workspace renamed EARLIER IN THE SAME PASS. The workspace pass
#   runs first and re-labels w1 from its directory ("api" -> "web"); the tab pass
#   reads the workspace list fetched before that rename, so the label in hand is
#   already one pass out of date. Deduping against it would name a tab in the web
#   workspace "web > nvim" -- the exact repetition the dedupe exists to remove --
#   until some later event refreshed the list.
#
#   Two events, because a workspace only follows its directory once the plugin
#   owns its label: the first adopts it where label and directory agree, the
#   second is the cd that moves it.
# ======================================================================
setup
export AUTO_INDEX=1
printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
mkdir -p "$SB/dev/api" "$SB/dev/web"
ident() {
  printf '{"version":7,"collapsed_space_keys":[],"workspaces":[{"id":"w1","label":null,"identity_cwd":"%s"}]}\n' \
    "$1" >"$SB/session.json"
}
ident "$SB/dev/api"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api","focused":false}]}}
JSON
run_event workspace.created
check_contains "the workspace is adopted at its own directory" "$(log)" "workspace rename w1 [1] api"

: >"$HERDR_MOCK_LOG"
ident "$SB/dev/web"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api","focused":false}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
cat >"$HERDR_MOCK_DIR/panes.json" <<JSON
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"$SB/dev/web"}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HOME=/home/u run_event pane.focused
out=$(log)
check_contains "the workspace follows its directory" "$out" "workspace rename w1 [1] web"
check_contains "the tab dedupes against the NEW name" "$out" "tab rename w1:t1 [1] nvim"
check_absent   "... not against the one it was fetched with" "$out" "web${SEP}nvim"
teardown

# ======================================================================
# Scenario 7: the branch qualifies the context.
#   t1 sits in the workspace's own directory on a feature branch -> the
#      directory drops out and the branch is what is left to say
#   t2 sits in another checkout that is on its trunk -> the branch says nothing
#      (every tab of that repository would carry it alike)
# ======================================================================
setup
mkdir -p "$SB/dev/api/.git/refs/remotes/origin" "$SB/dev/web/.git/refs/remotes/origin"
printf 'ref: refs/heads/feature/proj-517-qa-bot\n' >"$SB/dev/api/.git/HEAD"
printf 'ref: refs/remotes/origin/main\n' >"$SB/dev/api/.git/refs/remotes/origin/HEAD"
printf 'ref: refs/heads/main\n' >"$SB/dev/web/.git/HEAD"
printf 'ref: refs/remotes/origin/main\n' >"$SB/dev/web/.git/refs/remotes/origin/HEAD"
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"$SB/dev/api"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,"cwd":"$SB/dev/web"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"}
  ]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim main.go"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the branch is reduced to its issue key" "$out" "tab rename w1:t1 PROJ-517${SEP}nvim"
check_contains "the trunk contributes nothing"          "$out" "tab rename w1:t2 web${SEP}nvim"
check_absent   "... and is not shown beside it"         "$out" "web${SEP}main"
teardown

# ======================================================================
# Scenario 8: SHOW_BRANCH=0, and the shell hook reads the branch from its own
#   directory -- a checkout switched at the prompt shows up at the next one,
#   which no herdr event would have told us about.
# ======================================================================
setup
export SHOW_BRANCH=0
mkdir -p "$SB/dev/api/.git/refs/remotes/origin"
printf 'ref: refs/heads/feature/oauth\n' >"$SB/dev/api/.git/HEAD"
printf 'ref: refs/remotes/origin/main\n' >"$SB/dev/api/.git/refs/remotes/origin/HEAD"
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"t1":{"auto":"zsh","enabled":true,"ws":"api"}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"zsh"}}}
JSON
( cd "$SB/dev/api" && /usr/bin/env bash "$ENGINE" precmd zsh )
check "SHOW_BRANCH=0 leaves the hook's label bare" "" "$(log)"
: >"$HERDR_MOCK_LOG"
unset SHOW_BRANCH
( cd "$SB/dev/api" && /usr/bin/env bash "$ENGINE" precmd zsh )
check_contains "the hook reads the branch from its own directory" "$(log)" \
  "tab rename t1 oauth${SEP}zsh"
teardown

# ======================================================================
# Scenario 9: a pane that reached another machine is named after it. The
#   directory it was launched from is local and says nothing about the remote,
#   and the branch checked out there would read as that machine's.
# ======================================================================
setup
mkdir -p "$SB/dev/api/.git/refs/remotes/origin"
printf 'ref: refs/heads/feature/oauth\n' >"$SB/dev/api/.git/HEAD"
printf 'ref: refs/remotes/origin/main\n' >"$SB/dev/api/.git/refs/remotes/origin/HEAD"
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"web"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"$SB/dev/api"}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"}]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"ssh","cmdline":"ssh -p 2222 deploy@prod-01"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the machine names the tab" "$out" "tab rename w1:t1 prod-01${SEP}ssh"
check_absent   "no local directory on a remote tab" "$out" "api${SEP}"
check_absent   "no local branch either"             "$out" "oauth"
teardown

# ======================================================================
# Scenario 10: the shell hook names an ssh tab the moment the command starts,
#   which is the only thing that can: herdr has no event for it, and by the time
#   one arrives the user is already looking at the remote shell.
# ======================================================================
setup
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"t1":{"auto":"zsh","enabled":true,"ws":"api"}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"zsh"}}}
JSON
/usr/bin/env bash "$ENGINE" preexec 'ssh prod-01'
check_contains "the hook names the machine too" "$(log)" "tab rename t1 prod-01${SEP}ssh"
teardown

# ======================================================================
# Scenario 11: an agent that has not titled its terminal is named from its own
#   session. Claude Code derives that title from what the user typed, so a
#   session opened with a slash command and answered by the agent alone never
#   gets one, and the tab read "claude" for as long as it ran.
#
#   t1 has no terminal title at all and a session to read.
#   t2 has one, so the transcript is never opened -- its session id points at a
#      transcript saying something else, which is how the test can tell.
# ======================================================================
setup
SESSION=647693ed-d633-4871-b7ee-5f5e4b5728ea
OTHER=11111111-2222-3333-4444-555555555555
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api"
cat >"$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api/$SESSION.jsonl" <<'JSON'
{"type":"user","message":{"role":"user","content":"<command-name>/code-review</command-name>\n<command-args>spec.md</command-args>"},"origin":{"kind":"human"}}
JSON
cat >"$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api/$OTHER.jsonl" <<'JSON'
{"type":"ai-title","aiTitle":"Never read this","sessionId":"x"}
JSON
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/api",
     "agent":"claude","agent_status":"working",
     "agent_session":{"agent":"claude","kind":"id","value":"$SESSION"}},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,"cwd":"/home/u/dev/api",
     "agent":"claude","agent_status":"working","terminal_title_stripped":"Squash merge command",
     "agent_session":{"agent":"claude","kind":"id","value":"$OTHER"}}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"}
  ]
}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the session names the untitled tab" "$out" "tab rename w1:t1 code-review spec.md"
check_contains "a titled agent is named from its title" "$out" "tab rename w1:t2 Squash merge command"
check_absent   "and its transcript is never opened"     "$out" "Never read this"
teardown

# ======================================================================
# Scenario 12: AGENT_TRANSCRIPT=0 leaves the transcript unread, and the tab is
#   named after the program as it was before this existed.
# ======================================================================
setup
export AGENT_TRANSCRIPT=0
SESSION=647693ed-d633-4871-b7ee-5f5e4b5728ea
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api"
cat >"$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api/$SESSION.jsonl" <<'JSON'
{"type":"ai-title","aiTitle":"Not to be read","sessionId":"x"}
JSON
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/api",
     "agent":"claude","agent_status":"working",
     "agent_session":{"agent":"claude","kind":"id","value":"$SESSION"}}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"}]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"claude","cmdline":"claude"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the program names the tab instead" "$out" "tab rename w1:t1 claude"
check_absent   "the transcript is not read"        "$out" "Not to be read"
teardown

# ======================================================================
# Scenario 13: another agent's pane is not read. Only Claude Code keeps its
#   sessions in this shape and this place, and a pane can carry a session value
#   that a claude left behind in it -- reading that would put one agent's prompts
#   on another agent's tab.
# ======================================================================
setup
SESSION=647693ed-d633-4871-b7ee-5f5e4b5728ea
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api"
cat >"$CLAUDE_CONFIG_DIR/projects/-home-u-dev-api/$SESSION.jsonl" <<'JSON'
{"type":"ai-title","aiTitle":"Belongs to claude","sessionId":"x"}
JSON
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/api",
     "agent":"codex","agent_status":"working",
     "agent_session":{"agent":"claude","kind":"id","value":"$SESSION"}}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"}]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"codex","cmdline":"codex"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the program names the tab" "$out" "tab rename w1:t1 codex"
check_absent   "another agent's transcript is not read" "$out" "Belongs to claude"
teardown

# ======================================================================
# Scenario 14: a workspace rewritten by WORKSPACE_SUBSTITUTE_SETS still swallows
#   its own name out of its tabs. The rewrite is the sidebar's alone -- the
#   directory is still called what it is called -- so the tabs go on deduping
#   against the DERIVED name. Deduping against the rewrite instead would have a
#   tab in worktree-feature/ re-inject the long spelling the sidebar was
#   shortened to lose ("worktree-feature > nvim" under a "wt-feature" heading).
# ======================================================================
setup
printf "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')\n" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
printf '{"version":7,"collapsed_space_keys":[],"workspaces":[
  {"id":"w1","label":null,"identity_cwd":"/home/u/dev/worktree-feature"}]}\n' \
  >"$SB/session.json"
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"worktree-feature"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"cwd":"/home/u/dev/worktree-feature"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,"cwd":"/home/u/dev/worktree-feature/web"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"}
  ]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim main.go"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_contains "the workspace wears the rewrite" "$out" "workspace rename w1 wt-feature"
check_contains "and its tabs still drop its directory" "$out" "tab rename w1:t1 nvim"
check_contains "a subdirectory still says which" "$out" "tab rename w1:t2 web${SEP}nvim"
teardown

# ======================================================================
# Scenario: herdr-mirror tabs belong to the remote (issue #26). A mirror pane
#   runs herdr-mirror's streamer in its .mirror-pane marker directory, and
#   herdr-mirror pushes any local label to the remote tab as a user rename. So
#   no write reaches a mirror tab: not a name, not a number, not the host tag.
#   t1 the remote's own host-tagged label, in the host tag's slot -> untouched
#   t2 a fresh mirror tab, still on herdr's placeholder         -> untouched
#   t3 an owned mirror tab, an agent reported onto its pane,
#      numbered for another position                            -> untouched
#   t4 a native tab after them                -> named, numbered for slot 4
# ======================================================================
setup
export AUTO_INDEX=1 HOST_PREFIX=1
TAG="$(uname -n 2>/dev/null)"; TAG="${TAG%%.*}: "
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t3":{"auto":"claude","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"[1] api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"vps: [1] Build API","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t3","label":"[5] claude","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t4","label":"4","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,
     "cwd":"/home/u/.local/state/herdr-mirror/.mirror-pane"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,
     "foreground_cwd":"/home/u/.local/state/herdr-mirror/.mirror-pane"},
    {"pane_id":"p3","tab_id":"w1:t3","focused":true,"agent":"claude",
     "terminal_title_stripped":"Fix the login bug",
     "cwd":"/home/u/.local/state/herdr-mirror/.mirror-pane"},
    {"pane_id":"p4","tab_id":"w1:t4","focused":true,"cwd":"/home/u/dev/web"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"},
    {"tab_id":"w1:t3","focused_pane_id":"p3"},
    {"tab_id":"w1:t4","focused_pane_id":"p4"}
  ]
}}}
JSON
for p in p1 p2 p3; do
  fixture "procinfo_$p.json" <<JSON
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"/home/u/.local/bin/herdr-mirror",
    "cmdline":"/home/u/.local/bin/herdr-mirror pane w1:$p"}]}}}
JSON
done
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"nvim","cmdline":"nvim main.go"}]}}}
JSON
HOME=/home/u run_event tab.focused
out=$(log)
check_absent   "mirror: a remote host tag gets no number or local tag" "$out" "tab rename w1:t1"
check_absent   "mirror: a fresh mirror tab is not named"               "$out" "tab rename w1:t2"
check_absent   "mirror: an owned mirror tab is not renamed"            "$out" "tab rename w1:t3"
check_contains "mirror: a native tab after them keeps its slot"        "$out" "tab rename w1:t4 [4] web${SEP}nvim"
: >"$HERDR_MOCK_LOG"
HOME=/home/u run_event --clear
check_absent   "mirror: --clear leaves a mirror tab's number alone"    "$(log)" "tab rename w1:t3"
teardown

# ======================================================================
# Scenario: the per-list path knows its mirror tabs too, and so does a pass
#   that only numbers (NAME_TABS=0), which has no pane list of its own to read.
#   t1 is a background split, so no pane resolves for it at all: every pane of
#   the tab is asked, not just the one naming would pick.
# ======================================================================
for nt in 1 0; do
  setup
  export AUTO_INDEX=1 NAME_TABS=$nt
  fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
  fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"[4] Build API","pane_count":2,"focused":false},
  {"tab_id":"w1:t2","label":"[1] logs","pane_count":1,"focused":true}
]}}
JSON
  fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":false,"cwd":"/home/u/.local/state/herdr-mirror/.mirror-pane"},
  {"pane_id":"p2","tab_id":"w1:t1","focused":true,"cwd":"/home/u/.local/state/herdr-mirror/.mirror-pane"},
  {"pane_id":"p3","tab_id":"w1:t2","focused":true,"cwd":"/home/u/dev/web"}
]}}
JSON
  fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
  HOME=/home/u run_event tab.focused
  out=$(log)
  check_absent   "mirror, list path, NAME_TABS=$nt: the split mirror tab is untouched" "$out" "tab rename w1:t1"
  check_contains "mirror, list path, NAME_TABS=$nt: the tab after it is numbered 2"     "$out" "tab rename w1:t2 [2] "
  teardown
done

# ======================================================================
# Scenario: a per-list pass that cannot read the pane list cannot tell which
#   tabs are herdr-mirror's, so it writes no tab at all rather than number a
#   mirror tab on a socket blip. Every way the read can go wrong: the call
#   fails, it answers something that does not parse, or it parses but carries
#   no pane array (an error envelope, a null).
# ======================================================================
for how in fail garbled envelope null; do
  setup
  export AUTO_INDEX=1
  fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
  fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"Build API","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"logs","pane_count":1,"focused":false}
]}}
JSON
  case $how in
    fail)     export HERDR_MOCK_FAIL_VERB="pane list" ;;
    garbled)  printf 'not json\n' | fixture panes.json ;;
    envelope) printf '{"error":{"message":"socket closed"}}\n' | fixture panes.json ;;
    null)     printf '{"result":{"panes":null}}\n' | fixture panes.json ;;
  esac
  HOME=/home/u run_event tab.focused
  check_absent "no pane list ($how): no tab is written" "$(log)" "tab rename"
  unset HERDR_MOCK_FAIL_VERB
  teardown
done

t_summary
