<#
.SYNOPSIS
Build Frigate for Intel Panther Lake from the pinned upstream release.

.DESCRIPTION
Clones Frigate at the tag in upstream.env into work/, refuses anything but the
pinned commit, applies patches/ with git am (one commit per patch), copies
overlay/ on top and builds the image into the local Docker image store.
build.sh does the same on Linux.

.EXAMPLE
./build.ps1

.EXAMPLE
./build.ps1 -Prepare

.EXAMPLE
./build.ps1 -Tag ghcr.io/sterion/frigate-npu:test -Push
#>
[CmdletBinding()]
param(
  # Stop once work/ holds the patched tree, without building.
  [switch]$Prepare,
  # Version Frigate reports; defaults to <frigate version>-npu-<commit>.
  [string]$Version,
  [string[]]$Tag = @('frigate-npu:local'),
  # Image labels as KEY=VALUE.
  [string[]]$Label = @(),
  [switch]$Push
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = $PSScriptRoot
$work = Join-Path $root 'work'
$marker = Join-Path $work '.git/frigate-npu-prepared'

$pin = @{}
foreach ($line in Get-Content (Join-Path $root 'upstream.env')) {
  if ($line -match '^(\w+)=(.*)$') { $pin[$Matches[1]] = $Matches[2] }
}

# work/ is regenerated on every run; refuse to throw away patch work that was
# not exported to patches/ yet.
if (Test-Path (Join-Path $work '.git')) {
  $prepared = (Test-Path $marker) ? (Get-Content $marker) : ''
  $head = git -C $work rev-parse HEAD
  $PSNativeCommandUseErrorActionPreference = $false
  git -C $work diff --quiet HEAD
  $clean = $LASTEXITCODE -eq 0
  $PSNativeCommandUseErrorActionPreference = $true
  if (-not $clean -or $head -ne $prepared) {
    throw "work/ has changes that are not in patches/. Export them with git format-patch, or delete work/."
  }
}
if (Test-Path $work) { Remove-Item -Recurse -Force $work }

git -c core.autocrlf=false -c advice.detachedHead=false clone --quiet --depth 1 --branch $pin.FRIGATE_TAG https://github.com/blakeblackshear/frigate.git $work
git -C $work config core.autocrlf false
$head = git -C $work rev-parse HEAD
if ($head -ne $pin.FRIGATE_COMMIT) {
  throw "$($pin.FRIGATE_TAG) is $head, expected $($pin.FRIGATE_COMMIT). Review the upstream change before moving the pin."
}

$patches = (Get-ChildItem (Join-Path $root 'patches/*.patch') | Sort-Object Name).FullName
git -C $work -c user.name=frigate-npu -c user.email=frigate-npu@localhost am --quiet @patches
git -C $work rev-parse HEAD | Set-Content $marker

Copy-Item -Path (Join-Path $root 'overlay/*') -Destination $work -Recurse -Force

$PSNativeCommandUseErrorActionPreference = $false
$short = (git -C $root rev-parse --short HEAD 2>$null) ?? 'dev'
$PSNativeCommandUseErrorActionPreference = $true
if (-not $Version) { $Version = "$($pin.FRIGATE_TAG.TrimStart('v'))-npu-$short" }
[IO.File]::WriteAllText((Join-Path $work 'frigate/version.py'), "VERSION = `"$Version`"`n")
[IO.File]::WriteAllText((Join-Path $work 'web/.env'), "VITE_GIT_COMMIT_HASH=$short`n")
Write-Host "work/ prepared: Frigate $Version"

if ($Prepare) { return }

$tagArgs = $Tag | ForEach-Object { '--tag', $_ }
$labelArgs = $Label | ForEach-Object { '--label', $_ }
docker buildx build --file (Join-Path $work 'docker/main/Dockerfile') --target frigate @tagArgs @labelArgs --load $work
if ($Push) { $Tag | ForEach-Object { docker push $_ } }
