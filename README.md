# Frigate for Intel Panther Lake

[Frigate](https://github.com/blakeblackshear/frigate) 0.18.2, rebuilt on Ubuntu 24.04
with an Intel stack new enough for Panther Lake (Intel Core Ultra series 3): the Xe3
iGPU for VA-API decode and OpenVINO `GPU`, and the NPU50xx for OpenVINO `NPU`.

Frigate itself is unchanged. Its Docker build is changed by three small patches in
[`patches/`](patches), applied to a pinned upstream commit, so the whole difference
from stock Frigate fits on a screen.

> This build stands on the work of [@timothystewart6](https://github.com/timothystewart6)
> in [frigate-intel-npu](https://github.com/timothystewart6/frigate-intel-npu), which
> worked out why Frigate could not use the Panther Lake NPU and GPU, and how to fix it,
> for Frigate 0.17.2. See [Credits](#credits).

| | Upstream 0.18.2 | This build |
|---|---|---|
| Base | Debian 12 | Ubuntu 24.04, Python 3.11 from deadsnakes |
| OpenVINO | 2025.4 | 2026.3.1 |
| NPU userspace | 1.19 (no NPU50xx) | 1.38 |
| GPU compute / IGC | 26.14 / 2.32 | 26.31 / 2.40 (Kobuk PPA) |
| Level Zero | 1.28.2 | 1.32.0 (Kobuk PPA) |
| Media driver | 25.2.6, built from source | 26.3.2 (Kobuk PPA) |

The Kobuk team PPA is the Intel graphics stack that Intel validates its NPU driver
against; it is only published for Ubuntu, which is why the base changes.

## Tested on

- Intel Core Ultra 9 386H, with the Xe3 iGPU (SR-IOV virtual function) and the NPU
  passed through to an Ubuntu 24.04 VM, kernel 7.0, running k3s with Intel's GPU and
  NPU device plugins.
- Two cameras at 5 fps detect, VA-API decode, YOLOv9 on the NPU.

[frigate-intel-npu](https://github.com/timothystewart6/frigate-intel-npu) has
bare-metal results on the same CPU for Frigate 0.17.2, including wall-power
measurements for CPU, GPU and NPU detection.

## Image

```
ghcr.io/sterion/frigate-npu:<version>
```

Versions are the Frigate version and a build number, e.g. `0.18.2-1`; `latest` and
`0.18.2` follow the newest build.

## Running it

The container needs the GPU render node and the NPU device:

```yaml
services:
  frigate:
    image: ghcr.io/sterion/frigate-npu:latest
    devices:
      - /dev/dri:/dev/dri
      - /dev/accel:/dev/accel
    group_add:
      - "992"    # the host's render group id; check with: getent group render
```

On Kubernetes with Intel's device plugins, request one of each:

```yaml
resources:
  limits:
    gpu.intel.com/xe: 1
    npu.intel.com/accel: 1
```

The NPU firmware comes from the host kernel; the image only carries the userspace.

### Keep the NPU powered

By default the kernel suspends the NPU after 100 ms without work. Frigate detects at
5 fps, so in a quiet scene the NPU sleeps between almost every frame and each
detection pays ~10 ms to wake it: the detector speed swings between ~9 and 25 ms.
With runtime power management off it stays flat:

| YOLOv9-t 640, one detection every 2 s | Detector total |
|---|---|
| default (`auto`, 100 ms delay) | 19.4 ms |
| `power/control=on` | 8.7 ms |

On the host:

```bash
for d in /sys/bus/pci/drivers/intel_vpu/0000:*; do echo on | sudo tee "$d/power/control"; done
```

That does not survive a reboot. On Kubernetes a privileged init container in the
Frigate pod sets it on every start:

```yaml
initContainers:
  - name: npu-power
    image: busybox:1.38
    securityContext:
      privileged: true
    command: ['sh', '-c', 'for d in /sys/bus/pci/drivers/intel_vpu/0000:*; do echo on > "$d/power/control"; done']
```

The idle NPU draws a fraction of the ~0.6 W it uses while detecting.

Even so, the first detection after minutes without motion takes 40–100 ms; the next
ones are back to normal. On a quiet night Frigate's average climbs because of those
single detections, and drops again as soon as anything moves.

## Models

The NPU only compiles models with static input shapes, so every resolution is its
own model file. YOLOv9 works well; export it with the recipe in
[Frigate's OpenVINO documentation](https://docs.frigate.video/configuration/object_detectors#openvino-detector),
put it under `/config/model_cache` and point the config at it:

```yaml
detectors:
  ov:
    type: openvino
    device: NPU
model:
  model_type: yolo-generic
  width: 512
  height: 512
  input_tensor: nchw
  input_dtype: float
  path: /config/model_cache/yolov9-s-512.onnx
  labelmap_path: /labelmap/coco-80.txt
```

Detector speed in Frigate on the 386H NPU, with the NPU kept powered:

| Model | Detector speed | COCO mAP (published, at 640) |
|---|---|---|
| YOLOv9-t 640 | ~8 ms | 38.3 |
| YOLOv9-s 512 | ~6–7 ms | 46.8 |
| YOLOv9-m 512 | ~11 ms | 51.4 |

The bundled SSDLite MobileNet v2 also runs on the NPU.

`coco-80` keeps `truck` apart from `car`, unlike the label map that comes with
SSDLite; track it too if vans and trucks should count.

### Two detectors on one NPU

One detector leaves the NPU idle ~30% of the time while Frigate pre- and
post-processes on the CPU. A second detector fills those gaps; a third adds nothing.
YOLOv9-m 512:

| Detectors | Detections/s | NPU busy |
|---|---|---|
| 1 | 104 | 70% |
| 2 | 154 | 100% |
| 3 | 154 | 100% |

Both detectors share the one NPU device; no extra device-plugin share is needed:

```yaml
detectors:
  ov_0:
    type: openvino
    device: NPU
  ov_1:
    type: openvino
    device: NPU
```

## Checking the hardware

```bash
docker exec frigate verify-frigate-intel
```

runs a model on the GPU and the NPU and probes VA-API on every render node.
`--static` checks the installed userspace without any hardware.

## Building

```bash
./build.sh                      # image frigate-npu:local
./build.sh --prepare            # patched tree in work/ only
```

`build.ps1` does the same on Windows. A cold build took 13 minutes on a 24-thread
machine and needs ~24 GB of disk.

The build clones Frigate at the tag in [`upstream.env`](upstream.env), refuses
anything but the pinned commit, applies the patches with `git am` and copies
[`overlay/`](overlay) on top.

To change a patch, run `./build.sh --prepare`, edit and commit in `work/`, then
export the series again:

```bash
rm patches/*.patch
git -C work format-patch -N --zero-commit --no-signature -o ../patches <FRIGATE_COMMIT>
```

The pins that live in the patches: `PPA_SNAPSHOT` (Dockerfile), the NPU driver URL
and SHA-256 (`install_deps.sh`) and OpenVINO (`requirements-wheels.txt`,
`requirements-ov.txt`).

## Credits

[@timothystewart6](https://github.com/timothystewart6)'s
[frigate-intel-npu](https://github.com/timothystewart6/frigate-intel-npu) did the hard
part for Frigate 0.17.2:

- found that Frigate already supports the NPU, and that what stood in the way was the
  Intel userspace bundled in its image, too old for Panther Lake;
- rebuilt Frigate on Ubuntu 24.04 with Python 3.11 from deadsnakes, the approach the
  first patch here follows;
- replaced the GPU compute runtime and media driver with the Kobuk PPA builds, which
  made OpenVINO `GPU` and VA-API decode work on the Xe3 iGPU;
- proved the NPU really runs the model, and measured CPU, GPU and NPU detection in a
  real Frigate setup, down to the wall power.

This repository carries that work forward to Frigate 0.18.2 as a patch series, with
newer NPU, GPU and OpenVINO releases.

[Frigate](https://github.com/blakeblackshear/frigate) is the NVR all of this runs on.

## License

MIT; see [LICENSE](LICENSE).

The patches modify Frigate's Docker build files, which are Copyright (c) 2026
Frigate, Inc. (Frigate™) and released under the
[MIT License](https://github.com/blakeblackshear/frigate/blob/dev/LICENSE); that
notice applies to those files too. Intel's drivers, OpenVINO and the other packages
installed into the image keep their own licenses.
