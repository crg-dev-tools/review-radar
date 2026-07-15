<#
.SYNOPSIS
  Install the isolated-review TAKT assets (custom facets, workflow, perspective
  catalog) into the current project's ./.takt/ so `takt` can resolve them.

.DESCRIPTION
  Idempotent: existing files are left untouched unless -Force is given, so
  per-project customizations (e.g. an edited catalog) are never clobbered.

.PARAMETER TargetRoot
  Project root to install into. Defaults to the current working directory.

.PARAMETER Force
  Overwrite existing files.

.EXAMPLE
  ./setup-takt.ps1
  ./setup-takt.ps1 -TargetRoot C:\path\to\repo -Force
#>
param(
  [string]$TargetRoot = (Get-Location).Path,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src = Join-Path $ScriptDir '..\takt'
$Src = (Resolve-Path $Src).Path
$Dest = Join-Path $TargetRoot '.takt'

Write-Output "Installing isolated-review TAKT assets into $Dest"
Get-ChildItem -Path $Src -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($Src.Length).TrimStart('\', '/')
  $dst = Join-Path $Dest $rel
  $dstDir = Split-Path -Parent $dst
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
  if ((Test-Path $dst) -and (-not $Force)) {
    Write-Output "  skip (exists): $rel"
  } else {
    Copy-Item -Path $_.FullName -Destination $dst -Force
    Write-Output "  installed: $rel"
  }
}
Write-Output "Done. Custom facets, workflow, and perspective catalog are available to takt."
Write-Output "Builtin facets (coding-reviewer, security-reviewer, findings-manager, ...) resolve automatically."
