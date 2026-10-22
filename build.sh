#!/usr/bin/env bash
# Build Frigate for Intel Panther Lake from the pinned upstream release.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [--prepare] [--version VERSION] [--tag IMAGE]... [--label KEY=VALUE]...
  --prepare  stop once work/ holds the patched tree, without building
  --version  version Frigate reports (default <frigate version>-npu-<commit>)
  --tag      image name and tag, repeatable (default frigate-npu:local)
  --label    image label, repeatable
EOF
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$root/work
marker=$work/.git/frigate-npu-prepared

prepare=false
version=""
tags=()
labels=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --prepare) prepare=true; shift ;;
    --version) version=$2; shift 2 ;;
    --tag) tags+=("$2"); shift 2 ;;
    --label) labels+=(--label "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ ${#tags[@]} -gt 0 ]] || tags=(frigate-npu:local)

source "$root/upstream.env"

# work/ is regenerated on every run; refuse to throw away patch work that was
# not exported to patches/ yet.
if [[ -d $work/.git ]]; then
  if ! git -C "$work" diff --quiet HEAD || [[ $(git -C "$work" rev-parse HEAD) != "$(cat "$marker" 2>/dev/null)" ]]; then
    echo "work/ has changes that are not in patches/. Export them with git format-patch, or delete work/." >&2
    exit 1
  fi
fi
rm -rf "$work"

git -c core.autocrlf=false -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRIGATE_TAG" https://github.com/blakeblackshear/frigate.git "$work"
git -C "$work" config core.autocrlf false
head=$(git -C "$work" rev-parse HEAD)
if [[ $head != "$FRIGATE_COMMIT" ]]; then
  echo "$FRIGATE_TAG is $head, expected $FRIGATE_COMMIT. Review the upstream change before moving the pin." >&2
  exit 1
fi

git -C "$work" -c user.name=frigate-npu -c user.email=frigate-npu@localhost am --quiet "$root"/patches/*.patch
git -C "$work" rev-parse HEAD > "$marker"
cp -R "$root/overlay/." "$work/"

short=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)
version=${version:-${FRIGATE_TAG#v}-npu-$short}
printf 'VERSION = "%s"\n' "$version" > "$work/frigate/version.py"
printf 'VITE_GIT_COMMIT_HASH=%s\n' "$short" > "$work/web/.env"
echo "work/ prepared: Frigate $version"

$prepare && exit 0

tag_args=()
for tag in "${tags[@]}"; do
  tag_args+=(--tag "$tag")
done
docker buildx build --file "$work/docker/main/Dockerfile" --target frigate "${tag_args[@]}" "${labels[@]}" --load "$work"
