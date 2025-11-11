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
     Commits ONLY if the solution actually changed. Version is included in the message (current version if not bumped).
     .\update.ps1 -SolutionName DOZVisits -Message "fix: corrected validation"

  2) Force a version bump even if nothing changed:
     Useful for marking a release/milestone. Creates a commit with version bump only.
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

  [string]$Prerelease,          # e.g., "rc.1" → 1.2.3-rc.1
  [switch]$Tag,                 # create annotated git tag "vX.Y.Z[-pre]"
  [switch]$Managed              # export managed instead of unmanaged (default = unmanaged)
)

$ErrorActionPreference = "Stop"

function Fail($m){ Write-Host "❌ $m" -f Red; exit 1 }
function Info($m){ Write-Host "▶ $m" -f Cyan }
function Ok($m){   Write-Host "✅ $m" -f Green }

if (-not (Test-Path ".git")) { Fail "Run this script from the root of your Git repo." }
try { pac --help | Out-Null } catch { Fail "PAC CLI not found in PATH." }

if ($EnvUrl) {
  Info "Switching PAC to $EnvUrl"
  pac auth create --environment $EnvUrl --deviceCode | Out-Null
}

$null = & pac org who 2>$null
if ($LASTEXITCODE -ne 0) {
  Fail "No active PAC auth. Run: pac auth create --environment <url> --deviceCode"
}

# 1) Export solution
$zipPath = Join-Path (Get-Location) "solution.zip"
Info "Exporting solution '$SolutionName' (managed: $($Managed.IsPresent)) → $zipPath"
# pass --managed only when true (PAC doesn't accept '--managed:false')
if ($Managed) {
  pac solution export --name $SolutionName --managed --path $zipPath
} else {
  pac solution export --name $SolutionName --path $zipPath
}

# 2) Unpack to /src
$srcPath = Join-Path (Get-Location) "src"
Info "Unpacking to $srcPath (allowDelete=true)"
pac solution unpack --zipFile $zipPath --folder $srcPath --allowDelete true

# Helpers
function Get-SolutionXmlPath {
  $candidates = Get-ChildItem -Path $srcPath -Filter "Solution.xml" -Recurse -File -ErrorAction SilentlyContinue
  if ($candidates.Count -eq 0) { Fail "Solution.xml not found under $srcPath. Unpack result unexpected." }
  return ($candidates | Sort-Object FullName | Select-Object -First 1).FullName
}
function Bump-SemVer {
  param([string]$version, [string]$bump, [string]$prerelease)
  $base = $version.Split("-")[0]
  $parts = $base.Split(".")
  if ($parts.Count -lt 3) { Fail "Invalid solution version '$version'. Expected MAJOR.MINOR.PATCH." }
  [int]$maj = $parts[0]; [int]$min = $parts[1]; [int]$pat = $parts[2]
  switch ($bump) {
    "major" { $maj++; $min=0; $pat=0 }
    "minor" { $min++; $pat=0 }
    "patch" { $pat++ }
    default  { } # none
  }
  $new = "$maj.$min.$pat"
  if ($prerelease) { $new = "$new-$prerelease" }
  return $new
}

# Read current version (we'll include it in commit message even if we don't bump)
$solutionXmlPath = Get-SolutionXmlPath
[xml]$xml = Get-Content -LiteralPath $solutionXmlPath
$versionNode = $xml.SelectSingleNode("//SolutionManifest/Version")
if (-not $versionNode) { $versionNode = $xml.SelectSingleNode("//Version") }
if (-not $versionNode) { Fail "Version node not found in Solution.xml ($solutionXmlPath)." }
$oldVersion = $versionNode.InnerText.Trim()
$newVersion  = $null

# 3) Detect changes BEFORE staging
# We ignore solution.zip (we delete it anyway) and we will separately decide about Solution.xml bump
$changes = git status --porcelain
# Remove empty lines and whitespace
$changes = $changes | Where-Object { $_ -and $_.Trim().Length -gt 0 }

# If no changes and no bump requested → exit cleanly
if (-not $changes -and $VersionBump -eq "none") {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Ok "No changes detected. Nothing to commit or push."
  exit 0
}

# 4) If bump requested → bump Solution.xml now
if ($VersionBump -ne "none") {
  $newVersion = Bump-SemVer -version $oldVersion -bump $VersionBump -prerelease $Prerelease
  if ($newVersion -ne $oldVersion) {
    Info "Bumping version: $oldVersion → $newVersion"
    $versionNode.InnerText = $newVersion
    $xml.Save($solutionXmlPath)
  } else {
    Info "Version unchanged ($oldVersion)."
  }
}

# 5) Remove temporary zip
if (Test-Path $zipPath) { Remove-Item $zipPath -Force; Info "Removed solution.zip" }

# 6) Stage only actual working tree changes + possibly bumped Solution.xml
# Recompute now (after optional bump)
$toStage = git status --porcelain | ForEach-Object {
  # output like: " M src\path\file"
  $_.Substring(3)
}
$toStage = $toStage | Where-Object { $_ -and $_.Trim().Length -gt 0 }

if (-not $toStage) {
  Ok "No changes detected after bump. Nothing to commit or push."
  exit 0
}

Info "Staging changed files..."
git add -- $toStage

# 7) Commit (always include a version in message: bumped or current)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
$commitVersion = $(if ($newVersion) { $newVersion } else { $oldVersion })
$commitMsg = "$Message (version: $commitVersion, $ts)"
Info "Committing: $commitMsg"
git commit -m $commitMsg

# 8) Push
Info "Pushing to remote..."
git push

# 9) Optional git tag (vX.Y.Z[-pre]) only when we actually bumped
if ($Tag -and $newVersion) {
  $tagName = "v$($newVersion)"
  Info "Creating git tag $tagName"
  git tag -a $tagName -m "Release $tagName"
  git push --tags
}

Ok "Done. Solution updated and pushed."
