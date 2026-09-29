#!/usr/bin/env bash
# =============================================================================
#  stop_pod.sh -- end a Runpod pod from inside it, for unattended batches.
#  Fire Starter Media / Firestarter Pictures.  Facts verified 2026-09-29.
# =============================================================================
#
#  WHY IT EXISTS
#    A pod left running after a batch bills by the hour: $1.99/h (community
#    H100 PCIe) to $7.89/h (B300) at 2026-09-28 prices.  An unattended overnight
#    hang is $16-22.  This script is the last line of the batch, and the
#    --watchdog mode is the belt-and-braces version for a render that hangs.
#
#  NO SECRET HANDLING AT ALL
#    Runpod injects RUNPOD_POD_ID and a pod-scoped RUNPOD_API_KEY into every pod
#    (docs.runpod.io/pods/templates/environment-variables), so there is nothing
#    to store, nothing to paste and nothing to print.  This script reads both
#    from the environment, never writes them anywhere, and never echoes them --
#    the key is passed to curl through a config file on stdin so it does not even
#    appear in the process list.  If you run it from your own machine instead,
#    export RUNPOD_API_KEY yourself; it is still never persisted.
#
#  IT REFUSES TO RUN WITHOUT AN EXPLICIT GO
#    Either pass --confirm, or set STOP_POD_CONFIRM=1.  Without one of those it
#    prints what it would do and exits 2.  --dry-run overrides both and never
#    touches the API.
#
#  USAGE
#    bash stop_pod.sh --dry-run                 # print the exact calls, do nothing
#    bash stop_pod.sh --confirm                 # TERMINATE this pod (default action)
#    bash stop_pod.sh --confirm --action stop   # stop instead (see the warning below)
#    STOP_POD_CONFIRM=1 bash stop_pod.sh        # same as --confirm, for a batch script
#    bash stop_pod.sh --confirm --watchdog 240  # fork: terminate in 240 minutes
#    bash stop_pod.sh --confirm --after-queue --server http://127.0.0.1:8188
#                                               # wait for ComfyUI's queue to drain first
#
#  terminate vs stop  (docs.runpod.io/pods/storage/types)
#    terminate  releases the GPU and DELETES the container disk AND the volume
#               disk.  Billing stops completely.  <-- what Jake wants between
#               sessions; the models are re-downloaded next time by bootstrap.sh.
#    stop       releases the GPU but KEEPS the volume disk, and a stopped pod's
#               volume bills at $0.20/GB/month -- twice the running rate.  A
#               100 GB volume left stopped is $20/month for nothing.
#    Neither touches a network volume ($0.07/GB/month), which survives terminate.
#
#  API
#    v2 (current):  POST https://api.runpod.io/v2/pods/<id>/action {"action":...}
#                   DELETE https://api.runpod.io/v2/pods/<id>
#    v1 (fallback): POST https://rest.runpod.io/v1/pods/<id>/stop
#                   DELETE https://rest.runpod.io/v1/pods/<id>
#    Runpod's own docs say "REST API v1 is deprecated and will be retired on
#    November 15, 2026", so v2 is tried first and v1 only if v2 answers 404/501.
#
#  bash 4+; tested with `bash -n` and --dry-run.
# =============================================================================

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ACTION="terminate"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${STOP_POD_CONFIRM:-0}"
POD_ID="${RUNPOD_POD_ID:-}"
WATCHDOG_MIN=""
AFTER_QUEUE=0
COMFY_SERVER="${COMFY_SERVER:-http://127.0.0.1:8188}"
QUEUE_POLL="${QUEUE_POLL:-30}"
QUEUE_MAX_MIN="${QUEUE_MAX_MIN:-480}"
API_V2="${RUNPOD_API_V2:-https://api.runpod.io/v2}"
API_V1="${RUNPOD_API_V1:-https://rest.runpod.io/v1}"

C_OFF=""; C_WARN=""; C_ERR=""; C_OK=""; C_DIM=""
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_OFF=$'\033[0m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_DIM=$'\033[90m'
fi
ts()   { date -u '+%H:%M:%SZ'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
ok()   { printf '[%s] %sOK%s   %s\n' "$(ts)" "$C_OK" "$C_OFF" "$*"; }
warn() { printf '[%s] %sWARNING:%s %s\n' "$(ts)" "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '[%s] %sERROR:%s %s\n' "$(ts)" "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
would(){ printf '[%s] %sDRY-RUN + %s%s\n' "$(ts)" "$C_DIM" "$*" "$C_OFF"; }

usage() { sed -n '2,50p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)   DRY_RUN=1 ;;
    --confirm|-y)   CONFIRM=1 ;;
    --action)       shift; ACTION="${1:-}" ;;
    --action=*)     ACTION="${1#*=}" ;;
    --pod-id)       shift; POD_ID="${1:-}" ;;
    --pod-id=*)     POD_ID="${1#*=}" ;;
    --watchdog)     shift; WATCHDOG_MIN="${1:-}" ;;
    --watchdog=*)   WATCHDOG_MIN="${1#*=}" ;;
    --after-queue)  AFTER_QUEUE=1 ;;
    --server)       shift; COMFY_SERVER="${1:-}" ;;
    --server=*)     COMFY_SERVER="${1#*=}" ;;
    --help|-h)      usage; exit 0 ;;
    *)              printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$ACTION" in
  terminate|stop|restart|start) : ;;
  *) die "--action must be terminate, stop, restart or start (got '$ACTION')" ;;
esac
if [ -n "$WATCHDOG_MIN" ] && ! [[ "$WATCHDOG_MIN" =~ ^[1-9][0-9]*$ ]]; then
  die "--watchdog takes a whole number of minutes (got '$WATCHDOG_MIN')"
fi

command -v curl >/dev/null 2>&1 || die "curl is required and not installed."

# ---------------------------------------------------------------- preflight ---
log "$SCRIPT_NAME"
log "action            : $ACTION"
if [ -z "$POD_ID" ]; then
  die "no pod id. Inside a pod RUNPOD_POD_ID is injected automatically; from elsewhere pass --pod-id <id>."
fi
log "pod               : $POD_ID"
if [ -n "${RUNPOD_API_KEY:-}" ]; then
  log "credentials       : RUNPOD_API_KEY is set (value never printed or written)"
else
  if [ "$DRY_RUN" != "1" ]; then
    die "RUNPOD_API_KEY is not set. Inside a pod Runpod injects a pod-scoped key; from your own machine export one for this shell only. This script never stores it."
  fi
  warn "RUNPOD_API_KEY is not set -- fine for a dry run, fatal for a real call."
fi
if [ "$ACTION" = "stop" ]; then
  warn "'stop' KEEPS the volume disk and bills it at \$0.20/GB/month while stopped --"
  warn "twice the running rate. For a finished session use the default, 'terminate'."
fi

# ---- the go / no-go gate -----------------------------------------------------
if [ "$DRY_RUN" != "1" ] && [ "$CONFIRM" != "1" ]; then
  printf '\n'
  warn "REFUSING to $ACTION pod $POD_ID without an explicit go."
  warn "  interactive : bash $SCRIPT_NAME --confirm"
  warn "  in a script : STOP_POD_CONFIRM=1 bash $SCRIPT_NAME"
  warn "  to look only: bash $SCRIPT_NAME --dry-run"
  exit 2
fi

# ------------------------------------------------------------------ helpers ---
# The key goes to curl through --config on stdin, so it never appears in argv
# (and so it cannot be read out of /proc or a process listing).
api_call() {  # api_call <METHOD> <URL> [json_body] -> prints "HTTPCODE<TAB>body"
  local method="$1" url="$2" body="${3:-}"
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "$url"
                 -H 'Accept: application/json' --max-time 60 --config -)
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "${RUNPOD_API_KEY:-}" \
    | curl "${args[@]}" 2>&1
}

describe_call() {  # describe_call <METHOD> <URL> [body]
  local method="$1" url="$2" body="${3:-}"
  if [ -n "$body" ]; then
    printf 'curl -X %s "%s" -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" -d %s\n' \
      "$method" "$url" "'$body'"
  else
    printf 'curl -X %s "%s" -H "Authorization: Bearer $RUNPOD_API_KEY"\n' "$method" "$url"
  fi
}

# ------------------------------------------------------- optional: wait first -
wait_for_queue() {
  local deadline=$(( SECONDS + QUEUE_MAX_MIN * 60 ))
  log "waiting for ComfyUI's queue to drain at $COMFY_SERVER (poll ${QUEUE_POLL}s, give up after ${QUEUE_MAX_MIN}m)"
  if [ "$DRY_RUN" = "1" ]; then
    would "curl -fsS $COMFY_SERVER/queue   # repeat every ${QUEUE_POLL}s until queue_running and queue_pending are both empty"
    return 0
  fi
  local idle=0 q flat
  while [ "$SECONDS" -lt "$deadline" ]; do
    q="$(curl -fsS --max-time 10 "$COMFY_SERVER/queue" 2>/dev/null)" || {
      warn "ComfyUI did not answer /queue -- treating it as finished (it may have crashed)"
      return 0
    }
    # Whitespace-stripped substring tests, so neither key order nor the JSON
    # encoder's spacing can fool this.
    flat="$(printf '%s' "$q" | tr -d ' \t\n\r')"
    if [ "${flat#*\"queue_running\":[]}" != "$flat" ] && [ "${flat#*\"queue_pending\":[]}" != "$flat" ]; then
      idle=$((idle + 1))
      # Two consecutive empty polls, so a job being handed over is not mistaken
      # for an empty queue.
      [ "$idle" -ge 2 ] && { ok "queue is empty"; return 0; }
    else
      idle=0
    fi
    sleep "$QUEUE_POLL"
  done
  warn "queue still not empty after ${QUEUE_MAX_MIN} minutes -- going ahead with $ACTION anyway"
}

# ------------------------------------------------------------------ watchdog ---
if [ -n "$WATCHDOG_MIN" ]; then
  log "watchdog          : $ACTION in $WATCHDOG_MIN minute(s)"
  # /workspace only exists on a pod. If the redirect target is not writable,
  # `nohup ... &` fails in the background but $! is still set, so without this
  # check the script would report "watchdog armed" when nothing was -- the worst
  # possible lie for the one feature whose job is to stop a hung render from
  # billing all night.
  WD_LOG="${WATCHDOG_LOG:-}"
  if [ -z "$WD_LOG" ]; then
    for cand in /workspace "${TMPDIR:-/tmp}" .; do
      if [ -d "$cand" ] && [ -w "$cand" ]; then WD_LOG="$cand/stop_pod_watchdog.log"; break; fi
    done
  fi
  [ -n "$WD_LOG" ] || die "nowhere writable for the watchdog log (tried /workspace, \$TMPDIR and .). Set WATCHDOG_LOG=<path>."
  log "watchdog log      : $WD_LOG"
  if [ "$DRY_RUN" = "1" ]; then
    would "nohup bash -c \"sleep $((WATCHDOG_MIN * 60)); STOP_POD_CONFIRM=1 bash '$0' --action '$ACTION' --pod-id '$POD_ID'\" > '$WD_LOG' 2>&1 &"
    log "dry run -- no watchdog was armed"
    exit 0
  fi
  nohup bash -c "sleep $((WATCHDOG_MIN * 60)); STOP_POD_CONFIRM=1 RUNPOD_API_KEY=\"\$RUNPOD_API_KEY\" bash '$0' --action '$ACTION' --pod-id '$POD_ID'" \
    > "$WD_LOG" 2>&1 &
  WD_PID=$!
  # Give the fork a moment, then prove it is really there before claiming it is.
  sleep 1
  if kill -0 "$WD_PID" 2>/dev/null; then
    ok "watchdog armed (pid $WD_PID), log $WD_LOG"
    log "cancel it with:  kill $WD_PID   (or pkill -f 'stop_pod.sh --action $ACTION')"
  else
    warn "the watchdog process died immediately -- NOTHING is armed, and the pod will keep"
    warn "billing until you terminate it yourself. Log: $WD_LOG"
    [ -s "$WD_LOG" ] && sed "s/^/      /" "$WD_LOG" >&2
    exit 1
  fi
  exit 0
fi

[ "$AFTER_QUEUE" = "1" ] && wait_for_queue

# ------------------------------------------------------------------ do it -----
if [ "$ACTION" = "terminate" ]; then
  V2_METHOD="DELETE"; V2_URL="$API_V2/pods/$POD_ID";         V2_BODY=""
  V1_METHOD="DELETE"; V1_URL="$API_V1/pods/$POD_ID";         V1_BODY=""
else
  V2_METHOD="POST";   V2_URL="$API_V2/pods/$POD_ID/action";  V2_BODY="{\"action\":\"$ACTION\"}"
  V1_METHOD="POST";   V1_URL="$API_V1/pods/$POD_ID/$ACTION"; V1_BODY=""
fi

printf '\n'
log "v2 call           : $(describe_call "$V2_METHOD" "$V2_URL" "$V2_BODY")"
log "v1 fallback       : $(describe_call "$V1_METHOD" "$V1_URL" "$V1_BODY")"
printf '\n'

if [ "$DRY_RUN" = "1" ]; then
  would "$(describe_call "$V2_METHOD" "$V2_URL" "$V2_BODY")"
  would "# if that answers 404 or 501, fall back to:"
  would "$(describe_call "$V1_METHOD" "$V1_URL" "$V1_BODY")"
  printf '\n'
  log "DRY RUN -- the Runpod API was NOT contacted and pod $POD_ID is untouched."
  exit 0
fi

log "calling v2 ..."
RESP="$(api_call "$V2_METHOD" "$V2_URL" "$V2_BODY")"
CODE="$(printf '%s' "$RESP" | tail -n1)"
BODY="$(printf '%s' "$RESP" | sed '$d')"
log "v2 HTTP $CODE"
[ -n "$BODY" ] && log "v2 body: $(printf '%s' "$BODY" | head -c 400)"

case "$CODE" in
  200|201|202|204)
    ok "pod $POD_ID: $ACTION accepted (v2)"
    [ "$ACTION" = "terminate" ] && log "billing for the GPU, container disk and volume disk stops now."
    exit 0
    ;;
  401|403)
    die "v2 refused the key (HTTP $CODE). Inside a pod the injected RUNPOD_API_KEY is pod-scoped; from outside the key needs pod write access. Nothing was changed."
    ;;
  404|501)
    warn "v2 answered $CODE -- trying the deprecated v1 route (retires 2026-11-15)"
    ;;
  *)
    warn "v2 answered $CODE -- trying v1 before giving up"
    ;;
esac

log "calling v1 ..."
RESP="$(api_call "$V1_METHOD" "$V1_URL" "$V1_BODY")"
CODE="$(printf '%s' "$RESP" | tail -n1)"
BODY="$(printf '%s' "$RESP" | sed '$d')"
log "v1 HTTP $CODE"
[ -n "$BODY" ] && log "v1 body: $(printf '%s' "$BODY" | head -c 400)"

case "$CODE" in
  200|201|202|204)
    ok "pod $POD_ID: $ACTION accepted (v1)"
    [ "$ACTION" = "terminate" ] && log "billing for the GPU, container disk and volume disk stops now."
    exit 0
    ;;
esac

printf '\n'
die "both API versions refused (last HTTP $CODE). THE POD IS STILL RUNNING AND STILL BILLING.
    Stop it by hand now: the Runpod console (runpod.io/console/pods) or
      runpodctl remove pod $POD_ID
    Then work out why -- most likely the key's scope or a changed endpoint."
