#!/usr/bin/env bash
# Unit tests for ai.sh -- model-written tab labels, with a stub standing in for
# claude so the rules a label has to keep are checked without a model.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
SHELL_NAME=zsh
# shellcheck source=naming.sh
. "$here/../naming.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-ai.XXXXXX")
export XDG_STATE_HOME="$SB/state"
AI_TITLES=1
AI_CLAUDE="$SB/claude"
# shellcheck source=ai.sh
. "$here/../ai.sh"

# Where the tools are missing (stock macOS) the feature is off, which is the
# whole of what there is to check.
if ! ar_ai_ready; then
  ar_ai_title "Fix auth retry" "" api; check_rc "missing tools turn it off" 1 "$?"
  rm -rf "$SB"; t_summary; exit
fi

# The stub answers with its arguments' --model value unless told otherwise, and
# logs every call.
stub() { printf '#!/usr/bin/env bash\necho call >>%q\nprintf "%%s" %q\n' "$SB/calls" "$1" >"$AI_CLAUDE"; chmod +x "$AI_CLAUDE"; }
ask() { ar_ai_ask "Fix auth retry" 16 "" haiku -; }

stub "auth-retry"
check "a fitting answer is kept" "auth-retry" "$(ask)"
stub $'`auth-retry`\nauth'
check "quotes come off, first fitting line wins" "auth-retry" "$(ask)"
stub $'auth-retry-backoff-fix\n[2] auth\nauth-backoff\nauth'
check "candidates over budget are skipped" "auth-backoff" "$(ask)"
stub "much-too-long-a-label"
check "an answer over budget is refused" "" "$(ask)"
stub "[3] auth"
check "the jump-number shape is refused" "" "$(ask)"
printf '#!/bin/sh\nexit 1\n' >"$AI_CLAUDE"
check "a failed call answers nothing" "" "$(ask)"

# A miss queues the title; the background worker has nothing to run here.
AR_ROOT="$SB/none"
ar_ai_title "Fix auth retry" "" api; check_rc "a miss is rc 1" 1 "$?"
check "and queues the title" "1" "$(find "$AR_AI_DIR/queue" -type f | wc -l | tr -d ' ')"
q=$(find "$AR_AI_DIR/queue" -type f)
check "the request records model and separator" "haiku-" "$(head -2 "$q" | tr -d '\n')"
printf 'auth-retry' >"$AR_AI_DIR/${q##*/}"
rm -f "$q"
ar_ai_title "Fix auth retry" "" api
check "a hit returns the cached label" "auth-retry" "$AR_AI_TITLE"
MAX_TITLE_LEN=12 ar_ai_title "Fix auth retry" "" api; check_rc "a different budget is a different key" 1 "$?"
TITLE_WORD_SEPARATOR=_ ar_ai_title "Fix auth retry" "" api; check_rc "so is a different separator" 1 "$?"
# Two characters of reserve in any locale, so the budget, and the key, agree.
rm -f "$AR_AI_DIR"/queue/*
LC_ALL=C ar_ai_title "Fix auth retry" $'\xcf\x80 ' api; c_key=$(ls "$AR_AI_DIR/queue")
rm -f "$AR_AI_DIR"/queue/*
LC_ALL=C.UTF-8 ar_ai_title "Fix auth retry" $'\xcf\x80 ' api
check "the reserve is measured in codepoints" "$c_key" "$(ls "$AR_AI_DIR/queue")"
check "the budget is MAX_TITLE_LEN (28) less 2" "26" "$(sed -n 3p "$AR_AI_DIR/queue/$c_key")"

# ---- the worker ----
mkdir -p "$SB/root"
printf '#!/usr/bin/env bash\necho "$1" >>%q\n' "$SB/reconciled" >"$SB/root/automatic-rename.sh"
AR_ROOT="$SB/root"
rm -rf "$AR_AI_DIR"; mkdir -p "$AR_AI_DIR/queue"
printf '#!/usr/bin/env bash\necho call >>%q\nprintf "%%s" "$3"\n' "$SB/calls" >"$AI_CLAUDE"
: >"$SB/calls"
printf 'm-old\n-\n16\napi\nFix auth retry\n' >"$AR_AI_DIR/queue/k1"
printf '\n\n\n\n\n' >"$AR_AI_DIR/queue/k2"
printf 'half' >"$AR_AI_DIR/queue/.k3.1"
AI_TITLE_MODEL=m-new ar_ai_worker
check "the recorded model answers, not the current one" "m-old" "$(cat "$AR_AI_DIR/k1")"
check "a malformed request costs no call" "1" "$(wc -l <"$SB/calls" | tr -d ' ')"
check "and is dropped" "" "$(ls "$AR_AI_DIR/queue")"
check "an unpublished request is not read" "no" "$([ -e "$AR_AI_DIR/k3" ] && echo yes || echo no)"
check "one reconcile follows" "ai-title" "$(cat "$SB/reconciled")"
: >"$SB/reconciled"
ar_ai_worker
check "an idle worker reconciles nothing" "" "$(cat "$SB/reconciled")"
# Events while a call is out re-queue its title; the answer is not paid twice.
printf 'm\n-\n16\napi\nFix auth retry\n' >"$AR_AI_DIR/queue/k1"
: >"$SB/calls"; ar_ai_worker
check "an answered request is not asked again" "0" "$(wc -l <"$SB/calls" | tr -d ' ')"

# ---- pins and retitle ----
rm -rf "$AR_AI_DIR"
AR_ROOT="$SB/none"
AR_PANE_AGENT=claude AR_PANE_SESSION=s1 AR_PANE_DIR=/x
ar_transcript_recent() { printf 'p1 | p2'; }
ar_ai_title "First task" "" api                 # queue it, then answer it
q=$(find "$AR_AI_DIR/queue" -type f); printf 'first-task' >"$AR_AI_DIR/${q##*/}"; rm -f "$q"
ar_ai_label w1:t1 "First task" "" api
check "the first label is used" "first-task" "$AR_AI_TITLE"
check "and pinned to the session" "first-task" "$(cat "$AR_AI_PINS/s1")"
ar_ai_label w1:t1 "Some later title" "" api
check "a later title keeps the pin" "first-task" "$AR_AI_TITLE"
check "and asks nothing" "" "$(ls "$AR_AI_DIR/queue")"
AR_PANE_SESSION=s2 ar_ai_label w1:t1 "Some later title" "" api; check_rc "a new session starts over" 1 "$?"
rm -f "$AR_AI_DIR"/queue/*

ar_ai_pinned w1:t1
check "a pin stands in for a title that says nothing" "first-task" "$AR_AI_TITLE"

# Another herdr session numbers its tabs the same way, and must not take this
# session's mark.
mkdir -p "$AR_AI_MARKS"; : >"$AR_AI_MARKS/w1_t1"
AR_AI_MARKS="$SB/other/ai-retitle" AR_AI_PINS="$SB/other/ai-pins" ar_ai_label w1:t1 "Some later title" "" api
check "another session leaves the mark alone" "yes" "$([ -e "$AR_AI_MARKS/w1_t1" ] && echo yes || echo no)"
rm -f "$AR_AI_DIR"/queue/*

ar_ai_label w1:t1 "Some later title" "" api
check "a retitle keeps the old pin while it waits" "first-task" "$AR_AI_TITLE"
check "and consumes its mark" "no" "$([ -e "$AR_AI_MARKS/w1_t1" ] && echo yes || echo no)"
req=$(find "$AR_AI_DIR/queue" -name 'pin-*')
check "and queues the latest prompts for the pin" "$AR_AI_PINS/s1" "$(sed -n 6p "$req")"
check_contains "the request carries the prompts" "$(sed -n 5p "$req")" "p1 | p2"
cp "$req" "$SB/pinreq"
AR_ROOT="$SB/root"
stub "now-task"; ar_ai_worker
check "the answer replaces the pin" "now-task" "$(cat "$AR_AI_PINS/s1")"
cp "$SB/pinreq" "$req"
printf '#!/bin/sh\nexit 1\n' >"$AI_CLAUDE"; ar_ai_worker
check "a failed retitle keeps the pin" "now-task" "$(cat "$AR_AI_PINS/s1")"
# The agent left the tab while the call was out: its pin is gone, and stays so.
cp "$SB/pinreq" "$req"; rm -f "$AR_AI_PINS/s1"
stub "late-answer"; ar_ai_worker
check "a retitle for a dropped pin is dropped" "no" "$([ -e "$AR_AI_PINS/s1" ] && echo yes || echo no)"

# Two herdr sessions retitling the same tab id queue two requests, not one.
rm -f "$AR_AI_DIR"/queue/*
AR_PANE_SESSION=""
for s in a b; do
  mkdir -p "$SB/$s/ai-retitle"; : >"$SB/$s/ai-retitle/w1_t1"
  AR_AI_MARKS="$SB/$s/ai-retitle" AR_AI_PINS="$SB/$s/ai-pins" ar_ai_label w1:t1 "T" "" api
done
check "each session's retitle keeps its own request" "2" "$(find "$AR_AI_DIR/queue" -name 'pin-*' | wc -l | tr -d ' ')"
rm -f "$AR_AI_DIR"/queue/*
AR_PANE_SESSION=s1

# A separator of one space survives the queue. The stub answers "space" when
# the system prompt (its 11th argument) asks for words joined by one.
printf '#!/usr/bin/env bash\n[[ ${11} == *%q* ]] && printf space || printf other\n' 'joined by " "' >"$AI_CLAUDE"
printf 'm\n \n16\n\nT\n' >"$AR_AI_DIR/queue/sp"
ar_ai_worker
check "a space separator reaches the model" "space" "$(cat "$AR_AI_DIR/sp")"

# A retitle that lands between the pin check and the first pin's write wins.
rm -f "$AR_AI_PINS/s1"
got=$(ar_ai_title() { ar_ai_put "$AR_AI_PIN" "retitled"; AR_AI_TITLE=first; }
      ar_ai_label w1:t1 "First task" "" api; printf '%s' "$AR_AI_TITLE")
check "the first pin never replaces a newer one" "retitled" "$got"
check "and the newer pin is what is shown" "retitled" "$(cat "$AR_AI_PINS/s1")"

# An agent with no session is pinned by its tab, until the tab has no agent.
AR_PANE_SESSION=""
printf 'old-agent' >"$AR_AI_PINS/tab-w1_t2"
ar_ai_pinned w1:t2; check "a sessionless agent is pinned by its tab" "old-agent" "$AR_AI_TITLE"
ar_ai_unpin_tab w1:t2
ar_ai_pinned w1:t2; check_rc "and the pin goes with the agent" 1 "$?"

rm -rf "$SB"
t_summary
