#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh -- provision a Runpod pod for MiniMax H3 video generation
#  Fire Starter Media / Firestarter Pictures.  Facts verified 2026-09-29.
#  Companion docs: README.md (session flow), TEMPLATE.md (how to build the pod).
# =============================================================================
#
#  WHAT IT DOES, in order:
#    0. reports what it found (ComfyUI version, GPU, python, disk, tooling)
#    1. upgrades ComfyUI to the pinned version if the image ships an older one
#    2. installs the custom-node packs at pinned commits, with constrained pip
#    3. downloads the model files for the chosen PROFILE and verifies every byte
#    4. prints a timed summary
#    5. starts ComfyUI on 0.0.0.0:8188 (or execs the image's own /start.sh)
#
#  IDEMPOTENT AND RESUMABLE.  Every step checks first and skips what is already
#  there; a half-finished download resumes; a failed run can simply be re-run.
#
#  USAGE
#    PROFILE=singularity-2pass bash bootstrap.sh
#    PROFILE=all bash bootstrap.sh --dry-run          # print every command, do nothing
#    bash bootstrap.sh --help
#
#  PROFILES
#    singularity-2pass   Jake's downloaded graph: Singularity ref2va UNET, two
#                        sampler passes with MinimaxH3LatentUpscaler3D between
#                        them, MiniMaxH3NativeAudioLock for exact audio.
#    stock-graphA        Z:\Claude\comfyui\minimax_h3_r2v_runcomfy\h3_r2v_graphA_*
#                        stock Comfy-Org ref2va + Fun ControlNet Union 2.0 depth.
#    all                 both, de-duplicated (three files are shared).
#
#  ENVIRONMENT (all optional)
#    PROFILE=singularity-2pass|stock-graphA|all   default singularity-2pass
#    DRY_RUN=1                  same as --dry-run
#    START_COMFY=0              provision only, do not start ComfyUI
#    COMFY_PIN=v0.37.4          ComfyUI tag to run (matches Jake's local install)
#    COMFY_DIR=/workspace/runpod-slim/ComfyUI
#    VENV_DIR=<autodetected>    e.g. $COMFY_DIR/.venv-cu128
#    MODELS_ROOT=$COMFY_DIR/models
#    NETVOL_MODELS=/workspace/models   if this DIRECTORY exists it becomes the
#                               model store: files are downloaded there once and
#                               symlinked into MODELS_ROOT, never re-downloaded.
#    SINGULARITY_UNET=pruned_int8|as_authored|w4a8      default pruned_int8
#                               pruned_int8 saves 13.04 GB per session at the same
#                               quantisation.  See FLAGS at the end of the run.
#    WANT_DEPTH=1               also fetch the 4.53 GB Fun ControlNet Union 2.0 model
#                               patch on the singularity-2pass profile.  Needed ONLY if
#                               you un-bypass the depth group (nodes 20-23) of
#                               h3_singularity_2pass_ui.json.  Implied by PROFILE=all
#                               and PROFILE=stock-graphA, which fetch it anyway.
#    WANT_MONITOR=0             skip Crystools + rgthree (the VRAM bar and progress bar)
#    WANT_SAGE=1                also update KJNodes to its pin and pip install
#                               sageattention (needed only if the graph's
#                               MiniMaxH3MemoryEfficientSageAttentionPatch node is
#                               NOT bypassed).  Default 0 -- see FLAGS.
#    DL_JOBS=3                  parallel downloads
#    ALLOW_DOWNGRADE=1          permit moving ComfyUI to an OLDER tag than the one
#                               installed.  Refused by default.
#    HF_TOKEN=...               only if a repo ever becomes gated.  All three are
#                               public today.  Never written to disk by this script.
#
#  FLAGS / --skip-comfy-upgrade --skip-packs --skip-models --no-start
#
#  WHAT IT DELIBERATELY DOES NOT DO
#    - no `pip install torch`, ever.  The image's CUDA stack is pinned by a
#      constraints file and this script adds its own pins on top (same defensive
#      approach as voice_changer_seedvc\install_seedvc.ps1).
#    - no ComfyUI-Manager / comfy-cli installs: they resolve requirements
#      unconstrained and can break the CUDA stack.
#    - never prints or stores a token.
#    - never kills a ComfyUI that is already running; it tells you to restart it.
#
#  bash 4+; tested with `bash -n` and `--dry-run` on 5.2.37.
# =============================================================================

# No `set -e`: a long provisioning script needs to decide for itself which
# failures are fatal, and `set -e` interacts badly with the parallel-download
# bookkeeping below.  Everything that matters is checked explicitly and ends in
# die().  `set -u` catches typo'd variables, `pipefail` keeps `cmd | grep` honest.
set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
START_TS=$SECONDS

# ------------------------------------------------------------------ pins ------
# ComfyUI.  Floor is 0.35.2 (Fun ControlNet as a model patch, refs+FunCN, the
# denoise-mask fix, and core's reading of transformer_options
# ["minimax_h3_lock_audio_clean"] which the audio-lock node sets).
# The pin matches Jake's local install so a graph validates identically on both.
COMFY_PIN="${COMFY_PIN:-v0.37.4}"
COMFY_FLOOR="0.35.2"

# Custom-node packs.  name|repo|commit|subdir_in_repo|profiles|gate_env
# subdir "-"  = the repo IS the pack.
# profiles    = comma list, or "both".
# gate_env    = "-" always, else the env var that must be 1 to install it.
PACKS=(
  "ComfyUI-H3-NativeAudioLock|https://github.com/Shrek3OnVH5/MiniMax-H3-NativeAudio-MusicVideo-Workflow|11a95f623b98496923714db99da0aecec672cbd4|custom_nodes/ComfyUI-H3-NativeAudioLock|singularity-2pass|-"
  "Comfyui_Minimax_h3_latent_Upscaler|https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler|40316cf008b2fd8663263270669eb4da23f89d2c|-|singularity-2pass|-"
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite|4d907bee61e92c2e65af3bd6383a4e4d356126d1|-|both|-"
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes|d3cfe21625e5170126ce06fbfcfe1d88108688c3|-|singularity-2pass|WANT_SAGE"
  # Monitoring, so the pod looks like Jake's local ComfyUI: Crystools draws the
  # CPU/RAM/GPU/VRAM bar across the top, rgthree the per-node progress bar and a
  # readable queue. Set WANT_MONITOR=0 to skip them.
  "ComfyUI-Crystools|https://github.com/crystian/ComfyUI-Crystools|2f18256c5b5063937106f29a8e0a7db3ae3869b7|-|both|MONITOR"
  "rgthree-comfy|https://github.com/rgthree/rgthree-comfy|2c5342a8cb0eaecaabf61435a5f37dd594c510ba|-|both|MONITOR"
)

# Hugging Face revisions, pinned.  Comfy-Org/MiniMax-H3 was modified on
# 2026-09-29, so /resolve/main/ is not reproducible; /resolve/<sha>/ is.
HF_REV_COMFYORG="e5eb578a89295337b8ff433a035929ce0279e0b6"
HF_REV_SINGULARITY="af671d9214a6e41ab8c2f43e9f871ea56246115f"
HF_REV_UPSCALER="3f941d5d182014dd5c0a5e16330420ee2d4aa0c6"

# Models.  profile|repo|revision|path_in_repo|models_subfolder|local_name|bytes
# local_name "-" = keep the repo's basename.
# Every byte size below was read from the Hugging Face tree API and confirmed
# with a HEAD on the resolve URL (302 -> 200, X-Linked-Size matching).
MODELS=()
build_model_list() {
  local sing_file sing_bytes
  case "${SINGULARITY_UNET:-pruned_int8}" in
    pruned_int8)  sing_file="Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors"; sing_bytes=20967647456 ;;
    as_authored)  sing_file="Minimax-h3_Singularity_ref2va_v1.3_int8.safetensors";        sing_bytes=34004507622 ;;
    w4a8)         sing_file="Minimax-h3_Singularity_ref2va_v1.3_Pruned_w4a8.safetensors"; sing_bytes=11767930768 ;;
    *) die "SINGULARITY_UNET must be pruned_int8, as_authored or w4a8 (got '${SINGULARITY_UNET}')" ;;
  esac

  MODELS=(
    # ---- singularity-2pass ------------------------------------------------
    "singularity-2pass|WarmBloodAban/Minimax-h3_Singularity|$HF_REV_SINGULARITY|$sing_file|diffusion_models|-|$sing_bytes"
    "singularity-2pass|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|vae/minimax_h3_video_vae_fp16.safetensors|vae|-|5207808496"
    # The latent upscaler's HF path has an extra folder level; the file is stored
    # under its real basename, which is exactly what the merged graph's
    # MinimaxH3LatentUpscaler3D widget names. NOT renamed -- the short name
    # minimax_h3_latent_upscaler_3d_fp16.safetensors that the downloaded README
    # gives is a 404 on Hugging Face and matches no node in this repo.
    "singularity-2pass|LBH-123-AI/Minimax_h3_latent_Upscaler|$HF_REV_UPSCALER|minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors|latent_upscale_models|-|690592672"
    # ---- stock-graphA ----------------------------------------------------
    "stock-graphA|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|diffusion_models|-|20970379616"
    "stock-graphA|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|vae/minimax_h3_video_vae_fp16.safetensors|vae|-|5207808496"
    "stock-graphA|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|model_patches/minimax_h3_fun_controlnet_union_2.0_pruned_int8_convrot.safetensors|model_patches|-|4531220608"
    # ---- shared by both profiles -----------------------------------------
    "both|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|-|15687142551"
    "both|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|vae/minimax_h3_audio_vae_fp32.safetensors|vae|-|605254808"
    "both|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors|loras|-|1956193000"
  )

  # h3_singularity_2pass_ui.json ships its depth group (nodes 20-23) BYPASSED, so
  # the singularity profile does not pay for the 4.53 GB Fun ControlNet patch.
  # Un-bypass those nodes and node 22 (ModelPatchLoader) needs the file, which
  # otherwise only the stock-graphA profile fetches. WANT_DEPTH=1 adds it.
  if [ "${WANT_DEPTH:-0}" = "1" ]; then
    MODELS+=(
      "singularity-2pass|Comfy-Org/MiniMax-H3|$HF_REV_COMFYORG|model_patches/minimax_h3_fun_controlnet_union_2.0_pruned_int8_convrot.safetensors|model_patches|-|4531220608"
    )
  fi
}

# Packages that must not move, whatever a pack's requirements.txt asks for.
# Same idea as install_seedvc.ps1's $LOCK_REGEX.
LOCK_REGEX='^(torch|torchvision|torchaudio|numpy|pillow|protobuf|transformers|tokenizers|huggingface-hub|hf-xet|safetensors|pydantic|pydantic-core|av|scipy|einops|opencv-python|opencv-python-headless|opencv-contrib-python|comfyui-frontend-package|comfyui-workflow-templates|comfyui-embedded-docs|comfy-kitchen|comfy-aimdo)$'

# ------------------------------------------------------------- defaults -------
PROFILE="${PROFILE:-singularity-2pass}"
DRY_RUN="${DRY_RUN:-0}"
START_COMFY="${START_COMFY:-1}"
COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
BAKED_DIR="${BAKED_DIR:-/opt/comfyui-baked}"
NETVOL_MODELS="${NETVOL_MODELS:-/workspace/models}"
DL_JOBS="${DL_JOBS:-3}"
WANT_SAGE="${WANT_SAGE:-0}"
# Crystools + rgthree: the VRAM/CPU bar and the per-node progress bar, so a pod
# looks like Jake's local ComfyUI. On by default; WANT_MONITOR=0 turns them off.
MONITOR="${WANT_MONITOR:-1}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-0}"
SINGULARITY_UNET="${SINGULARITY_UNET:-pruned_int8}"
SKIP_COMFY_UPGRADE=0
SKIP_PACKS=0
SKIP_MODELS=0
PIP_CONSTRAINT_IMAGE="${PIP_CONSTRAINT_IMAGE:-/opt/comfyui-runtime-constraints.txt}"

# ------------------------------------------------------------- logging --------
C_OFF=""; C_OK=""; C_WARN=""; C_ERR=""; C_STEP=""; C_DIM=""
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_OFF=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'; C_STEP=$'\033[36m'; C_DIM=$'\033[90m'
fi
elapsed() { local s=$((SECONDS - START_TS)); printf '%02d:%02d' $((s / 60)) $((s % 60)); }
log()   { printf '[%s] %s\n' "$(elapsed)" "$*"; }
step()  { printf '\n[%s] %s==> %s%s\n' "$(elapsed)" "$C_STEP" "$*" "$C_OFF"; }
info()  { printf '[%s]     %s\n' "$(elapsed)" "$*"; }
ok()    { printf '[%s]     %sOK%s   %s\n' "$(elapsed)" "$C_OK" "$C_OFF" "$*"; }
skip()  { printf '[%s]     %sSKIP%s %s\n' "$(elapsed)" "$C_DIM" "$C_OFF" "$*"; }
warn()  { printf '[%s]     %sWARNING:%s %s\n' "$(elapsed)" "$C_WARN" "$C_OFF" "$*"; }
die()   { printf '\n[%s] %sERROR:%s %s\n' "$(elapsed)" "$C_ERR" "$C_OFF" "$*" >&2
          printf '[%s] %s\n' "$(elapsed)" "Nothing else was attempted. Fix the above and re-run: the script skips whatever already succeeded." >&2
          exit 1; }

SUMMARY=()
FLAGS=()
sum()  { SUMMARY+=("$*"); }
flag() { FLAGS+=("$*"); }

# Quote a command for the dry-run log so it can be pasted into a shell as-is.
quote_cmd() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      ""|*[!A-Za-z0-9_./:=@%+,-]*) out+="'${a//\'/\'\\\'\'}' " ;;
      *)                           out+="$a " ;;
    esac
  done
  printf '%s' "${out% }"
}
# run CMD ...      -- execute, or print it under --dry-run
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '[%s]     %s+ %s%s\n' "$(elapsed)" "$C_DIM" "$(quote_cmd "$@")" "$C_OFF"; return 0; fi
  "$@"
}
# run_sh 'shell string'  -- for redirections / cd / globs
run_sh() {
  if [ "$DRY_RUN" = "1" ]; then printf '[%s]     %s+ %s%s\n' "$(elapsed)" "$C_DIM" "$1" "$C_OFF"; return 0; fi
  bash -c "$1"
}

# ------------------------------------------------------------- args -----------
usage() { sed -n '2,70p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)           DRY_RUN=1 ;;
    --profile)              shift; PROFILE="${1:-}" ;;
    --profile=*)            PROFILE="${1#*=}" ;;
    --no-start)             START_COMFY=0 ;;
    --skip-comfy-upgrade)   SKIP_COMFY_UPGRADE=1 ;;
    --skip-packs)           SKIP_PACKS=1 ;;
    --skip-models)          SKIP_MODELS=1 ;;
    --jobs)                 shift; DL_JOBS="${1:-3}" ;;
    --jobs=*)               DL_JOBS="${1#*=}" ;;
    --help|-h)              usage; exit 0 ;;
    *)                      printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$PROFILE" in
  singularity-2pass|stock-graphA|all) : ;;
  *) printf 'ERROR: PROFILE must be singularity-2pass, stock-graphA or all (got %s)\n' "$PROFILE" >&2; exit 2 ;;
esac
[[ "$DL_JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'ERROR: DL_JOBS/--jobs must be a positive integer\n' >&2; exit 2; }

wanted_profile() {  # wanted_profile <entry_profile>
  [ "$1" = "both" ] && return 0
  [ "$PROFILE" = "all" ] && return 0
  [ "$1" = "$PROFILE" ]
}

gb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1000000000}'; }

ver_ge() {  # ver_ge A B -> 0 if A >= B (numeric/dotted)
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" = "$b" ]
}

# =============================================================================
step "0. Where we are"
# =============================================================================
build_model_list
info "$SCRIPT_NAME from $SCRIPT_DIR"
info "profile           : $PROFILE"
[ "$DRY_RUN" = "1" ] && warn "DRY RUN -- every mutating command is printed, nothing is changed."
info "pod               : ${RUNPOD_POD_ID:-<not a Runpod pod / RUNPOD_POD_ID unset>}"
info "hostname          : $(hostname 2>/dev/null || echo '?')"
info "kernel            : $(uname -srm 2>/dev/null || echo '?')"
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS= read -r line; do info "gpu               : $line"; done < <(
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "nvidia-smi failed")
else
  warn "nvidia-smi not found -- no GPU visible. Provisioning still works; a render will not."
fi
info "disk /workspace   : $(df -h /workspace 2>/dev/null | awk 'NR==2{print $4" free of "$2}' || echo '?')"
info "disk /            : $(df -h / 2>/dev/null | awk 'NR==2{print $4" free of "$2}' || echo '?')"

for t in git curl python3 rsync; do
  if command -v "$t" >/dev/null 2>&1; then info "tool $t$(printf '%*s' $((14 - ${#t})) '')= $(command -v "$t")"
  else warn "tool $t is MISSING"; fi
done
# Every `pip freeze` / helper call is wrapped in this, so a stalled pip cannot
# quietly burn GPU-hours. Empty if coreutils `timeout` is not available.
TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 240"
HAVE_ARIA2=0; command -v aria2c >/dev/null 2>&1 && HAVE_ARIA2=1
info "aria2c            : $([ $HAVE_ARIA2 = 1 ] && echo "$(command -v aria2c)" || echo 'not installed (curl fallback will be used)')"
command -v git >/dev/null 2>&1 || die "git is required and not installed."
command -v curl >/dev/null 2>&1 || die "curl is required and not installed."

# --- ComfyUI directory: create it from the baked bundle if this runs before /start.sh
if [ ! -d "$COMFY_DIR" ]; then
  if [ -d "$BAKED_DIR" ]; then
    warn "$COMFY_DIR does not exist yet (this script ran before /start.sh)."
    info "copying the baked bundle $BAKED_DIR -> $COMFY_DIR (exactly what /start.sh would do)"
    run mkdir -p "$(dirname "$COMFY_DIR")"
    run cp -a "$BAKED_DIR" "$COMFY_DIR"
    sum "ComfyUI      : workspace created from $BAKED_DIR"
  else
    die "Neither $COMFY_DIR nor $BAKED_DIR exists. Set COMFY_DIR to your ComfyUI install."
  fi
fi
info "ComfyUI dir       : $COMFY_DIR"

# --- venv: reuse whatever the image made, else make one the same way start.sh does
if [ -z "${VENV_DIR:-}" ]; then
  VENV_DIR=""
  for cand in "$COMFY_DIR"/.venv-cu* "$COMFY_DIR"/.venv; do
    [ -x "$cand/bin/python" ] && { VENV_DIR="$cand"; break; }
  done
  [ -z "$VENV_DIR" ] && VENV_DIR="$COMFY_DIR/.venv-cu128"
fi
if [ ! -x "$VENV_DIR/bin/python" ]; then
  warn "no venv at $VENV_DIR -- creating one with --system-site-packages (as /start.sh does)"
  run python3 -m venv --system-site-packages "$VENV_DIR"
  run_sh "'$VENV_DIR/bin/python' -m ensurepip >/dev/null 2>&1 || true"
  sum "venv         : created $VENV_DIR"
fi
PY="$VENV_DIR/bin/python"
info "venv              : $VENV_DIR"
if [ "$DRY_RUN" = "1" ] && [ ! -x "$PY" ]; then
  PY="$(command -v python3)"
  info "dry run, venv python missing -- probing with $PY instead"
fi
info "python            : $("$PY" -V 2>&1 || echo '?')"

# --- pip constraints.  /start.sh exports PIP_CONSTRAINT; this script may run
#     BEFORE it, so export it here too.  Without it a pack's requirements.txt can
#     pull a generic torch wheel over the image's CUDA build.
if [ -f "$PIP_CONSTRAINT_IMAGE" ]; then
  export PIP_CONSTRAINT="$PIP_CONSTRAINT_IMAGE"
  info "image pip pins    : $PIP_CONSTRAINT_IMAGE"
  while IFS= read -r l; do [ -n "$l" ] && info "                    $l"; done < "$PIP_CONSTRAINT_IMAGE"
else
  warn "no $PIP_CONSTRAINT_IMAGE -- this may not be the official runpod/comfyui image."
fi
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONDONTWRITEBYTECODE=1

STATE_DIR="${STATE_DIR:-/workspace/runpod-slim/fsm-bootstrap}"
run mkdir -p "$STATE_DIR"
info "state / logs      : $STATE_DIR"

# --- is ComfyUI already serving?  (decides step 5, and warns about restarts)
COMFY_WAS_UP=0
if curl -fsS --max-time 3 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
  COMFY_WAS_UP=1
  warn "ComfyUI is ALREADY serving on 127.0.0.1:8188."
  warn "New custom nodes are only registered at startup, so it will have to be restarted"
  warn "after this script finishes. This script will not kill it."
fi

# =============================================================================
step "1. ComfyUI version"
# =============================================================================
read_comfy_version() {
  local v=""
  if [ -f "$COMFY_DIR/comfyui_version.py" ]; then
    v="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$COMFY_DIR/comfyui_version.py" | head -n1)"
  fi
  if [ -z "$v" ] && [ -f "$COMFY_DIR/.runpod-bundle-version" ]; then
    v="$(sed -n 's/^COMFYUI_VERSION=v\{0,1\}\(.*\)$/\1/p' "$COMFY_DIR/.runpod-bundle-version" | head -n1)"
  fi
  if [ -z "$v" ]; then
    v="$(git -C "$COMFY_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
  fi
  printf '%s' "$v"
}
CUR_VER="$(read_comfy_version)"
info "installed         : ${CUR_VER:-<unknown>}"
info "pinned            : ${COMFY_PIN#v}"
info "floor for H3      : $COMFY_FLOOR"

if [ "$SKIP_COMFY_UPGRADE" = "1" ]; then
  skip "--skip-comfy-upgrade given"
  sum "ComfyUI      : left at ${CUR_VER:-unknown} (--skip-comfy-upgrade)"
elif [ -z "$CUR_VER" ]; then
  warn "could not read the installed version -- not touching ComfyUI."
  warn "Set COMFY_DIR correctly, or re-run with --skip-comfy-upgrade once you have checked by hand."
  sum "ComfyUI      : version UNKNOWN, left alone"
  flag "ComfyUI version could not be read at $COMFY_DIR -- check before rendering."
elif [ "$CUR_VER" = "${COMFY_PIN#v}" ]; then
  ok "already at the pin"
  sum "ComfyUI      : $CUR_VER (already at the pin)"
elif ver_ge "$CUR_VER" "${COMFY_PIN#v}"; then
  warn "installed $CUR_VER is NEWER than the pin ${COMFY_PIN#v}."
  if [ "$ALLOW_DOWNGRADE" = "1" ]; then
    warn "ALLOW_DOWNGRADE=1 -- moving DOWN to $COMFY_PIN as asked."
    NEED_CHECKOUT=1
  else
    warn "Refusing to downgrade silently. It is left as it is."
    warn "A newer core is usually fine (floor is $COMFY_FLOOR) but the same seed can render"
    warn "differently than on Jake's 0.37.4, so a take locked here may not reproduce there."
    warn "To force the pin: ALLOW_DOWNGRADE=1 bash $SCRIPT_NAME"
    sum "ComfyUI      : $CUR_VER (newer than the pin; NOT changed)"
    flag "Pod ComfyUI is $CUR_VER, Jake's local is ${COMFY_PIN#v}. Locked takes may not reproduce across the two."
    NEED_CHECKOUT=0
  fi
else
  if ver_ge "$CUR_VER" "$COMFY_FLOOR"; then
    info "installed $CUR_VER clears the $COMFY_FLOOR floor but is below the pin -- upgrading for parity."
  else
    warn "installed $CUR_VER is BELOW the $COMFY_FLOOR floor. The H3 graphs cannot run on it. Upgrading."
  fi
  NEED_CHECKOUT=1
fi
NEED_CHECKOUT="${NEED_CHECKOUT:-0}"

if [ "$NEED_CHECKOUT" = "1" ]; then
  git -C "$COMFY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$COMFY_DIR is not a git repo, so it cannot be moved to $COMFY_PIN. Use an image whose ComfyUI is a git checkout."
  if ! git -C "$COMFY_DIR" remote get-url origin >/dev/null 2>&1; then
    info "adding the upstream remote"
    run git -C "$COMFY_DIR" remote add origin https://github.com/comfyanonymous/ComfyUI.git
  fi
  # The runpod image tracks its own bundle with an untracked marker file; keep it.
  # If it disappears, /start.sh rsyncs the baked v0.30.0 back over core on the
  # next boot and silently undoes this upgrade.
  MARKER="$COMFY_DIR/.runpod-bundle-version"
  [ -f "$MARKER" ] && run cp -a "$MARKER" "$STATE_DIR/runpod-bundle-version.bak"
  info "fetching tag $COMFY_PIN (shallow)"
  run git -C "$COMFY_DIR" fetch --depth 1 origin "refs/tags/$COMFY_PIN:refs/tags/$COMFY_PIN" \
    || die "could not fetch tag $COMFY_PIN from GitHub. Check the pod's network and the tag name."
  info "checking out $COMFY_PIN (detached)"
  run git -C "$COMFY_DIR" -c advice.detachedHead=false checkout -f "$COMFY_PIN" \
    || die "git checkout $COMFY_PIN failed. The workspace tree may be dirty: inspect $COMFY_DIR."
  if [ -f "$STATE_DIR/runpod-bundle-version.bak" ] && [ ! -f "$MARKER" ]; then
    info "restoring the runpod bundle marker"
    run cp -a "$STATE_DIR/runpod-bundle-version.bak" "$MARKER"
  fi
  # 0.37.4 needs comfyui-frontend-package 1.52.7, workflow-templates 0.11.69,
  # embedded-docs 0.5.12, comfy-kitchen 0.2.35, comfy-aimdo 0.5.5 and av>=17,
  # where 0.30.0 pinned av>=16 -- so requirements.txt must be re-installed.
  info "installing ComfyUI requirements under the image's torch pins"
  run_sh "'$PY' -m pip install --no-input -r '$COMFY_DIR/requirements.txt' 2>&1 | tail -n 25" \
    || die "pip install of ComfyUI $COMFY_PIN requirements failed. See the output above; nothing after this ran."
  NEW_VER="$(read_comfy_version)"
  if [ "$DRY_RUN" = "1" ]; then
    ok "would be at ${COMFY_PIN#v}"
    sum "ComfyUI      : ${CUR_VER:-?} -> ${COMFY_PIN#v} (dry run)"
  elif [ "$NEW_VER" = "${COMFY_PIN#v}" ]; then
    ok "ComfyUI is now $NEW_VER"
    sum "ComfyUI      : ${CUR_VER:-?} -> $NEW_VER"
  else
    die "after checkout the version reads '$NEW_VER', expected ${COMFY_PIN#v}."
  fi
  flag "This upgrade lives on /workspace. If Runpod publishes a new image tag, /start.sh's rsync --delete restores the baked core (and the baked KJNodes) -- just re-run bootstrap.sh."
fi

# =============================================================================
step "2. Custom-node packs"
# =============================================================================
CN_DIR="$COMFY_DIR/custom_nodes"
run mkdir -p "$CN_DIR"

# Snapshot pip before any pack touches it (same purpose as install_seedvc.ps1's
# pip_freeze snapshot: it is what proves nothing moved).
FREEZE_BEFORE="$STATE_DIR/pip_freeze_before.txt"
if [ "$SKIP_PACKS" != "1" ]; then
  run_sh "$TMO '$PY' -m pip freeze > '$FREEZE_BEFORE' 2>/dev/null || true"
fi

# Our own constraints on top of the image's: lock the whole core set to what is
# installed right now, so no pack's requirements.txt can move it.
MY_CONSTRAINTS="$STATE_DIR/constraints.txt"
build_constraints() {
  if [ "$DRY_RUN" = "1" ]; then
    info "would write $MY_CONSTRAINTS = image pins + every installed package matching"
    info "  $LOCK_REGEX"
    return 0
  fi
  : > "$MY_CONSTRAINTS"
  [ -f "$PIP_CONSTRAINT_IMAGE" ] && cat "$PIP_CONSTRAINT_IMAGE" >> "$MY_CONSTRAINTS"
  # The helper is written to a file rather than piped through `python -`: it is
  # then auditable on the pod next to the constraints it produced, and it does
  # not depend on the interpreter reading its program from stdin.
  cat > "$STATE_DIR/_lock_add.py" <<'PYEOF'
import re, subprocess, sys
out, rx = sys.argv[1], re.compile(sys.argv[2])
have = set()
try:
    with open(out) as f:
        for line in f:
            if "==" in line:
                have.add(line.split("==")[0].strip().lower().replace("_", "-"))
except OSError:
    pass
try:
    frozen = subprocess.run([sys.executable, "-m", "pip", "freeze"],
                            capture_output=True, text=True, timeout=180).stdout.splitlines()
except (subprocess.TimeoutExpired, OSError) as exc:
    # Better to fall back to the image's own pins than to stall a paid pod.
    sys.stderr.write("pip freeze failed (%s); keeping the image pins only\n" % exc)
    sys.exit(3)
with open(out, "a") as f:
    for line in frozen:
        if "==" not in line or line.startswith("-e"):
            continue
        name = line.split("==")[0].strip()
        key = name.lower().replace("_", "-")
        if rx.match(key) and key not in have:
            f.write(line.strip() + "\n")
            have.add(key)
PYEOF
  # TMO wraps the helper so nothing here can stall a metered pod.
  $TMO "$PY" "$STATE_DIR/_lock_add.py" "$MY_CONSTRAINTS" "$LOCK_REGEX" \
    || warn "could not extend the constraints from pip freeze -- $MY_CONSTRAINTS holds the image pins only"
  info "wrote $MY_CONSTRAINTS ($(wc -l < "$MY_CONSTRAINTS" 2>/dev/null || echo 0) pins)"
}

# Filter a pack's requirements.txt:
#   - drop torch/torchvision/torchaudio/numpy (the constraints pin them anyway,
#     and dropping them means pip never even considers a wheel swap)
#   - drop opencv-python-headless when opencv-python is installed: both provide
#     cv2 and the official image installs opencv-python explicitly.
filter_requirements() {  # filter_requirements <src> <dst>
  local src="$1" dst="$2" have_cv2=0
  if [ "$DRY_RUN" = "1" ]; then info "would filter $src -> $dst"; return 0; fi
  "$PY" -c 'import cv2' >/dev/null 2>&1 && have_cv2=1
  awk -v have_cv2="$have_cv2" '
    { line = $0; low = tolower(line); sub(/^[ \t]+/, "", low) }
    low ~ /^(torch|torchvision|torchaudio|numpy)([ \t]*[<>=!~;#\[]|$)/ { print "# [fsm] pinned by the image, skipped: " line; next }
    have_cv2 == 1 && low ~ /^opencv-python-headless([ \t]*[<>=!~;#\[]|$)/ { print "# [fsm] opencv-python already present, skipped: " line; next }
    { print line }
  ' "$src" > "$dst"
}

pip_install_pack_requirements() {  # pip_install_pack_requirements <pack_name> <pack_dir>
  local name="$1" dir="$2" req="$2/requirements.txt" filtered
  if [ ! -f "$req" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      info "then, if $name ships a requirements.txt: filter it (drop torch/torchvision/torchaudio/numpy,"
      info "  and opencv-python-headless when opencv-python is present) and"
      info "  $PY -m pip install --no-input -c $MY_CONSTRAINTS -r $STATE_DIR/req_${name}.txt"
      info "  (of the four packs, only VideoHelperSuite and KJNodes have one)"
    else
      info "$name has no requirements.txt -- nothing to pip install"
    fi
    return 0
  fi
  filtered="$STATE_DIR/req_${name}.txt"
  filter_requirements "$req" "$filtered"
  info "pip install -r $filtered (constrained)"
  run_sh "'$PY' -m pip install --no-input -c '$MY_CONSTRAINTS' -r '$filtered' 2>&1 | tail -n 15" \
    || die "pip install of $name requirements failed. Constraints: $MY_CONSTRAINTS"
}

install_pack() {  # install_pack name repo pin subdir
  local name="$1" repo="$2" pin="$3" subdir="$4"
  # Separate statements on purpose: `local a=1 b=$a` expands every argument
  # BEFORE the first assignment, so b would be unbound under `set -u`.
  local dest="$CN_DIR/$name"
  local pinfile="$dest/.fsm-pin"
  local tmp="$STATE_DIR/clone_$name"

  if [ -f "$pinfile" ] && [ "$(cat "$pinfile" 2>/dev/null)" = "$pin" ]; then
    skip "$name already at $pin"
    sum "pack         : $name @ ${pin:0:7} (already present)"
    return 0
  fi

  if [ "$subdir" = "-" ] && [ -d "$dest/.git" ]; then
    # A real clone we (or the image) put there: move it to the pin in place.
    local cur; cur="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo unknown)"
    info "$name is at ${cur:0:12}, moving to ${pin:0:12}"
    run git -C "$dest" fetch --depth 1 origin "$pin" || die "could not fetch $pin for $name from $repo"
    run git -C "$dest" -c advice.detachedHead=false checkout -f "$pin" \
      || die "could not check out $pin in $dest (local modifications?)"
    run_sh "printf '%s\n' '$pin' > '$pinfile'"
    pip_install_pack_requirements "$name" "$dest"
    ok "$name @ ${pin:0:7}"
    sum "pack         : $name ${cur:0:7} -> ${pin:0:7}"
    return 0
  fi

  if [ -d "$dest" ]; then
    local aside="$dest.replaced-$(date +%Y%m%d-%H%M%S)"
    warn "$dest exists but is not at the pin and is not a git checkout we can move."
    info "moving it aside to $aside (nothing is deleted)"
    run mv "$dest" "$aside"
  fi

  info "clone $repo @ ${pin:0:12}"
  run rm -rf "$tmp"
  run mkdir -p "$tmp"
  run git -C "$tmp" init -q
  run git -C "$tmp" remote add origin "$repo"
  run git -C "$tmp" fetch --depth 1 origin "$pin" \
    || die "could not fetch $pin from $repo. Check the pin and the pod's network."
  run git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD \
    || die "could not check out $pin from $repo"

  if [ "$subdir" = "-" ]; then
    run mv "$tmp" "$dest"
  else
    # Only one folder of the repo is the pack (the audio lock ships this way).
    if [ "$DRY_RUN" != "1" ] && [ ! -d "$tmp/$subdir" ]; then
      die "$repo @ $pin has no '$subdir'. The pin or the path is wrong."
    fi
    run mkdir -p "$dest"
    run_sh "cp -a '$tmp/$subdir/.' '$dest/'"
    run rm -rf "$tmp"
  fi
  run_sh "printf '%s\n' '$pin' > '$pinfile'"
  pip_install_pack_requirements "$name" "$dest"
  ok "$name @ ${pin:0:7}"
  sum "pack         : $name @ ${pin:0:7} (installed)"
}

if [ "$SKIP_PACKS" = "1" ]; then
  skip "--skip-packs given"
else
  build_constraints
  for entry in "${PACKS[@]}"; do
    IFS='|' read -r p_name p_repo p_pin p_sub p_prof p_gate <<< "$entry"
    if ! wanted_profile "$p_prof"; then
      skip "$p_name (not needed by profile $PROFILE)"
      continue
    fi
    if [ "$p_gate" != "-" ]; then
      if [ "${!p_gate:-0}" != "1" ]; then
        skip "$p_name ($p_gate is not 1)"
        if [ "$p_name" = "ComfyUI-KJNodes" ]; then
          info "  The image bakes KJNodes bc8e4ce (2026-06-27). That commit has"
          info "  web/js/setgetnodes.js, so SetNode/GetNode work, but it does NOT have"
          info "  MiniMaxH3MemoryEfficientSageAttentionPatch. Bypass that node in the"
          info "  graph (recommended for the first run: 80 GB of VRAM does not need it),"
          info "  or re-run with WANT_SAGE=1."
        fi
        continue
      fi
    fi
    install_pack "$p_name" "$p_repo" "$p_pin" "$p_sub"
  done

  if [ "$WANT_SAGE" = "1" ]; then
    info "WANT_SAGE=1 -- installing sageattention (KJNodes does NOT declare it)"
    warn "the minimum sageattention version this patch needs is UNVERIFIED; the node only says 'latest'."
    run_sh "'$PY' -m pip install --no-input -c '$MY_CONSTRAINTS' sageattention 2>&1 | tail -n 10" \
      || die "pip install sageattention failed. Bypass the Sage patch node and re-run with WANT_SAGE=0."
    sum "pip          : sageattention (for the KJNodes Sage patch)"
    flag "sageattention installed but its required minimum version is UNVERIFIED. If node 11 of h3_singularity_2pass_ui.json (the Sage patch) raises RuntimeError, bypass it again."
  fi

  # Prove the locked set did not move.
  if [ "$DRY_RUN" != "1" ] && [ -f "$FREEZE_BEFORE" ]; then
    FREEZE_AFTER="$STATE_DIR/pip_freeze_after.txt"
    $TMO "$PY" -m pip freeze > "$FREEZE_AFTER" 2>/dev/null || true
    cat > "$STATE_DIR/_lock_diff.py" <<'PYEOF'
import re, sys
before, after, rx = sys.argv[1], sys.argv[2], re.compile(sys.argv[3])
def load(p):
    d = {}
    try:
        for line in open(p):
            if "==" in line and not line.startswith("-e"):
                n, v = line.strip().split("==", 1)
                d[n.strip().lower().replace("_", "-")] = v.strip()
    except OSError:
        pass
    return d
b, a = load(before), load(after)
for k in sorted(set(b) | set(a)):
    if rx.match(k) and b.get(k) != a.get(k):
        print(f"{k}: {b.get(k, '<absent>')} -> {a.get(k, '<absent>')}")
PYEOF
    MOVED="$($TMO "$PY" "$STATE_DIR/_lock_diff.py" "$FREEZE_BEFORE" "$FREEZE_AFTER" "$LOCK_REGEX" 2>/dev/null)"
    if [ -n "$MOVED" ]; then
      warn "LOCKED PACKAGES MOVED -- the CUDA stack may be broken:"
      while IFS= read -r l; do warn "  $l"; done <<< "$MOVED"
      flag "Locked pip packages changed during pack installs (see $STATE_DIR). Verify torch still sees the GPU before rendering."
    else
      ok "no locked package moved (torch / numpy / opencv / frontend pins intact)"
    fi
    run_sh "'$PY' -m pip check 2>&1 | tail -n 10 || true"
  fi
fi

# =============================================================================
step "3. Models"
# =============================================================================
MODELS_ROOT="${MODELS_ROOT:-$COMFY_DIR/models}"
info "models root       : $MODELS_ROOT"
if wanted_profile "singularity-2pass" && [ "$PROFILE" != "all" ]; then
  if [ "${WANT_DEPTH:-0}" = "1" ]; then
    info "depth path        : WANT_DEPTH=1, adding the 4.53 GB Fun ControlNet patch for nodes 20-23"
  else
    info "depth path        : the graph ships nodes 20-23 bypassed, so the 4.53 GB Fun ControlNet"
    info "                    patch is NOT fetched. Re-run with WANT_DEPTH=1 if you un-bypass them."
  fi
fi

# A mounted network volume becomes the store: download once, symlink forever.
USE_NETVOL=0
NETVOL_STORE=""
if [ -d "$NETVOL_MODELS" ]; then
  USE_NETVOL=1
  NETVOL_STORE="$NETVOL_MODELS"
  ok "network volume models dir found: $NETVOL_STORE"
  info "files are kept there and symlinked into $MODELS_ROOT -- nothing is re-downloaded"
  sum "storage      : network volume in use at $NETVOL_STORE"
else
  info "no $NETVOL_MODELS -- downloading into $MODELS_ROOT (container/volume disk)"
  info "this disk dies with the pod, which is the storage-at-zero choice (see TEMPLATE.md)"
  sum "storage      : no network volume; models live on the pod disk"
fi

# Which downloader?
DL_MODE="curl"
if command -v hf >/dev/null 2>&1; then DL_MODE="hf"
elif [ $HAVE_ARIA2 = 1 ]; then DL_MODE="aria2c"; fi
if [ "$DL_MODE" = "hf" ]; then
  # hf_transfer is deprecated (HF's own download guide says to use hf_xet, which
  # ships with huggingface_hub >= 0.32.0). All four repos are already on Xet
  # storage, so hf_xet is the live fast path. Only fall back to the old lever if
  # hf_transfer happens to be installed and hf_xet is not.
  if "$PY" -c 'import hf_xet' >/dev/null 2>&1; then
    info "downloader        : hf CLI with hf_xet (chunk-dedup fast path)"
  elif "$PY" -c 'import hf_transfer' >/dev/null 2>&1; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
    warn "hf_xet is absent; falling back to the deprecated hf_transfer for speed."
    info "downloader        : hf CLI with HF_HUB_ENABLE_HF_TRANSFER=1"
  else
    info "downloader        : hf CLI (plain). 'pip install -U huggingface_hub' would add hf_xet."
    flag "hf_xet was not importable on this pod -- downloads run at plain HTTPS speed. Check 'pip show hf_xet'."
  fi
else
  info "downloader        : $DL_MODE (hf CLI not on PATH)"
fi
[ -n "${HF_TOKEN:-}" ] && info "HF_TOKEN          : set (value never printed or written)"

MODELS_PLANNED=0; MODELS_PRESENT=0; MODELS_TO_GET=0
BYTES_TOTAL=0; BYTES_TO_GET=0
DL_QUEUE=()      # dest|repo|rev|hfpath|bytes
SEEN_DESTS=" "

plan_models() {
  local entry
  for entry in "${MODELS[@]}"; do
    IFS='|' read -r m_prof m_repo m_rev m_path m_folder m_name m_bytes <<< "$entry"
    wanted_profile "$m_prof" || continue
    [ "$m_name" = "-" ] && m_name="$(basename "$m_path")"
    local dest="$MODELS_ROOT/$m_folder/$m_name"
    case "$SEEN_DESTS" in *" $dest "*) continue ;; esac
    SEEN_DESTS+="$dest "
    MODELS_PLANNED=$((MODELS_PLANNED + 1))
    BYTES_TOTAL=$((BYTES_TOTAL + m_bytes))

    # Where the bytes actually live: the network volume if there is one.
    local store="$dest"
    [ "$USE_NETVOL" = "1" ] && store="$NETVOL_STORE/$m_folder/$m_name"

    local have=0 actual=0
    if [ -f "$store" ]; then
      actual="$(stat -c %s "$store" 2>/dev/null || echo 0)"
      if [ "$actual" = "$m_bytes" ]; then have=1
      else warn "$m_folder/$m_name is $actual bytes, expected $m_bytes -- will re-fetch (resume)"; fi
    fi

    if [ "$have" = "1" ]; then
      MODELS_PRESENT=$((MODELS_PRESENT + 1))
      skip "$m_folder/$m_name ($(gb "$m_bytes") GB, present)"
    else
      MODELS_TO_GET=$((MODELS_TO_GET + 1))
      BYTES_TO_GET=$((BYTES_TO_GET + m_bytes))
      info "GET  $m_folder/$m_name  $(gb "$m_bytes") GB  <- $m_repo"
      DL_QUEUE+=("$store|$m_repo|$m_rev|$m_path|$m_bytes")
    fi

    # Symlink the store into ComfyUI's tree (no-op when they are the same path).
    if [ "$USE_NETVOL" = "1" ]; then
      run mkdir -p "$(dirname "$dest")" "$(dirname "$store")"
      if [ -L "$dest" ]; then
        if [ "$(readlink "$dest" 2>/dev/null)" != "$store" ]; then
          info "re-pointing symlink $dest -> $store"
          run ln -sfn "$store" "$dest"
        fi
      elif [ -e "$dest" ]; then
        warn "$dest is a real file, not a symlink -- leaving it alone. Delete it to use the network volume copy."
      else
        info "symlink $dest -> $store"
        run ln -sfn "$store" "$dest"
      fi
    else
      run mkdir -p "$(dirname "$dest")"
    fi
  done
}

# ---- one file, three possible tools, always resumable, size always verified --
download_one() {  # download_one dest repo rev path_in_repo bytes  (runs in a subshell)
  local dest="$1" repo="$2" rev="$3" path="$4" bytes="$5"
  local name; name="$(basename "$dest")"
  local dir; dir="$(dirname "$dest")"
  local url="https://huggingface.co/$repo/resolve/$rev/$path"

  mkdir -p "$dir" || return 1

  # An auth header is built as an array element so the value is never word-split,
  # and the token itself is never echoed (no `set -x` anywhere in this script).
  local -a auth=()

  case "$DL_MODE" in
    hf)
      # One staging dir per file: two files from the same models subfolder can be
      # in flight at the same time.
      local stage="$dir/.hf-staging-$name"
      mkdir -p "$stage" || return 1
      local -a cmd=(hf download "$repo" "$path" --revision "$rev" --local-dir "$stage")
      [ -n "${HF_TOKEN:-}" ] && cmd+=(--token "$HF_TOKEN")
      # On failure the staging dir is KEPT on purpose: hf keeps its incomplete
      # blob under $stage/.cache/huggingface, so re-running the script resumes a
      # 21 GB file instead of starting it again. Only a success deletes it.
      "${cmd[@]}" >/dev/null || {
        printf 'hf download failed for %s -- staging dir kept at %s so a re-run resumes
' "$name" "$stage" >&2
        return 1
      }
      [ -f "$stage/$path" ] || {
        printf 'hf download reported success but %s is not there
' "$stage/$path" >&2
        return 1
      }
      mv -f "$stage/$path" "$dest" || return 1
      rm -rf "$stage"
      ;;
    aria2c)
      [ -n "${HF_TOKEN:-}" ] && auth=(--header="Authorization: Bearer $HF_TOKEN")
      aria2c --continue=true --max-connection-per-server=8 --split=8 --min-split-size=1M \
             --max-tries=10 --retry-wait=5 --timeout=60 --auto-file-renaming=false \
             --allow-overwrite=true --summary-interval=0 --console-log-level=warn \
             "${auth[@]+"${auth[@]}"}" \
             -d "$dir" -o "$name" "$url" || return 1
      ;;
    curl)
      [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
      # `-C -` needs the output file to exist before it can work out where to resume.
      [ -f "$dest.part" ] || : > "$dest.part" || return 1
      curl -fL --retry 10 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
           -C - "${auth[@]+"${auth[@]}"}" \
           -o "$dest.part" "$url" || return 1
      mv -f "$dest.part" "$dest" || return 1
      ;;
  esac

  local got; got="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
  if [ "$got" != "$bytes" ]; then
    mv -f "$dest" "$dest.badsize" 2>/dev/null || true
    printf 'SIZE MISMATCH %s: got %s, expected %s (moved to %s.badsize)\n' "$name" "$got" "$bytes" "$dest" >&2
    return 2
  fi
  return 0
}

download_all() {
  [ "${#DL_QUEUE[@]}" -eq 0 ] && { ok "every model file is already in place"; return 0; }

  if [ "$DRY_RUN" = "1" ]; then
    info "would download ${#DL_QUEUE[@]} file(s), $(gb "$BYTES_TO_GET") GB, $DL_JOBS at a time:"
    local e
    for e in "${DL_QUEUE[@]}"; do
      IFS='|' read -r d_dest d_repo d_rev d_path d_bytes <<< "$e"
      case "$DL_MODE" in
        hf)     printf '[%s]     %s+ hf download %s %s --revision %s --local-dir %s   # then mv -> %s (%s B)%s\n' \
                  "$(elapsed)" "$C_DIM" "$d_repo" "$d_path" "$d_rev" "$(dirname "$d_dest")/.hf-staging-$(basename "$d_dest")" "$d_dest" "$d_bytes" "$C_OFF" ;;
        aria2c) printf '[%s]     %s+ aria2c -c -x8 -s8 -k1M --max-tries=10 --retry-wait=5 -d %s -o %s https://huggingface.co/%s/resolve/%s/%s   # %s B%s\n' \
                  "$(elapsed)" "$C_DIM" "$(dirname "$d_dest")" "$(basename "$d_dest")" "$d_repo" "$d_rev" "$d_path" "$d_bytes" "$C_OFF" ;;
        curl)   printf '[%s]     %s+ curl -fL --retry 10 --retry-delay 5 --retry-all-errors -C - -o %s.part https://huggingface.co/%s/resolve/%s/%s   # %s B%s\n' \
                  "$(elapsed)" "$C_DIM" "$d_dest" "$d_repo" "$d_rev" "$d_path" "$d_bytes" "$C_OFF" ;;
      esac
      printf '[%s]     %s+ stat -c %%s %s   # must equal %s, else move to .badsize and fail%s\n' \
        "$(elapsed)" "$C_DIM" "$d_dest" "$d_bytes" "$C_OFF"
    done
    return 0
  fi

  local -a pids=() tags=()
  local running=0 failed=0 e
  for e in "${DL_QUEUE[@]}"; do
    IFS='|' read -r d_dest d_repo d_rev d_path d_bytes <<< "$e"
    log "    start  $(basename "$d_dest")  $(gb "$d_bytes") GB"
    ( download_one "$d_dest" "$d_repo" "$d_rev" "$d_path" "$d_bytes" ) \
      > "$STATE_DIR/dl_$(basename "$d_dest").log" 2>&1 &
    pids+=("$!"); tags+=("$(basename "$d_dest")")
    running=$((running + 1))
    if [ "$running" -ge "$DL_JOBS" ]; then
      wait -n 2>/dev/null || failed=$((failed + 1))
      running=$((running - 1))
    fi
  done
  local i
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      ok "downloaded ${tags[$i]}"
    else
      # `wait -n` above may already have reaped it; a second wait returns 127.
      local rc=$?
      if [ "$rc" != "127" ]; then
        warn "FAILED ${tags[$i]} (exit $rc) -- log: $STATE_DIR/dl_${tags[$i]}.log"
        failed=$((failed + 1))
      fi
    fi
  done
  [ "$failed" -gt 0 ] && warn "$failed download job(s) reported a non-zero exit; the size check below is the verdict"

  # Whatever the exit codes said, the size check is the real verdict.
  local bad=""
  for e in "${DL_QUEUE[@]}"; do
    IFS='|' read -r d_dest d_repo d_rev d_path d_bytes <<< "$e"
    local got; got="$(stat -c %s "$d_dest" 2>/dev/null || echo 0)"
    if [ "$got" != "$d_bytes" ]; then
      bad+=$'\n'"  $(basename "$d_dest"): $got bytes on disk, expected $d_bytes"
    else
      ok "verified $(basename "$d_dest") = $d_bytes bytes"
    fi
  done
  if [ -n "$bad" ]; then
    warn "logs are in $STATE_DIR/dl_*.log"
    die "model download did not complete:$bad"$'\n'"    Re-run the script -- finished files are skipped and partial ones resume."
  fi
  ok "all ${#DL_QUEUE[@]} file(s) downloaded and size-verified"
}

if [ "$SKIP_MODELS" = "1" ]; then
  skip "--skip-models given"
  sum "models       : skipped (--skip-models)"
else
  plan_models
  info "planned: $MODELS_PLANNED file(s), $(gb "$BYTES_TOTAL") GB total; $MODELS_PRESENT present, $MODELS_TO_GET to fetch ($(gb "$BYTES_TO_GET") GB)"
  # Fail before spending pod minutes if the disk cannot hold it.
  if [ "$BYTES_TO_GET" -gt 0 ]; then
    AVAIL_KB="$(df -Pk "$MODELS_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "${AVAIL_KB:-}" ]; then
      NEED_KB=$(( BYTES_TO_GET / 1024 + 5242880 ))   # + 5 GiB headroom
      if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
        die "only $(gb $((AVAIL_KB * 1024))) GB free where the models go, need about $(gb $((NEED_KB * 1024))) GB. Recreate the pod with a bigger disk (see TEMPLATE.md)."
      fi
      info "disk check: $(gb $((AVAIL_KB * 1024))) GB free, need about $(gb $((NEED_KB * 1024))) GB -- OK"
    fi
  fi
  download_all
  sum "models       : $MODELS_PLANNED file(s), $(gb "$BYTES_TOTAL") GB ($MODELS_TO_GET fetched this run, $(gb "$BYTES_TO_GET") GB)"
fi

# =============================================================================
step "4. Summary"
# =============================================================================
printf '\n'
printf '  profile            : %s\n' "$PROFILE"
printf '  ComfyUI            : %s at %s\n' "$(read_comfy_version)" "$COMFY_DIR"
printf '  models             : %s\n' "$MODELS_ROOT"
if [ "${#SUMMARY[@]}" -gt 0 ]; then
  printf '\n  what this run did:\n'
  for l in "${SUMMARY[@]}"; do printf '    - %s\n' "$l"; done
fi
printf '\n  total model payload for this profile: %s GB (%s file(s))\n' "$(gb "$BYTES_TOTAL")" "$MODELS_PLANNED"
printf '  elapsed            : %s\n' "$(elapsed)"
[ "$DRY_RUN" = "1" ] && printf '\n  %sThis was a DRY RUN. Nothing above was actually done.%s\n' "$C_WARN" "$C_OFF"

# Things Jake has to decide -- Jake rule 8: flag, never silently choose.
# Three of these only apply to the Singularity profile, so they are gated: a
# FLAGS block full of irrelevant lines stops being read.
if wanted_profile "singularity-2pass"; then
  # The repo graph h3_singularity_2pass_*.json names the PRUNED int8 file in its
  # UNETLoader widget (node 10), so the default needs no graph edit. The other
  # two choices do.
  case "$SINGULARITY_UNET" in
    pruned_int8)
      flag "Singularity UNET = pruned_int8 (20.97 GB), which is exactly what h3_singularity_2pass_api.json node 10 names -- no graph edit needed. as_authored is 34.00 GB at the same quantisation; w4a8 is 11.77 GB with an UNVERIFIED quality cost."
      ;;
    as_authored)
      flag "Singularity UNET = as_authored (34.00 GB), NOT the file the repo graph's UNETLoader names. Point node 10 at it: --set 10.unet_name=Minimax-h3_Singularity_ref2va_v1.3_int8.safetensors  -- or re-run with SINGULARITY_UNET=pruned_int8 and change nothing."
      ;;
    w4a8)
      flag "Singularity UNET = w4a8 (11.77 GB, quality cost UNVERIFIED), NOT the file the repo graph's UNETLoader names. Point node 10 at it: --set 10.unet_name=Minimax-h3_Singularity_ref2va_v1.3_Pruned_w4a8.safetensors  -- or re-run with SINGULARITY_UNET=pruned_int8 and change nothing."
      ;;
  esac
  flag "Video VAE: fp16 (5,207,808,496 B), NOT the int8_convrot file the downloaded README names. MEASURED 2026-09-29 on an A100 pod: the int8 VAE dies in VAE decode with 'detect_k_anchor kernel launch failed: CUDA driver version is insufficient for CUDA runtime version' (comfy/ldm/minimax/vae.py -> comfy_kitchen int8_attention). Runpod driver was 570.172.08. fp16 costs 2.4 GB more and needs no int8 kernels; on an 80 GB card there is no reason to want int8."
  flag "MiniMaxH3NativeAudioLock has NO license anywhere in the Shrek3OnVH5 repo. 71 lines, no weights, but the film is monetized. MIT alternative badgids/ComfyUI-H3-ExactAudioLock is not a drop-in (different class key)."
fi
flag "MiniMax authorization for Firestarter Media LLC is on file (api@minimax.io, 2026-09-29). Open: does a third-party fine-tune (Singularity) count as an 'H3 Work'? One line to api@minimax.io settles it."
flag "The 8188 proxy URL has NO authentication and is public. Treat the pod id as a secret, keep sessions short, and terminate when done (stop_pod.sh)."
if [ "${#FLAGS[@]}" -gt 0 ]; then
  printf '\n  %sFLAGS -- needs Jake:%s\n' "$C_WARN" "$C_OFF"
  for l in "${FLAGS[@]}"; do printf '    ! %s\n' "$l"; done
fi

cat <<NEXT

  next, from Jake's PC:
    py=D:\\ComfyUI\\Comfy New_09_2026\\ComfyUI\\.venv\\Scripts\\python.exe
    t=Z:\\Claude\\comfyui\\_tools
    1. \$py \$t\\comfy_api.py --server https://${RUNPOD_POD_ID:-<pod-id>}-8188.proxy.runpod.net stats
    2. \$py \$t\\dump_object_info.py live --server https://${RUNPOD_POD_ID:-<pod-id>}-8188.proxy.runpod.net
       (snapshot the pod's node catalog into _schemas\\ -- proves the pack set is right
        BEFORE a GPU-second goes into a render)
    3. \$py \$t\\validate_workflow.py <folder> --object-info <that snapshot>
    4. one short audition, Jake approves, --save-prompt locks it, then the batch
    5. bash $SCRIPT_DIR/stop_pod.sh --confirm     <-- TERMINATE the pod when done

NEXT

# =============================================================================
step "5. ComfyUI"
# =============================================================================
if [ "$START_COMFY" = "0" ]; then
  skip "START_COMFY=0 / --no-start -- not starting ComfyUI"
  info "start it by hand with:  cd $COMFY_DIR && source ${VENV_DIR#"$COMFY_DIR/"}/bin/activate && python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header"
  exit 0
fi
if [ "$COMFY_WAS_UP" = "1" ]; then
  warn "ComfyUI was already serving on 8188 before this script ran, so it has NOT loaded"
  warn "the packs installed above. Restart it yourself:"
  warn "  pkill -f 'main.py --listen' ; cd $COMFY_DIR && source $(basename "$VENV_DIR")/bin/activate && python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header &"
  warn "or just restart the pod. This script never kills a running ComfyUI."
  exit 0
fi
if [ "$DRY_RUN" = "1" ]; then
  if [ -x /start.sh ]; then info "would: exec /start.sh   (the image's own supervisor: ComfyUI + SSH + Jupyter + FileBrowser, and it forwards SIGTERM)"
  else info "would: exec $PY $COMFY_DIR/main.py --listen 0.0.0.0 --port 8188 --enable-cors-header"; fi
  exit 0
fi
if [ -x /start.sh ] && [ "${USE_START_SH:-1}" = "1" ]; then
  log "exec /start.sh -- it starts ComfyUI on 0.0.0.0:8188 plus SSH, Jupyter and FileBrowser"
  cd /
  exec /start.sh
fi
log "starting ComfyUI on 0.0.0.0:8188"
cd "$COMFY_DIR" || die "cannot cd to $COMFY_DIR"
exec "$PY" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header
