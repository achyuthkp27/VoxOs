# Parakeet Redux helper

Runs [`moondream/parakeet-redux`](https://huggingface.co/moondream/parakeet-redux) (a 178 MB, ternary-weight
build of NVIDIA Parakeet 0.6B v3, 25 European languages) as a local transcription server that VoxOS can use
through its **Custom** transcription provider. Audio stays on the machine: the server binds to `127.0.0.1`
only, and the one network call is the first-run model download.

VoxOS already ships native Parakeet (FluidAudio / CoreML). Use this helper when you want to try Redux itself.

## Run

```shell
make parakeet-redux          # or: scripts/parakeet-redux/run.sh --port 8765
```

First run creates `~/VoxOS-Dependencies/parakeet-env` (override with `PARAKEET_VENV`) and downloads the model.
Options: `--port` (default 8765), `--device cpu|mps|cuda` (default: auto), `--token SECRET`.

## Use it in VoxOS

Settings → Models → Custom → add a model:

| Field | Value |
| --- | --- |
| Endpoint | `http://127.0.0.1:8765/v1/audio/transcriptions` |
| Model name | `parakeet-redux` |
| API key | anything (or the `--token` value if you set one) |

## Behaviour

- Model loads once at startup and stays loaded; requests are serialised.
- `GET /health` reports readiness. Errors return JSON with 400/401/404/413/500 and never include audio or text.
- Measured on an Apple Silicon Mac: ~1.7 s for the first request, ~0.06 s for a repeat on a 4 s clip.
- Known limits: European languages only; one review reports reduced accuracy on noisy audio.
