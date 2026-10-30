#!/usr/bin/env bash
# Unit tests for ai.sh -- model-written tab labels, with a stub standing in for
# curl so the rules a label has to keep are checked without a model.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
SHELL_NAME=zsh
# shellcheck source=naming.sh
. "$here/../naming.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-ai.XXXXXX")
export XDG_STATE_HOME="$SB/state"
AI_TITLES=1
CURL_STUB="$SB/bin/curl"
mkdir -p "$SB/bin"; PATH="$SB/bin:$PATH"
export ANTHROPIC_API_KEY=test-key
AR_AI_CATALOG="$SB/catalog.json"
# shellcheck source=ai.sh
. "$here/../ai.sh"

# Where the tools are missing (stock macOS) the feature is off, which is the
# whole of what there is to check.
if ! ar_ai_ready; then
  ar_ai_title "Fix auth retry" "" api; check_rc "missing tools turn it off" 1 "$?"
  rm -rf "$SB"; t_summary; exit
fi

# The curl stub logs every call, its arguments, the headers it was handed as
# files and the request body, and answers in one reply that is both a Messages
# API response opening with a thinking block, as Haiku 5.5's does by default,
# and the gateway's chat completion, finished as $FINISH says (stop). reply
# <jq filter on the request> answers whatever the filter makes of it.
reply() { printf '#!/usr/bin/env bash\necho call >>%q\nprintf "%%s\\n" "$@" >%q\n: >%q\nfor a; do [[ $a == @/dev/fd/* ]] && cat "${a#@}" >>%q; done\ntee %q | jq -c %q\n' \
  "$SB/calls" "$SB/args" "$SB/headers" "$SB/headers" "$SB/body" \
  "($1) as \$t | {content: [{type: \"thinking\", thinking: \"\", signature: \"s\"}, {type: \"text\", text: \$t}],
    choices: [{index: 0, message: {role: \"assistant\", content: \$t}, finish_reason: \"${FINISH:-stop}\"}]}" \
  >"$CURL_STUB"; chmod +x "$CURL_STUB"; }
stub() { reply "$(jq -rn --arg t "$1" '$t | tojson')"; }
ask() { ar_ai_ask "Fix auth retry" 16 "" haiku -; }

stub "auth-retry"
check "a fitting answer after a thinking block is kept" "auth-retry" "$(ask)"
check "the key stays out of curl's arguments" "no" "$(grep -q test-key "$SB/args" && echo yes || echo no)"
check "and goes in a header" "x-api-key: test-key" "$(cat "$SB/headers")"
: >"$SB/calls"
check "no key, no answer" "" "$(ANTHROPIC_API_KEY='' AI_API_KEY_FILE=/nonexistent ask)"
check "and no call" "0" "$(wc -l <"$SB/calls" | tr -d ' ')"
printf 'OTHER_KEY=x\nANTHROPIC_API_KEY="file-key"\n' >"$SB/key"
check "the key file stands in for the variable" "auth-retry" "$(ANTHROPIC_API_KEY='' AI_API_KEY_FILE="$SB/key" ask)"
check "with its ANTHROPIC_API_KEY line" "x-api-key: file-key" "$(cat "$SB/headers")"
printf 'bare-key\n' >"$SB/bare"
ANTHROPIC_API_KEY='' AI_API_KEY_FILE="$SB/bare" ask >/dev/null
check "a bare key file is the key" "x-api-key: bare-key" "$(cat "$SB/headers")"
AI_API_KEY_FILE="$SB/key" ask >/dev/null
check "the variable wins over the file" "x-api-key: test-key" "$(cat "$SB/headers")"
printf 'OTHER_KEY=other-secret\nSECOND_KEY=second\n' >"$SB/other"
: >"$SB/calls"
check "a file without the entry answers nothing" "" "$(ANTHROPIC_API_KEY='' AI_API_KEY_FILE="$SB/other" ask)"
check "and sends no other secret" "0" "$(wc -l <"$SB/calls" | tr -d ' ')"
fkey() { printf "$1" >"$SB/f"; ar_ai_file_key "$SB/f" ANTHROPIC_API_KEY; }
check "export and indentation are read past" "k1" "$(fkey '  export ANTHROPIC_API_KEY = "k1"\n')"
check "single quotes come off" "k2" "$(fkey "ANTHROPIC_API_KEY='k2'\n")"
check "CRLF line endings are read past" "k3" "$(fkey '# note\r\nANTHROPIC_API_KEY=k3\r\n')"
check "the first entry wins" "k4" "$(fkey 'ANTHROPIC_API_KEY=k4\nANTHROPIC_API_KEY=k5\n')"
check "an empty entry is no key" "" "$(fkey 'ANTHROPIC_API_KEY=\n')"
check "a commented-out entry is no key" "" "$(fkey '# ANTHROPIC_API_KEY=k6\n')"
check "a lookalike name is no key" "" "$(fkey 'MY_ANTHROPIC_API_KEY=k7\n')"
check "two bare lines are no key" "" "$(fkey 'k8\nk9\n')"
printf 'ANTHROPIC_API_KEY=k1 # comment\n' >"$SB/f"
: >"$SB/calls"
ANTHROPIC_API_KEY='' AI_API_KEY_FILE="$SB/f" ask >/dev/null
check "a key with whitespace in it is not sent" "0" "$(wc -l <"$SB/calls" | tr -d ' ')"
stub $'`auth-retry`\nauth'
check "quotes come off, first fitting line wins" "auth-retry" "$(ask)"
stub $'auth-retry-backoff-fix\n[2] auth\nauth-backoff\nauth'
check "candidates over budget are skipped" "auth-backoff" "$(ask)"
stub "much-too-long-a-label"
check "an answer over budget is refused" "" "$(ask)"
stub "[3] auth"
check "the jump-number shape is refused" "" "$(ask)"
printf '#!/bin/sh\nexit 1\n' >"$CURL_STUB"
check "a failed call answers nothing" "" "$(ask)"

# A miss queues the title; the background worker has nothing to run here.
AR_ROOT="$SB/none"
ar_ai_title "Fix auth retry" "" api; check_rc "a miss is rc 1" 1 "$?"
check "and queues the title" "1" "$(find "$AR_AI_DIR/queue" -type f | wc -l | tr -d ' ')"
q=$(find "$AR_AI_DIR/queue" -type f)
check "the request records model and separator" "claude-haiku-5-5-" "$(head -2 "$q" | tr -d '\n')"
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
reply '.model'
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
touch "$req"   # not old: the worker expires pins past 30 days
stub "now-task"; ar_ai_worker
check "the answer replaces the pin" "now-task" "$(cat "$AR_AI_PINS/s1")"
check "and leaves nothing in the queue" "" "$(ls -A "$AR_AI_DIR/queue")"
cp "$SB/pinreq" "$req"
printf '#!/bin/sh\nexit 1\n' >"$CURL_STUB"; ar_ai_worker
check "a failed retitle keeps the pin" "now-task" "$(cat "$AR_AI_PINS/s1")"
# The agent left the tab while the call was out: its pin is gone, and stays so.
cp "$SB/pinreq" "$req"; rm -f "$AR_AI_PINS/s1"
stub "late-answer"; ar_ai_worker
check "a retitle for a dropped pin is dropped" "no" "$([ -e "$AR_AI_PINS/s1" ] && echo yes || echo no)"

# Two herdr sessions retitling the same tab id queue two requests, not one.
AR_ROOT="$SB/none"
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
# the system prompt asks for words joined by one.
reply 'if (.system | contains("joined by \" \"")) then "space" else "other" end'
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

# ---- llm-gateway ----
# Both branches run from one shared config, the token file's presence the only
# difference, and each request is compared with llm-gateway's fixture of
# today's call: its upstream body for the direct branch, its gateway_request
# for the gateway one.
FX="$here/fixtures/llm-gateway/automatic-rename__tab-label.json"
printf 'LLM_GATEWAY_TOKEN=lgw_test-token\n' >"$SB/token"
AR_ROOT="$SB/root"
# parity <token file> - one title through the queue and the worker, as an
# event and the worker it spawns would run it.
parity() {
  rm -rf "$AR_AI_DIR"; : >"$SB/body"
  AI_GATEWAY_TOKEN_FILE=$1 MAX_TITLE_LEN=16 ar_ai_title "Fix the login redirect bug" "" demo
  AI_GATEWAY_TOKEN_FILE=$1 ar_ai_worker
}
answer() { find "$AR_AI_DIR" -maxdepth 1 -type f ! -name lock -exec cat {} +; }
url() { grep -x 'https*://.*' "$SB/args"; }
# The -H arguments and the header files, one header per line.
sent_headers() { awk 'p { print; p = 0 } $0 == "-H" { p = 1 }' "$SB/args" | grep -v '^@'; cat "$SB/headers"; }
names() { cut -d: -f1 | grep -vix content-type | sort | paste -sd, -; }
# The gateway's catalog snapshot, with a provider this plugin has never heard of.
snapshot() {
  jq -n '{schema: 1, revision: "r", efforts: ["none","minimal","low","medium","high","xhigh","max"],
    providers: {anthropic: {label: "Anthropic"}, newprov: {label: "New"}},
    models: [{id: "anthropic/claude-haiku-5-5", provider: "anthropic"}, {id: "newprov/fast-1", provider: "newprov"}]}' >"$AR_AI_CATALOG"
}
snapshot
stub "login-redirect"

parity /nonexistent
check "direct: today's body, unchanged" "$(jq -cS .upstream.body "$FX")" "$(jq -cS . "$SB/body")"
check "direct: to today's URL" "$(jq -r .upstream.url "$FX")" "$(url)"
check "direct: the key in x-api-key" "x-api-key: test-key" "$(cat "$SB/headers")"
check_contains "direct: today's anthropic-version" "$(sent_headers)" "anthropic-version: 2023-06-01"
check "direct: the label lands" "login-redirect" "$(answer)"

parity "$SB/token"
check "gateway: the fixture's gateway_request body" "$(jq -cS .gateway_request.body "$FX")" "$(jq -cS . "$SB/body")"
check "gateway: to its path on loopback" "http://127.0.0.1:8011$(jq -r .gateway_request.path "$FX")" "$(url)"
check "gateway: the fixture's headers" "$(jq -r '.gateway_request.headers | keys[]' "$FX" | names)" "$(sent_headers | names)"
check "gateway: the token as a bearer, from the token file" "Authorization: Bearer lgw_test-token" "$(cat "$SB/headers")"
check "gateway: the fixture's deadline" "X-Gateway-Deadline: $(jq -r '.gateway_request.headers["X-Gateway-Deadline"]' "$FX")" \
  "$(sent_headers | grep '^X-Gateway-Deadline:')"
check "gateway: the token stays out of curl's arguments" "no" "$(grep -q lgw_test-token "$SB/args" && echo yes || echo no)"
check "gateway: the label lands" "login-redirect" "$(answer)"
rm -f "$AR_AI_CATALOG"; parity "$SB/token"
check "gateway: the same request with no snapshot to read" "$(jq -cS .gateway_request.body "$FX")" "$(jq -cS . "$SB/body")"
snapshot

# Asked once each way under the same title: the model is in the cache key.
rm -rf "$AR_AI_DIR"; AR_ROOT="$SB/none"
AI_GATEWAY_TOKEN_FILE=/nonexistent MAX_TITLE_LEN=16 ar_ai_title "T" "" demo
AI_GATEWAY_TOKEN_FILE="$SB/token" MAX_TITLE_LEN=16 ar_ai_title "T" "" demo
check "each mode queues its own request" "2" "$(find "$AR_AI_DIR/queue" -type f | wc -l | tr -d ' ')"
gw_req=$(grep -l / "$AR_AI_DIR"/queue/*)
check "the gateway one records a provider/model id and its effort" "anthropic/claude-haiku-5-5 low" \
  "$(printf '%s %s' "$(sed -n 1p "$gw_req")" "$(sed -n 7p "$gw_req")")"
# A direct key is the one it always was, so answers cached before this change are still found.
old_key=$(printf '%s\037%s\037%s\037%s\037%s' claude-haiku-5-5 - 16 demo T | md5sum); old_key=${old_key%% *}
check "a direct request keeps its old cache key" "yes" "$([ -e "$AR_AI_DIR/queue/$old_key" ] && echo yes || echo no)"
check "and records no effort" "" "$(sed -n 7p "$AR_AI_DIR/queue/$old_key")"
AI_GATEWAY_TOKEN_FILE="$SB/token" AI_GATEWAY_EFFORT=high MAX_TITLE_LEN=16 ar_ai_title "T" "" demo
check "a gateway effort is in the cache key" "3" "$(find "$AR_AI_DIR/queue" -type f | wc -l | tr -d ' ')"
# A request is answered the way it was asked, whichever mode the worker is in.
rm -f "$AR_AI_DIR"/queue/*
AI_GATEWAY_TOKEN_FILE=/nonexistent MAX_TITLE_LEN=16 ar_ai_title "T" "" demo
AR_ROOT="$SB/root"; AI_GATEWAY_TOKEN_FILE="$SB/token" ar_ai_worker
check "a direct request queued before the token file came goes direct" "$(jq -r .upstream.url "$FX")" "$(url)"
# And at the effort it was asked at, whatever the worker's config says now.
rm -rf "$AR_AI_DIR"; AR_ROOT="$SB/none"
AI_GATEWAY_TOKEN_FILE="$SB/token" AI_GATEWAY_EFFORT=high MAX_TITLE_LEN=16 ar_ai_title "T" "" demo
AR_ROOT="$SB/root"; AI_GATEWAY_TOKEN_FILE="$SB/token" AI_GATEWAY_EFFORT=medium ar_ai_worker
check "the recorded effort answers, not the current one" "high" "$(jq -r .reasoning_effort "$SB/body")"
printf 'anthropic/claude-haiku-5-5\n-\n16\ndemo\nTask title: T\n' >"$AR_AI_DIR/queue/no-effort"
AI_GATEWAY_TOKEN_FILE="$SB/token" ar_ai_worker
check "a gateway request recorded without an effort asks at low" "low" "$(jq -r .reasoning_effort "$SB/body")"
AR_ROOT="$SB/none"

gask() { AI_GATEWAY_TOKEN_FILE=${2:-$SB/token} ar_ai_ask "Fix auth retry" 16 "" "${1:-anthropic/claude-haiku-5-5}" - "${3:-}"; }
check "gateway: an answer that finished is kept" "auth-retry" "$(stub auth-retry; gask)"
FINISH=length stub "auth-retry"
check "gateway: one that did not finish is refused" "" "$(gask)"
stub "auth-retry"
check "gateway: the Anthropic key is never sent" "no" "$(gask >/dev/null; grep -q test-key "$SB/args" "$SB/headers" && echo yes || echo no)"
: >"$SB/calls"; : >"$SB/empty"
check "gateway: an empty token file answers nothing" "" "$(gask "" "$SB/empty")"
check "gateway: an Anthropic key in its place is no token" "" "$(gask "" "$SB/key")"
check "and neither makes a call" "0" "$(wc -l <"$SB/calls" | tr -d ' ')"
printf '#!/bin/sh\nexit 22\n' >"$CURL_STUB"
check "gateway: a refused call answers nothing" "" "$(gask)"

# A usable body is no answer when the transfer failed or the JSON breaks off
# after it, on either path.
broken() { # <exit status> <trailing bytes>
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s%%s" %q %q\nexit %s\n' \
    '{"content":[{"type":"text","text":"auth-retry"}],"choices":[{"message":{"content":"auth-retry"},"finish_reason":"stop"}]}' \
    "$2" "$1" >"$CURL_STUB"
}
broken 28 ""
check "direct: a cut-off transfer answers nothing" "" "$(ask)"
check "gateway: a cut-off transfer answers nothing" "" "$(gask)"
broken 0 '{"content'
check "direct: malformed trailing JSON answers nothing" "" "$(ask)"
check "gateway: malformed trailing JSON answers nothing" "" "$(gask)"
broken 0 ""
check "the same body whole is an answer" "auth-retry auth-retry" "$(ask) $(gask)"

# Options from the gateway's catalog snapshot: a provider added there is
# usable with no change here, and a pick it no longer offers, or any pick when
# no snapshot loads, falls back to the explicit default.
reply '"\(.model) \(.reasoning_effort)"'
pick() { AI_GATEWAY_MODEL=$1 AI_GATEWAY_EFFORT=$2 ar_ai_model; gask "$AR_AI_MODEL" "" "$AR_AI_EFFORT" >/dev/null; jq -r '"\(.model) \(.reasoning_effort)"' "$SB/body"; }
AI_GATEWAY_TOKEN_FILE="$SB/token"
snapshot
check "a new provider's model is sent as picked" "newprov/fast-1 high" "$(pick newprov/fast-1 high)"
check "a pick the snapshot lacks falls back to AI_TITLE_MODEL" "anthropic/claude-haiku-5-5 medium" "$(pick gone/model-1 medium)"
check "an effort it does not know falls back to low" "newprov/fast-1 low" "$(pick newprov/fast-1 turbo)"
AI_GATEWAY_MODEL=claude-sonnet-5-5 ar_ai_model
check "a bare pick is an Anthropic one" "anthropic/claude-sonnet-5-5" "$AR_AI_MODEL"
rm -f "$AR_AI_CATALOG"
check "without a snapshot, the default model and low" "anthropic/claude-haiku-5-5 low" "$(pick newprov/fast-1 high)"
printf '{"schema": 2, "models": [{"id": "newprov/fast-1"}], "efforts": ["high"]}' >"$AR_AI_CATALOG"
check "with one of an unknown schema, the same" "anthropic/claude-haiku-5-5 low" "$(pick newprov/fast-1 high)"
snapshot; chmod 000 "$AR_AI_CATALOG"
if [ -r "$AR_AI_CATALOG" ]; then
  check "an unreadable snapshot (skipped: running as root)" "" ""
else
  check "with an unreadable one, the same" "anthropic/claude-haiku-5-5 low" "$(pick newprov/fast-1 high)"
fi
chmod 600 "$AR_AI_CATALOG"
unset AI_GATEWAY_TOKEN_FILE
AI_GATEWAY_TOKEN_FILE=/nonexistent AI_GATEWAY_MODEL=newprov/fast-1 ar_ai_model
check "without the token file the gateway pick is not used" "claude-haiku-5-5" "$AR_AI_MODEL"

rm -rf "$SB"
t_summary
