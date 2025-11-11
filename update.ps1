<#
  Power Platform Solution Update Script (with Semantic Versioning)
  ---------------------------------------------------------------

  What it does:
    1) Export solution from environment
    2) Unpack to /src (text-based sources)
    3) Optionally bump version in Solution.xml (SemVer)
    4) Remove temporary solution.zip
    5) git add/commit/push (optional git tag)

  Usage examples
  --------------

  1) Standard snapshot (no explicit bump):
     Commits ONLY if the solution actually changed (Canvas .msapp noise is ignored).
     Commit message will contain the current version.
     .\update.ps1 -SolutionName DOZVisits -Message "fix: corrected validation"

  2) Force a version bump even if nothing changed:
     Useful for marking a release/milestone. Creates a commit even when no solution changes exist.
     .\update.ps1 -SolutionName DOZVisits -Message "release: prepare" -VersionBump patch

  3) Solution changes + intentional version progression:
     Typical for feature work or breaking changes.
     .\update.ps1 -SolutionName DOZVisits -Message "feat: bulk operations" -VersionBump minor
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$SolutionName,

  [Parameter(Mandatory=$true)]
  [string]$Message,

  [string]$EnvUrl,

  [ValidateSet("none","patch","minor","major")]
  [string]$VersionBump = "none",

  [string]$Prerelease,
  [switch]$Tag,
  [switch]$Managed
)

$ErrorActionPreference = "Stop"

function Fail($m){ Write-Host "❌ $m" -f Red; exit 1 }
function Info($m){ Write-Host "▶ $m" -f Cyan }
function Ok($m){ Write-Host "✅ $m" -f Green }

if (-not (Test-Path ".git")) { Fail "Run this script from the root of your Git repo." }
try { pac --help | Out-Null } catch { Fail "PAC CLI not found in PATH." }

if ($EnvUrl) {
  Info "Switching PAC to $EnvUrl"
  pac auth create --environment $EnvUrl --deviceCode | Out-Null
}

$null = & pac org who 2>$null
if ($LASTEXITCODE -ne 0) { Fail "No active PAC auth. Run: pac auth create --environment <url> --deviceCode" }

# 1) Export solution
$zipPath = Join-Path (Get-Location) "solution.zip"
Info "Exporting solution '$SolutionName' (managed: $($Managed.IsPresent)) -> $zipPath"
if ($Managed) {
  pac solution export --name $SolutionName --managed --path $zipPath
} else {
  pac solution export --name $SolutionName --path $zipPath
}

# 2) Unpack
$srcPath = Join-Path (Get-Location) "src"
Info "Unpacking solution -> $srcPath"
pac solution unpack --zipFile $zipPath --folder $srcPath --allowDelete true

# Helpers
function Get-SolutionXmlPath {
  $candidates = Get-ChildItem -Path $srcPath -Filter "Solution.xml" -Recurse -File -ErrorAction SilentlyContinue
  if ($candidates.Count -eq 0) { Fail "Solution.xml not found after unpack." }
  return ($candidates | Select-Object -First 1).FullName
}
function Bump-SemVer {
  param([string]$version, [string]$bump, [string]$prerelease)
  $base = $version.Split("-")[0]
  $parts = $base.Split(".")

  [int]$maj = $parts[0]
  [int]$min = $parts[1]
  [int]$pat = $parts[2]

  switch ($bump) {
    "major" { $maj++; $min=0; $pat=0 }
    "minor" { $min++; $pat=0 }
    "patch" { $pat++ }
    default { }
  }

  $new = "$maj.$min.$pat"
  if ($prerelease) { $new = "$new-$prerelease" }
  return $new
}

# Read version (used in commit message even if not bumped)
$solutionXmlPath = Get-SolutionXmlPath
[xml]$xml = Get-Content -LiteralPath $solutionXmlPath

# PS 5.1-compatible fallback instead of '??'
$versionNode = $xml.SelectSingleNode("//SolutionManifest/Version")
if (-not $versionNode) { $versionNode = $xml.SelectSingleNode("//Version") }
if (-not $versionNode) { Fail "Version node not found in Solution.xml ($solutionXmlPath)." }

$oldVersion = $versionNode.InnerText.Trim()
$newVersion = $null

# Noise filters (ignore Canvas bundle noise if they are the only changes)
$NoisePatterns = @(
  '\.msapp$',
  '_BackgroundImageUri$',
  '_AdditionalUris'
)

# Raw changes (before staging)
$changesRaw = git status --porcelain | ForEach-Object { $_.Substring(3) } |
  Where-Object { $_ -and $_.Trim().Length -gt 0 }

$realChanged = @()
foreach ($p in $changesRaw) {
  $isNoise = $false
  foreach ($pattern in $NoisePatterns) {
    if ($p -imatch $pattern) { $isNoise = $true; break }
  }
  if (-not $isNoise) { $realChanged += $p }
}

# No real changes & no bump -> exit
if (-not $realChanged -and $VersionBump -eq "none") {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Ok "No real solution changes (Canvas noise ignored). Nothing committed."
  exit 0
}

# Optional bump
if ($VersionBump -ne "none") {
  $newVersion = Bump-SemVer -version $oldVersion -bump $VersionBump -prerelease $Prerelease
  if ($newVersion -ne $oldVersion) {
    Info "Bumping version: $oldVersion -> $newVersion"
    $versionNode.InnerText = $newVersion
    $xml.Save($solutionXmlPath)
    # Use full path (PS5 doesn't reliably support Resolve-Path -Relative for git add)
    $realChanged += $solutionXmlPath
  }
}

# Cleanup temp zip
if (Test-Path $zipPath) { Remove-Item $zipPath -Force; Info "Removed temporary solution.zip" }

# Stage only real changes
$toStage = $realChanged | Select-Object -Unique
if (-not $toStage) {
  Ok "No commit required after filtering noise & optional bump."
  exit 0
}

Info "Staging files..."
git add -- $toStage

# Commit (always include version)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
$commitVersion = $(if ($newVersion) { $newVersion } else { $oldVersion })
$commitMsg = "$Message (version: $commitVersion, $ts)"
Info "Committing: $commitMsg"
git commit -m $commitMsg

Info "Pushing..."
git push

if ($Tag -and $newVersion) {
  $tagName = "v$($newVersion)"
  Info "Tagging $tagName"
  git tag -a $tagName -m "Release $tagName"
  git push --tags
}

Ok "Done. Solution exported, unpacked, versioned and pushed."
