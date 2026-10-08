# ai.sh - agent tab labels written by a small model instead of cut from a title.
#
# Sourced by automatic-rename.sh beside transcript.sh. A model call takes seconds
# and a reconcile runs on every event, so naming never waits for one: a title
# with a cached answer gets it, and a title without one is queued for a
# background worker, keeps the condensed label meanwhile, and is relabeled by the
# full reconcile the worker runs when it is done.
#
# The first label a session gets is PINNED: later title changes leave the tab
# alone, so a tab keeps the name it was given at the start. The `retitle` action
# (a keybinding) replaces the pin with a label for what the session is doing
# now, written from its latest prompts.
#
# Checked on its own by shellcheck, where AR_AI_TITLE has no reader in sight.
# shellcheck disable=SC2034

: "${AI_TITLES:=0}"            # 1 = ask a model for agent tab labels
: "${AI_TITLE_MODEL:=claude-haiku-5-5}"  # any Anthropic API model id
: "${AI_API_URL:=https://api.anthropic.com/v1/messages}"
# The API key: $ANTHROPIC_API_KEY when set, else this file's ANTHROPIC_API_KEY=
# line (read, never sourced), or the whole file when it is a bare key.
: "${AI_API_KEY_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/anthropic/secrets.env}"

# Answers to a title are shared by every herdr session; the queue and worker
# with them. Pins and retitle marks are not: every session numbers its tabs from
# w1:t1, so they live under STATE_DIR, which automatic-rename.sh already scopes
# to the session.
AR_AI_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-automatic-rename/ai-titles"
AR_AI_PINS="${STATE_DIR:-$AR_AI_DIR}/ai-pins"
AR_AI_MARKS="${STATE_DIR:-$AR_AI_DIR}/ai-retitle"

# ar_ai_ready -> 0 when the tools the queue and worker lean on are all present.
# Stock macOS has none of them, and there the feature is off rather than broken:
# naming falls back to the condensed title. Asked once per process.
ar_ai_ready() {
  if [ -z "${_ar_ai_ready:-}" ]; then
    local c
    _ar_ai_ready=1
    for c in md5sum setsid flock curl; do
      command -v "$c" >/dev/null 2>&1 || { _ar_ai_ready=0; break; }
    done
  fi
  [ "$_ar_ai_ready" = 1 ]
}

# ar_ai_id <string> -> the string with anything unsafe in a file name replaced.
ar_ai_id() { printf '%s' "${1//[!A-Za-z0-9._-]/_}"; }

# ar_ai_put <file> <text> - replace <file> with <text> in one rename, so no
# reader ever sees it empty or half-written.
ar_ai_put() {
  printf '%s' "$2" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1" || rm -f "$1.tmp.$$"
}

# ar_ai_pin <tab_id> -> sets AR_AI_PIN to the file holding this tab's pinned
# label. Keyed by the agent's session, so a new session in the same tab starts
# over; an agent herdr reports no session for is pinned by its tab, and that
# pin is dropped once the tab has no agent (ar_ai_unpin_tab). Reads
# AR_PANE_SESSION, from the pane facts ar_tab_name has already loaded.
ar_ai_pin() {
  if [ -n "${AR_PANE_SESSION:-}" ]; then
    AR_AI_PIN="$AR_AI_PINS/${AR_PANE_SESSION//[!A-Za-z0-9._-]/_}"
  else
    AR_AI_PIN="$AR_AI_PINS/tab-${1//[!A-Za-z0-9._-]/_}"
  fi
}

# ar_ai_pinned <tab_id> -> sets AR_AI_TITLE to the tab's pinned label; rc 1
# when it has none. What an agent tab shows while its title says nothing.
ar_ai_pinned() {
  AR_AI_TITLE=""
  [ "${AI_TITLES:-0}" = "1" ] || return 1
  ar_ai_pin "$1"
  [ -s "$AR_AI_PIN" ] || return 1
  AR_AI_TITLE=$(<"$AR_AI_PIN")
  [ -n "$AR_AI_TITLE" ]
}

# ar_ai_unpin_tab <tab_id> - drop a tab-keyed pin: the agent it named is gone,
# and the next agent in this tab gets a label of its own. Tests before it
# forks, since this runs for every tab without an agent.
ar_ai_unpin_tab() {
  local f="$AR_AI_PINS/tab-${1//[!A-Za-z0-9._-]/_}"
  [ -e "$f" ] && rm -f "$f"
  return 0
}

# ar_ai_budget <reserve> -> sets AR_AI_BUDGET to MAX_TITLE_LEN less <reserve>,
# the literal text that will share the label (icon, name prefix); rc 1 when
# nothing is left. Measured in codepoints, not with ${#}, which counts bytes
# under a C locale: herdr events and shell-started passes would otherwise ask
# for two budgets, cache two answers, and flip the tab between them.
ar_ai_budget() {
  local n=${#1}
  case $1 in
  *[!$'\01'-$'\177']*) n=$(printf '%s' "$1" | jq -Rrs 'length' 2>/dev/null) || return 1 ;;
  esac
  AR_AI_BUDGET=$(( ${MAX_TITLE_LEN:-28} - n ))
  [ "$AR_AI_BUDGET" -gt 0 ]
}

# ar_ai_enqueue <name> <budget> <workspace> <message> [<pin file>] - queue one
# model request and wake the worker. With a pin file the answer replaces that
# pin; without one it is cached under <name>.
#
# Written beside the queue under a dot name the worker's glob skips, then
# renamed in, so the worker never reads a request half-written. The request
# carries the model and separator it was made under, so a worker started under
# an older config answers it the way the request says.
ar_ai_enqueue() {
  local q="$AR_AI_DIR/queue/.$1.$$"
  mkdir -p "$AR_AI_DIR/queue" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$AI_TITLE_MODEL" "${TITLE_WORD_SEPARATOR:--}" \
    "$2" "$3" "$4" "${5:-}" >"$q" && mv -f "$q" "$AR_AI_DIR/queue/$1" || { rm -f "$q"; return 1; }
  # Detached and with every stream closed: this runs inside the command
  # substitution that captures the tab's name, which would otherwise wait out
  # the model call.
  (setsid bash "$AR_ROOT/automatic-rename.sh" ai-worker </dev/null >/dev/null 2>&1 &)
}

# ar_ai_cached <file> -> 0 when <file> holds an answer, or a failure younger
# than an hour. Either way the title is not asked again: a network outage must
# not become a model call on every event.
ar_ai_cached() {
  [ -f "$1" ] || return 1
  [ -s "$1" ] || [ -z "$(find "$1" -mmin +60 2>/dev/null)" ]
}

# ar_ai_title <title> <reserve> <workspace label> -> sets AR_AI_TITLE to the
# model's label for that title; rc 1 when there is none yet (the title is then
# queued) or the model's answer was refused.
#
# Everything that changes the answer is in the key: model, separator, budget,
# and the workspace, a word the model is told not to spend on.
ar_ai_title() {
  local title=$1 ws=$3 key f
  AR_AI_TITLE=""
  [ "${AI_TITLES:-0}" = "1" ] && [ -n "$title" ] && ar_ai_ready || return 1
  ar_ai_budget "$2" || return 1
  key=$(printf '%s\037%s\037%s\037%s\037%s' "$AI_TITLE_MODEL" "${TITLE_WORD_SEPARATOR:--}" \
    "$AR_AI_BUDGET" "$ws" "$title" | md5sum)
  key=${key%% *}
  [ -n "$key" ] || return 1
  f="$AR_AI_DIR/$key"
  if ar_ai_cached "$f"; then
    AR_AI_TITLE=$(<"$f")
    [ -n "$AR_AI_TITLE" ]
    return
  fi
  ar_ai_enqueue "$key" "$AR_AI_BUDGET" "$ws" "Task title: $title"
  return 1
}

# ar_ai_label <tab_id> <title> <reserve> <workspace label> -> sets AR_AI_TITLE
# to the label this agent tab should carry; rc 1 when there is none yet. Reads
# AR_PANE_AGENT / AR_PANE_SESSION / AR_PANE_DIR, the pane facts ar_tab_name has
# already loaded.
ar_ai_label() {
  local tab=$1 title=$2 reserve=$3 ws=$4 mark recent msg tmp key
  AR_AI_TITLE=""
  [ "${AI_TITLES:-0}" = "1" ] && ar_ai_ready || return 1
  ar_ai_pin "$tab"
  mark="$AR_AI_MARKS/$(ar_ai_id "$tab")"
  # The retitle action left a mark for this tab. The pin it replaces stays on
  # the tab until the new answer lands, and a failed call leaves it there.
  if [ -f "$mark" ] && rm -f "$mark" && ar_ai_budget "$reserve"; then
    recent=$(ar_transcript_recent "$AR_PANE_AGENT" "$AR_PANE_SESSION" "$AR_PANE_DIR")
    msg="Session title: $title"
    [ -n "$recent" ] && msg="$msg. The user's latest requests, oldest first: $recent. Name what the session is working on NOW; the latest requests matter most."
    # Named after the whole pin path: the queue is shared by every herdr
    # session, and two of them can hold a tab-keyed pin of the same name.
    key=$(printf '%s' "$AR_AI_PIN" | md5sum)
    ar_ai_enqueue "pin-${key%% *}" "$AR_AI_BUDGET" "$ws" "$msg" "$AR_AI_PIN"
  fi
  if [ -s "$AR_AI_PIN" ]; then
    AR_AI_TITLE=$(<"$AR_AI_PIN")
    return 0
  fi
  ar_ai_title "$title" "$reserve" "$ws" || return 1
  # Pinned only if no pin exists by now: a retitle the worker finished since
  # the check above must not be replaced by the first label. `ln` refuses an
  # existing target and lands whole, and whichever pin won is the one used.
  mkdir -p "$AR_AI_PINS" 2>/dev/null || return 0
  tmp="$AR_AI_PIN.tmp.$$"
  printf '%s' "$AR_AI_TITLE" >"$tmp" && ln "$tmp" "$AR_AI_PIN" 2>/dev/null
  rm -f "$tmp"
  [ -s "$AR_AI_PIN" ] && AR_AI_TITLE=$(<"$AR_AI_PIN")
  return 0
}

# ar_ai_file_key <file> -> the file's ANTHROPIC_API_KEY entry, read the way
# personal-feed reads the same file (optional `export`, surrounding whitespace
# and quotes; comment lines skipped; never sourced), or the file's one line when
# that is a bare key. Nothing otherwise, so another secret in a shared file is
# never sent as this one.
ar_ai_file_key() {
  local l k v bare="" n=0
  [ -s "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l#"${l%%[![:space:]]*}"}; l=${l%"${l##*[![:space:]]}"}
    [ -n "$l" ] || continue
    n=$((n + 1)) bare=$l
    [[ $l == \#* || $l != *=* ]] && continue
    [[ $l == "export "* ]] && { l=${l#export }; l=${l#"${l%%[![:space:]]*}"}; }
    k=${l%%=*} v=${l#*=}
    [ "${k%"${k##*[![:space:]]}"}" = ANTHROPIC_API_KEY ] || continue
    v=${v#"${v%%[![:space:]]*}"}
    [[ ${#v} -ge 2 && ${v:0:1} == "${v: -1}" && ${v:0:1} == [\"\'] ]] && v=${v:1:${#v}-2}
    printf '%s' "$v"
    return 0
  done <"$1"
  [[ $n == 1 && $bare != *[=#[:space:]]* ]] && printf '%s' "$bare"
  return 0
}

# ar_ai_ask <message> <budget> <workspace label> <model> <separator> -> the
# model's label, or "" when the call failed or no answer keeps a label's rules.
#
# A model counts characters badly, so it is asked for several candidates, each
# shorter than the last, and the first one that fits is taken.
ar_ai_ask() {
  local msg=$1 max=$2 ws=$3 model=$4 sep=$5 out line avoid="" key=${ANTHROPIC_API_KEY:-}
  [ -n "$key" ] || key=$(ar_ai_file_key "$AI_API_KEY_FILE")
  # A key never holds whitespace: one that does is a mangled entry (an inline
  # comment, a stray word), and is not sent.
  [[ -n $key && $key != *[[:space:]]* ]] || return 0
  [ -n "$ws" ] && avoid=" The tab already sits under a workspace named \"$ws\", so never spend characters on that name."
  # The key goes in through a header file, so it never shows in `ps`.
  out=$(jq -n --arg m "$model" --arg u "$msg" \
    --arg s "You name terminal tabs. Given what a coding agent's session is about, write a tab label of at most $max characters that says which task this is, so it stands apart from the user's other agent tabs. Lowercase words joined by \"$sep\"; keep the most specific nouns, drop generic verbs and filler, abbreviate long words when that keeps meaning (config->cfg, database->db). Keep issue keys and acronyms as written.$avoid Reply with 5 candidate labels, one per line, best first, each shorter than the one before. Labels only: no numbering, quotes or explanation." \
    '{model: $m, max_tokens: 1024, output_config: {effort: "low"}, system: $s, messages: [{role: "user", content: $u}]}' |
    curl -sf --max-time 60 "$AI_API_URL" -H @<(printf 'x-api-key: %s\n' "$key") \
      -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' --data-binary @- 2>/dev/null |
    jq -r '.content[]? | select(.type == "text") | .text' 2>/dev/null) || return 0
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '`"'"'" | tr -s '[:space:]' ' ')
    line=${line# }; line=${line% }
    case $line in
    "" | *[[:cntrl:]]*) continue ;;
    esac
    # The shape ar_strip_prefix reads back as a jump number: a label wearing it
    # reads as a hand rename at the next reconcile.
    [[ $line =~ ^\[[0-9]+\] ]] && continue
    ar_fits "$line" "$max" || continue
    printf '%s' "$line"
    return 0
  done <<<"$out"
}

# ar_ai_worker - answer every queued request, one model call at a time, then run
# one full reconcile so the tabs waiting on an answer pick it up. One worker at a
# time; flock lets go when the process dies, so a killed worker blocks nothing.
#
# The queue is checked again AFTER the lock is let go. A request queued while
# this worker held the lock spawned a worker that found it held and left, but
# its file was written before that, so this check sees it and goes round again.
ar_ai_worker() {
  local q model sep budget ws msg pin out did=0
  mkdir -p "$AR_AI_DIR/queue" 2>/dev/null || return 0
  exec 9>"$AR_AI_DIR/lock"
  while flock -n 9; do
    while :; do
      set -- "$AR_AI_DIR"/queue/*
      [ -e "$1" ] || break
      for q; do
        model="" sep="" budget="" ws="" msg="" pin=""
        # IFS= keeps a separator of one space from being read back as nothing.
        { IFS= read -r model; IFS= read -r sep; IFS= read -r budget; IFS= read -r ws
          IFS= read -r msg; IFS= read -r pin; } <"$q"
        rm -f "$q"
        [ -n "$model" ] && [ -n "$msg" ] && [ "$budget" -gt 0 ] 2>/dev/null || continue
        if [ -n "$pin" ]; then
          # A retitle: only an answer replaces the pin, so a failure keeps it,
          # and only a pin that is still there: one dropped meanwhile belonged
          # to an agent that has left the tab (ar_ai_unpin_tab). A retitle asked
          # before the session's first pin landed is dropped the same way.
          case $pin in */ai-pins/*) ;; *) continue ;; esac
          out=$(ar_ai_ask "$msg" "$budget" "$ws" "$model" "$sep")
          [ -n "$out" ] && [ -e "$pin" ] || continue
          ar_ai_put "$pin" "$out"
        else
          # Every event while a call is out re-queues its title, so a request
          # already answered (or failed recently) is not asked again.
          ar_ai_cached "$AR_AI_DIR/${q##*/}" && continue
          ar_ai_put "$AR_AI_DIR/${q##*/}" "$(ar_ai_ask "$msg" "$budget" "$ws" "$model" "$sep")"
        fi
        did=1
      done
    done
    flock -u 9
    set -- "$AR_AI_DIR"/queue/*
    [ -e "$1" ] || break
  done
  # ponytail: answers and this session's pins expire 30 days after they were
  # written, used or not; a tab still open then is relabeled from its title.
  find "$AR_AI_DIR" "$AR_AI_PINS" -maxdepth 1 -type f ! -name lock -mtime +30 -delete 2>/dev/null
  find "$AR_AI_DIR" "$AR_AI_DIR/queue" "$AR_AI_PINS" -maxdepth 1 -type f \
    \( -name '.*' -o -name '*.tmp.*' \) -mmin +5 -delete 2>/dev/null
  # Only this herdr session is reconciled. A tab in another session that was
  # waiting on an answer picks it up at that session's next event.
  [ "$did" = 1 ] && bash "$AR_ROOT/automatic-rename.sh" ai-title </dev/null >/dev/null 2>&1
  return 0
}
