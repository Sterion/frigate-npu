# AGENTS.md

This repository builds a Frigate image for Intel Panther Lake. It holds no Frigate
source: the build clones upstream at a pinned commit and applies a patch series.

## Layout

| Path | |
|---|---|
| `upstream.env` | Frigate tag and the commit it must resolve to |
| `patches/` | Changes to Frigate, applied in order with `git am`: its Docker build, and the `FRIGATE_NPU_TURBO` switch |
| `overlay/` | Files added to the tree as-is (`verify-frigate-intel`) |
| `build.sh`, `build.ps1` | The same build for Linux and Windows |
| `.github/workflows/` | `image.yml` builds, smoke-tests and pushes; `build.yml` and `release.yml` call it |

`work/` is generated and gitignored.

## Rules

- Never commit Frigate's files. Every change to Frigate goes in a patch.
- Change patches through `work/`: `./build.sh --prepare`, commit there, then export
  with `git -C work format-patch -N --zero-commit --no-signature -o ../patches <FRIGATE_COMMIT>`.
  `-N` keeps one patch from rewriting the others' headers.
- Keep patches small and each about one thing, with a commit message that says why.
  They are what readers of this repository look at.
- `build.sh` and `build.ps1` take the same options and do the same steps; change both.
- The workflows run on `workflow_dispatch` only. Do not add push, tag or schedule
  triggers unless the owner asks for them.
- Everything is LF (`.gitattributes`); patches and shell scripts break with CRLF.
- No personal or site-specific data: no hostnames, addresses, credentials or camera
  names in the README, examples or patches.

## Pins

Frigate in `upstream.env`. In the patches: `PPA_SNAPSHOT` (Dockerfile), the NPU driver
URL and SHA-256 (`install_deps.sh`) and OpenVINO (`requirements-wheels.txt`,
`requirements-ov.txt`). The Kobuk PPA stack and NPU driver version go together: Intel
validates each NPU driver release against a specific GPU stack and OpenVINO version.

## Checking a change

1. `./build.sh --prepare` applies every patch cleanly.
2. `./build.sh` builds.
3. `docker run --rm --entrypoint verify-frigate-intel frigate-npu:local --static` passes.

Hardware checks (`verify-frigate-intel` without `--static`) need the Panther Lake
GPU and NPU passed into the container.
