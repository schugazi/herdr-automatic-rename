#!/usr/bin/env bash
# Unit tests for transcript.sh -- what a Claude Code session says it is about,
# read from the transcript the agent appends to.
#
# The fixtures are hand-written JSONL in the shapes a real transcript carries
# (checked against live ones): the newer form, which marks what the user typed
# with origin.kind, and an older form that marks nothing at all.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
# ar_case, which the topic is folded through, lives in naming.sh.
SHELL_NAME=zsh
# shellcheck source=naming.sh
. "$here/../naming.sh"
# The engine too, for the jq definitions a topic is cleaned and folded through
# (AR_JQ_CLEAN / AR_JQ_TASK) and for AR_ROW_SEP. Sourcing it defines its
# functions and runs nothing, which is what tests/test_naming.sh relies on too.
# shellcheck source=automatic-rename.sh
. "$here/../automatic-rename.sh"
# shellcheck source=transcript.sh
. "$here/../transcript.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-tr.XXXXXX")
export CLAUDE_CONFIG_DIR="$SB/claude"
ID=647693ed-d633-4871-b7ee-5f5e4b5728ea
DIR=/Users/tester/dev/api
SLUG=-Users-tester-dev-api
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG"
FILE="$CLAUDE_CONFIG_DIR/projects/$SLUG/$ID.jsonl"

topic_of() {
  if ar_transcript_topic "${3:-claude}" "$1" "$2"; then printf '%s' "$AR_TRANSCRIPT_TOPIC"
  else printf -- '-'; fi
}

# ---- the title the agent generated ----
# Claude Code writes one of these every time it renames the session, so the LAST
# one is the session's current name.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"add a retry to the uploader"},"origin":{"kind":"human"}}
{"type":"ai-title","aiTitle":"Uploader retries","sessionId":"x"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
{"type":"ai-title","aiTitle":"Uploader retry backoff","sessionId":"x"}
JSON
check "the last generated title wins" "Uploader retry backoff" "$(topic_of "$ID" "$DIR")"
check "and is folded for comparison" "uploader retry backoff" \
  "$(ar_transcript_topic claude "$ID" "$DIR" && printf '%s' "$AR_TRANSCRIPT_TOPIC_LC")"

# ---- the first prompt, when there is no title yet ----
# The case this exists for: a session that has said nothing Claude Code could
# derive a title from still opened with something.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"add a retry to the uploader"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":"and a test for it"},"origin":{"kind":"human"}}
JSON
check "the first typed prompt names it" "add a retry to the uploader" "$(topic_of "$ID" "$DIR")"

# A prompt runs to a paragraph; a tab shows its first line, and the budget the
# label gets cuts the rest (ar_format).
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"fix the flaky test\n\nit fails on CI only"},"origin":{"kind":"human"}}
JSON
check "only the first line of a prompt" "fix the flaky test" "$(topic_of "$ID" "$DIR")"

# ---- a session opened with a slash command ----
# THE case this feature exists for: Claude Code derives its terminal title from
# what the user typed, so a session opened this way and answered by the agent
# alone never gets one, and the tab read "claude" for as long as it ran.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>spec.md</command-args>"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/tester/.claude/skills/code-review"}]},"origin":{"kind":"human"}}
JSON
check "a slash command, with what it was called with" "code-review spec.md" "$(topic_of "$ID" "$DIR")"

cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"<command-name>/standup</command-name>\n<command-args></command-args>"},"origin":{"kind":"human"}}
JSON
check "a slash command with no arguments" "standup" "$(topic_of "$ID" "$DIR")"

# ---- what is NOT the user talking ----
# A slash command expands into the conversation as further user messages, a tool
# answers with its output, and a resumed session opens with a caveat the tool
# wrote. Naming a tab after any of those names it after the plumbing.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"total 432"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"This session is being continued from a previous conversation"}]}}
{"type":"user","message":{"role":"user","content":"the real question"},"origin":{"kind":"human"}}
JSON
check "a tool result is not a prompt" "the real question" "$(topic_of "$ID" "$DIR")"

# A message that is nothing but markup the tool wrapped has nothing left once the
# markup goes, and the read moves on to the next line.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"<system-reminder>be careful</system-reminder>"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":"what is actually being asked"},"origin":{"kind":"human"}}
JSON
check "a message of pure markup is skipped" "what is actually being asked" "$(topic_of "$ID" "$DIR")"

# ---- an older transcript, with no marker at all ----
# origin.kind is recent. In a transcript without it, a message whose content is a
# plain STRING is the same thing by another road: everything the tool injects
# arrives as blocks.
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"<command-name>/give-review</command-name>\n<command-args>PR 8806</command-args>"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/tester/.claude/skills/give-review"}]}}
JSON
check "an unmarked transcript still reads" "give-review PR 8806" "$(topic_of "$ID" "$DIR")"

# ---- nothing to say ----
: >"$FILE"
check "an empty transcript says nothing" "-" "$(topic_of "$ID" "$DIR")"
cat >"$FILE" <<'JSON'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
JSON
check "an agent talking to itself says nothing" "-" "$(topic_of "$ID" "$DIR")"
# A transcript that has stopped carrying the fields this reads is the failure
# mode to have: nothing, and the tab is named as it was before this existed.
cat >"$FILE" <<'JSON'
{"kind":"something-else","payload":{"body":"a format we do not know"}}
JSON
check "an unknown format says nothing" "-" "$(topic_of "$ID" "$DIR")"
# The agent may be writing a line while this reads, and both reads cut one.
printf '{"type":"user","message":{"role":"user","content":"complete line"},"origin":{"kind":"human"}}\n{"type":"user","mess' >"$FILE"
check "a half-written line is skipped" "complete line" "$(topic_of "$ID" "$DIR")"

# ---- finding the file ----
cat >"$FILE" <<'JSON'
{"type":"ai-title","aiTitle":"Found anyway","sessionId":"x"}
JSON
# A pane that has cd'd since the session started files it under another project,
# and only the whole projects directory says where.
check "a session filed under another project" "Found anyway" "$(topic_of "$ID" /somewhere/else)"
check "no session id, no read" "-" "$(topic_of "" "$DIR")"
# The id becomes part of a path, so it is refused unless it is shaped like one.
check "a path traversal is refused" "-" "$(topic_of "../../etc/passwd" "$DIR")"
# ... and refused because of its SHAPE, not because the file happened not to be
# there: an id that is not a uuid never becomes part of a path at all.
cat >"$CLAUDE_CONFIG_DIR/projects/$SLUG/notauuid.jsonl" <<'JSON'
{"type":"ai-title","aiTitle":"Should never be read","sessionId":"x"}
JSON
check "an id that is not a uuid is refused" "-" "$(topic_of notauuid "$DIR")"
check "an unknown session is not there" "-" \
  "$(topic_of 00000000-0000-0000-0000-000000000000 "$DIR")"
check "AGENT_TRANSCRIPT=0 reads nothing" "-" "$(AGENT_TRANSCRIPT=0 topic_of "$ID" "$DIR")"
# Only Claude Code keeps its sessions in this shape and this place. Another
# agent's pane can carry a session value of its own -- or a stale one left by a
# claude that ran there before -- and reading it here would put one agent's
# prompts on another agent's tab.
cat >"$FILE" <<'JSON'
{"type":"ai-title","aiTitle":"Belongs to claude","sessionId":"x"}
JSON
check "another agent's pane is not read" "-" "$(topic_of "$ID" "$DIR" codex)"
check "and the kind is compared exactly" "-" "$(topic_of "$ID" "$DIR" Claude)"

# ---- the latest prompts, for an AI retitle ----
cat >"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"one"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}
{"type":"user","message":{"role":"user","content":"two"},"origin":{"kind":"human"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
{"type":"user","message":{"role":"user","content":"three"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":"four"},"origin":{"kind":"human"}}
JSON
check "the last three typed prompts, oldest first" "two | three | four" "$(ar_transcript_recent claude "$ID" "$DIR")"
cat >>"$FILE" <<'JSON'
{"type":"user","message":{"role":"user","content":"<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>auth.sh</command-args>"},"origin":{"kind":"human"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /home/u/.claude/skills/code-review"}]},"origin":{"kind":"human"}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x"}]}}
{"type":"user","message":{"role":"user","content":"[Subagent hand-back] report"},"origin":{"kind":"peer"}}
JSON
check "skill expansions and other agents are not the user" "three | four | code-review auth.sh" \
  "$(ar_transcript_recent claude "$ID" "$DIR")"
check "only for claude" "" "$(ar_transcript_recent codex "$ID" "$DIR")"

rm -rf "$SB"
t_summary
