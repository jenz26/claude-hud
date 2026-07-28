#!/usr/bin/env bash
# claude-hud.sh  -  HUD delle sessioni Claude Code
#
# USO
#   bash claude-hud.sh event     letto dagli hook, riceve il JSON su stdin
#   bash claude-hud.sh watch     ridisegna a schermo ogni secondo
#   bash claude-hud.sh once      disegna una volta e esce, comodo per i test
#
# Il widget non e' piu' questo script. Lo disegna ~/.claude/claude-hud-widget.ps1,
# una finestra senza cornice sempre in primo piano che legge gli stessi file di
# stato e si lancia dal Desktop con "Claude HUD.cmd". Qui il ruolo che conta e'
# "event": watch e once restano per guardare lo stato a mano dal terminale.
#
# RICHIEDE jq  ->  winget install jqlang.jq
#
# INSTALLAZIONE (globale)
#   Questo script vive in ~/.claude/claude-hud.sh e gli hook sono registrati in
#   ~/.claude/settings.json, NON nel .claude/settings.json di un progetto: cosi'
#   l'HUD raccoglie le sessioni di qualunque cartella, non solo di una.
#   Nel comando niente ${CLAUDE_PROJECT_DIR} (fuori da un progetto punterebbe
#   alla cartella sbagliata): si usa $HOME, che espande bash, cioe' la shell
#   dichiarata nell'hook stesso.
#
#   I 7 eventi registrati, tutti async, dove HOOK sta per
#     { "type": "command", "shell": "bash", "async": true,
#       "command": "bash \"$HOME/.claude/claude-hud.sh\" event" }
#
#   "hooks": {
#     "SessionStart":     [ { "hooks": [ HOOK ] } ],
#     "UserPromptSubmit": [ { "hooks": [ HOOK ] } ],
#     "PostToolUse":      [ { "hooks": [ HOOK ] } ],
#     "Stop":             [ { "hooks": [ HOOK ] } ],
#     "StopFailure":      [ { "hooks": [ HOOK ] } ],
#     "SessionEnd":       [ { "hooks": [ HOOK ] } ],
#     "Notification":     [ { "matcher": "permission_prompt|idle_prompt|agent_needs_input",
#                             "hooks": [ HOOK ] } ]
#   }
#
# Nomi evento e nomi campo sono quelli documentati su
# https://code.claude.com/docs/en/hooks :
#   SessionStart      -> .source
#   UserPromptSubmit  -> .prompt   (verificato sul payload reale di questa
#                        installazione; letto con fallback su .prompt_text)
#   PostToolUse       -> .tool_name, .tool_input, ...  (qui usato solo come heartbeat)
#   Notification      -> .notification_type, .message
#   Stop              -> .last_assistant_message, .turn_count, .tool_use_count
#   StopFailure       -> .error_type, .error_message
#   SessionEnd        -> .reason
# campi comuni: .session_id .transcript_path .cwd .permission_mode .hook_event_name

set -uo pipefail

# In Git Bash LANG non e' impostato: senza questo bash conta i BYTE e ogni
# accento sfasa di una colonna il pallino di stato.
export LC_ALL="${HUD_LOCALE:-C.UTF-8}"

# Claude Code lancia l'hook in modo NON interattivo: .bashrc non viene letto e
# il PATH aggiornato da winget puo' non essere ancora ereditato dal processo
# padre. Quindi jq lo cerchiamo da soli. NB: WinGet/Links puo' essere vuota,
# il binario vero sta sotto WinGet/Packages/jqlang.jq_*/.
# Override manuale: HUD_JQ=/percorso/di/jq
JQ=""
resolve_jq() {
  local c la
  if [ -n "${HUD_JQ:-}" ] && [ -x "$HUD_JQ" ]; then JQ="$HUD_JQ"; return 0; fi
  if command -v jq >/dev/null 2>&1; then JQ="$(command -v jq)"; return 0; fi
  la="${LOCALAPPDATA:-}"; la="${la//\\//}"
  [ -n "$la" ] || la="$HOME/AppData/Local"
  for c in \
      "$la"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe \
      "$la"/Microsoft/WinGet/Links/jq.exe \
      "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe \
      "$HOME"/AppData/Local/Microsoft/WinGet/Links/jq.exe \
      "$HOME"/scoop/shims/jq.exe \
      /c/ProgramData/chocolatey/bin/jq.exe \
      /usr/bin/jq /usr/local/bin/jq "$HOME"/bin/jq "$HOME"/bin/jq.exe ; do
    [ -x "$c" ] || continue
    JQ="$c"; PATH="$(dirname "$c"):$PATH"; export PATH; return 0
  done
  return 1
}

HUD_DIR="${HOME}/.claude/hud"
STALE_AFTER=300        # secondi di silenzio in "running" prima di virare a grigio
ORPHAN_AFTER=1800      # dopo mezz'ora di silenzio il file di stato viene rimosso
                       # (VS Code chiuso di netto: SessionEnd non scatta mai)
W_PROJ=12              # larghezza colonna progetto
W_TITLE=30             # larghezza colonna titolo
DOT="${HUD_DOT:-●}"    # HUD_DOT='*' se il font del terminale non ha il pallino
ELL="${HUD_ELLIPSIS:-…}"

mkdir -p "$HUD_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- helper

# I path che arrivano dagli hook su Windows possono avere i backslash.
norm_path() {
  local p="${1//\\//}"
  printf '%s' "$p"
}

# risale da cwd fino alla prima cartella con .vscode o .git (quella aperta in VS Code)
find_root() {
  local start d parent
  start="$(norm_path "$1")"
  d="$start"
  [ -n "$d" ] || { printf '%s' ""; return; }
  while [ -n "$d" ]; do
    [ -d "$d/.vscode" ] && { printf '%s' "$d"; return; }
    [ -d "$d/.git"    ] && { printf '%s' "$d"; return; }
    case "$d" in
      /|.|[A-Za-z]:|[A-Za-z]:/) break ;;
    esac
    parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && break
    d="$parent"
  done
  printf '%s' "$start"
}

# .vscode/settings.json e' JSONC: provo con jq dopo aver tolto i commenti,
# se fallisce ripiego su estrazione testuale del solo valore della chiave.
json_string_value() {          # json_string_value <file> <chiave>
  local f="$1" key="$2" v
  v="$(sed -e 's://[^"]*$::' "$f" 2>/dev/null \
       | "$JQ" -r --arg k "$key" '
           def pick($o): if ($o|type)=="object" and ($o[$k]|type)=="string"
                         then $o[$k] else empty end;
           [ pick(.), pick(.["workbench.colorCustomizations"] // {}) ] | first // ""
         ' 2>/dev/null)"
  if [ -z "$v" ]; then
    v="$(grep -o "\"${key//./\\.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null \
         | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  fi
  printf '%s' "$v"
}

# peacock.color -> titleBar.activeBackground -> grigio
peacock_color() {
  local root="$1" f="$1/.vscode/settings.json" v hex=""
  [ -n "$root" ] && [ -f "$f" ] || { printf '#666666'; return; }
  for key in "peacock.color" "titleBar.activeBackground"; do
    v="$(json_string_value "$f" "$key")"
    v="${v#\#}"
    case "$v" in
      [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
        hex="${v:0:6}"; break ;;                      # #rrggbb o #rrggbbaa
      [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
        hex="${v:0:1}${v:0:1}${v:1:1}${v:1:1}${v:2:1}${v:2:1}"; break ;;   # #rgb
    esac
  done
  [ -n "$hex" ] || hex="666666"
  printf '#%s' "$hex"
}

hex_to_ansi() {                       # "#61dafb" -> "97;218;251"
  local h="${1#\#}"
  case "$h" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) h="666666" ;;
  esac
  printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

# tronca con ellissi e pareggia la larghezza.
# NB: il padding NON usa '%-*s' perche' bash lo calcola in byte, non in
# caratteri, e le lettere accentate sfaserebbero la colonna dei pallini.
trunc() {
  local s="$1" n="$2" len pad
  len=${#s}
  if [ "$len" -gt "$n" ]; then
    printf '%s%s' "${s:0:n-1}" "$ELL"
  else
    printf '%s' "$s"
    pad=$(( n - len ))
    [ "$pad" -gt 0 ] && printf '%*s' "$pad" ''
  fi
  return 0
}

sanitize() {                          # via i separatori e i controlli
  printf '%s' "$1" | tr -d '\r' | tr '\n\t|' '   ' | cut -c1-120
}

# L'estensione VS Code inietta il proprio contesto dentro .prompt:
#   <ide_opened_file>The user opened ...</ide_opened_file>ciao
# Via prima i blocchi <tag>...</tag> con tutto il contenuto (in ciclo, possono
# essere piu' di uno), poi i tag isolati rimasti, poi spazi doppi e bordi.
clean_title() {
  # jq.exe emette CRLF: se il \r resta, il trim finale toglie lo spazio ma non
  # il \r, e lo spazio riaffiora quando sanitize() elimina i control char.
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed -E ':a; s@<([A-Za-z_][A-Za-z0-9_.:-]*)[^>]*>.*</\1[[:space:]]*>@ @; ta' \
    | sed -E 's@</?[A-Za-z_][A-Za-z0-9_.:-]*[^>]*>@ @g' \
    | tr -s ' ' \
    | sed -E 's/^ +//; s/ +$//'
}

# ---------------------------------------------------------------- hook

cmd_event() {
  local json ev sid cwd root state title color proj
  local old_state old_ts old_color old_proj old_title
  json="$(cat)"

  # se jq non si trova, meglio non fare nulla che disturbare la sessione
  resolve_jq || return 0

  ev="$(printf '%s' "$json"  | "$JQ" -r '.hook_event_name // ""' 2>/dev/null)"
  sid="$(printf '%s' "$json" | "$JQ" -r '.session_id      // ""' 2>/dev/null)"
  cwd="$(printf '%s' "$json" | "$JQ" -r '.cwd             // ""' 2>/dev/null)"
  [ -n "$sid" ] || return 0
  # niente path traversal nel nome file. Il backslash serve perche' su Windows
  # e' un separatore quanto lo slash, anche se qui gli id sono UUID e non ci
  # arriverebbe mai: costa un pattern in piu'.
  case "$sid" in */*|*\\*|..*) return 0 ;; esac

  local f="$HUD_DIR/$sid"

  if [ "$ev" = "SessionEnd" ]; then rm -f "$f"; return 0; fi

  case "$ev" in
    UserPromptSubmit) state="running" ;;
    PostToolUse)      state="running" ;;   # heartbeat: tiene fresco il timestamp
    Stop)             state="done"    ;;
    StopFailure)      state="error"   ;;
    SessionStart)     state="idle"    ;;
    Notification)
      # solo le notifiche che richiedono davvero me: permessi / input
      case "$(printf '%s' "$json" | "$JQ" -r '.notification_type // ""' 2>/dev/null)" in
        permission_prompt|idle_prompt|agent_needs_input) state="waiting" ;;
        *) return 0 ;;
      esac ;;
    *) return 0 ;;
  esac

  # stato precedente (per conservare titolo/colore/progetto tra un evento e l'altro)
  old_state=""; old_ts=""; old_color=""; old_proj=""; old_title=""
  if [ -f "$f" ]; then
    IFS='|' read -r old_state old_ts old_color old_proj old_title < "$f" || true
  fi

  # Gli hook sono tutti async, quindi l'ordine di arrivo non e' garantito: il
  # PostToolUse dell'ultimo tool puo' finire DOPO lo Stop. Se succede, il
  # battito riscriverebbe "running" sopra "done" e la riga resterebbe gialla
  # fino allo stale, cioe' cinque minuti di bugia proprio a turno finito.
  # Il battito serve a tenere fresco il timestamp di una sessione al lavoro,
  # non a resuscitarla: se il turno e' gia' chiuso, non ha niente da dire.
  # Sicuro, perche' per avere altri tool serve un nuovo UserPromptSubmit, che
  # rimette "running" per conto suo.
  if [ "$ev" = "PostToolUse" ]; then
    case "$old_state" in done|error) return 0 ;; esac
  fi

  # il titolo lo prendiamo dal prompt dell'utente e poi lo conserviamo
  title=""
  if [ "$ev" = "UserPromptSubmit" ]; then
    # NB: prima si ripulisce, poi si taglia. Tagliando prima, il taglio
    # cadrebbe dentro il blocco iniettato e il tag di chiusura sparirebbe.
    title="$("$JQ" -r '.prompt // .prompt_text // ""' <<<"$json" 2>/dev/null | tr '\n|' '  ')"
    title="$(clean_title "$title")"
    title="$(sanitize "$title" | cut -c1-80)"
  fi
  [ -n "$title" ] || title="$old_title"
  [ -n "$title" ] || title="(new session)"

  root="$(find_root "$cwd")"
  if [ -n "$root" ]; then
    proj="$(basename "$root")"
    color="$(peacock_color "$root")"
  else
    proj="${old_proj:-?}"
    color="${old_color:-#666666}"
  fi

  # scrittura atomica: il watcher non deve mai leggere una riga a meta'
  local tmp="$f.$$.tmp"
  printf '%s|%s|%s|%s|%s\n' \
    "$state" "$(date +%s)" "$color" "$(sanitize "$proj")" "$title" > "$tmp" \
    && mv -f "$tmp" "$f" || rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------- widget

dot_color() {
  case "$1" in
    running) printf '33'  ;;   # giallo  - turno in corso
    done)    printf '32'  ;;   # verde   - turno concluso
    error)   printf '31'  ;;   # rosso   - errore API
    waiting) printf '34'  ;;   # blu     - aspetta input/permesso
    *)       printf '90'  ;;   # grigio  - idle o stale
  esac
}

render_once() {
  local now f state ts color proj title out line
  now="$(date +%s)"
  # una riga per sessione, ordinate per progetto+titolo cosi' non ballano
  out="$(
    for f in "$HUD_DIR"/*; do
      [ -f "$f" ] || continue
      IFS='|' read -r state ts color proj title < "$f" || continue
      [ -n "$state" ] || continue
      # orfana: nessun evento da ORPHAN_AFTER, qualunque sia lo stato
      case "$ts" in
        ''|*[!0-9]*) ts=0 ;;                       # ts illeggibile: non cancello,
                                                   # lo lascio a video in grigio
        *) [ $(( now - ts )) -gt "$ORPHAN_AFTER" ] && { rm -f "$f"; continue; } ;;
      esac
      [ "$state" = "running" ] && [ $(( now - ts )) -gt "$STALE_AFTER" ] && state="stale"
      printf '%s\t\033[48;2;%sm  \033[0m %s %s \033[1;%sm%s\033[0m\n' \
        "$proj$title" \
        "$(hex_to_ansi "${color:-#666666}")" \
        "$(trunc "$proj"  "$W_PROJ")" \
        "$(trunc "$title" "$W_TITLE")" \
        "$(dot_color "$state")" "$DOT"
    done | sort -f | cut -f2-
  )"
  [ -n "$out" ] || out=$'\033[90mno active sessions\033[0m'
  printf '%s\n' "$out" | while IFS= read -r line; do printf '%s\033[K\n' "$line"; done
  printf '\033[J'
}

cmd_watch() {
  resolve_jq || echo "warning: jq not found, the hooks will write nothing" >&2
  shopt -s nullglob
  printf '\033[?25l'
  trap 'printf "\033[?25h\n"; exit 0' INT TERM
  while :; do
    printf '\033[H'
    render_once
    sleep 1
  done
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  event) cmd_event; exit 0 ;;
  watch) cmd_watch ;;
  once)  shopt -s nullglob; render_once ;;   # comodo per i test
  *) echo "usage: $0 {event|watch|once}" >&2; exit 1 ;;
esac
