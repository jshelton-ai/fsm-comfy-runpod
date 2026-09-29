# fsm-comfy-runpod

Provisioning scripts that turn a bare [RunPod](https://runpod.io) pod into a working
ComfyUI machine for **MiniMax H3** video generation.

Scripts only — no models, no workflows, no project content. Models are pulled from
Hugging Face at boot; graphs are uploaded per session.

## Use it on a pod

Launch a pod from the **ComfyUI** template (`runpod/comfyui:latest`), open JupyterLab on
port 8888, and in a terminal run:

```bash
curl -sL https://raw.githubusercontent.com/jshelton-ai/fsm-comfy-runpod/main/bootstrap.sh -o bootstrap.sh
PROFILE=singularity-2pass bash bootstrap.sh
```

It upgrades ComfyUI to the pinned version, installs the custom-node packs at pinned commits,
downloads and byte-verifies the models, and starts ComfyUI on `0.0.0.0:8188`. It is idempotent
and resumable — re-run it after any failure. `--dry-run` prints every command without doing
anything.

ComfyUI then answers at `https://<pod-id>-8188.proxy.runpod.net`.

### Profiles

| `PROFILE` | What | Models |
|---|---|---|
| `singularity-2pass` *(default)* | Singularity ref2va + turbo LoRA, two sampler passes with a latent upscale between them, exact-audio lock | 42.72 GB |
| `stock-graphA` | Stock Comfy-Org ref2va with a depth ControlNet | 48.96 GB |
| `all` | Both, deduplicated | 73.43 GB |

Useful switches: `SINGULARITY_UNET=pruned_int8|as_authored|w4a8`, `WANT_DEPTH=1` (adds the Fun
ControlNet Union 2.0 patch), `WANT_SAGE=1` (adds KJNodes; needs the `sageattention` package),
`START_COMFY=0`.

### Disks

| Disk | Size |
|---|---|
| Container | 30 GB |
| Volume (`/workspace`) | 60 GB for one profile, 100 GB for `all` |

## Switching the meter off

```bash
bash stop_pod.sh --confirm                  # terminate now
bash stop_pod.sh --confirm --after-queue    # terminate once the render queue empties
bash stop_pod.sh --confirm --watchdog 30    # terminate after 30 idle minutes
```

It uses the `RUNPOD_POD_ID` and pod-scoped `RUNPOD_API_KEY` that RunPod injects, so there is no
token to handle. `--dry-run` shows what it would call.

## Notes

- A **Container start command is silently ignored** on `runpod/comfyui:latest` — its entrypoint
  does not pass arguments through. Run the bootstrap from a terminal, or build an image with
  its own entrypoint.
- The base image ships an older ComfyUI than MiniMax H3 needs, which is why the bootstrap
  upgrades it. If RunPod publishes a new image tag, the upgrade is reverted on next boot —
  just re-run the bootstrap.
- Pod HTTP proxy URLs are public and unauthenticated. Keep sessions short and terminate when
  finished.

## Licensing

These scripts are MIT. The models they download are not: **MiniMax H3** is under the MiniMax H3
Community License and its use here is covered by a written authorization issued to Firestarter
Media LLC. Anyone else using this repo needs their own. The node packs it installs carry their
own licenses.
