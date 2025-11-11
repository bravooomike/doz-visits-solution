<#
  Power Platform Solution Update Script (with Semantic Versioning)
  ---------------------------------------------------------------
  What it does:
    1) Export solution from environment
    2) Unpack to /src (text-based sources)
    3) Auto-bump version in Solution.xml (SemVer)
    4) Remove temporary solution.zip
    5) git add/commit/push (optional git tag)

  Usage examples:
    .\update.ps1 -SolutionName DOZVisits -Message "fix: header spacing"
    .\update.ps1 -SolutionName DOZVisits -Message "feat: add search" -VersionBump minor
    .\update.ps1 -SolutionName DOZVisits -Message "hotfix: patch" -Prerelease "rc.1" -Tag
    .\update.ps1 -SolutionName DOZVisits -Message "release: managed export" -Managed
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$SolutionName,

  [Parameter(Mandatory=$true)]
  [string]$Message,

  [string]$EnvUrl,

  [ValidateSet("patch","minor","major")]
  [string]$VersionBump = "patch",

  [string]$Prerelease,          # e.g., "rc.1" → 1.2.3-rc.1
  [switch]$Tag,                 # create annotated git tag "vX.Y.Z[-pre]"
  [switch]$Managed              # export managed instead of unmanaged (default = unmanaged)
)

$ErrorActionPreference = "Stop"

function Fail($m){ Write-Host "❌ $m" -f Red; exit 1 }
function Info($m){ Write-Host "▶ $m" -f Cyan }
function Ok($m){   Write-Host "✅ $m" -f Green }

# Ensure we're at repo root
if (-not (Test-Path ".git")) { Fail "Run this script from the root of your Git repo." }

# PAC CLI available?
try { pac --help | Out-Null } catch { Fail "PAC CLI not found in PATH." }

# Optional environment switch (creates/activates a profile)
if ($EnvUrl) {
  Info "Switching PAC to $EnvUrl"
  pac auth create --environment $EnvUrl --deviceCode | Out-Null
}

# Check active PAC auth robustly (language-agnostic)
$null = & pac org who 2>$null
if ($LASTEXITCODE -ne 0) {
  Fail "No active PAC auth. Run: pac auth create --environment <url> --deviceCode"
}

# 1) Export solution
$zipPath = Join-Path (Get-Location) "solution.zip"
$managedFlag = $Managed.IsPresent
Info "Exporting solution '$SolutionName' (managed: $managedFlag) → $zipPath"
pac solution export --name $SolutionName --managed:$managedFlag --path $zipPath

# 2) Unpack to /src
$srcPath = Join-Path (Get-Location) "src"
Info "Unpacking to $srcPath (allowDelete=true)"
pac solution unpack --zipFile $zipPath --folder $srcPath --allowDelete true

# 3) Bump version in Solution.xml (SemVer)
function Get-SolutionXmlPath {
  $candidates = Get-ChildItem -Path $srcPath -Filter "Solution.xml" -Recurse -File -ErrorAction SilentlyContinue
  if ($candidates.Count -eq 0) { Fail "Solution.xml not found under $srcPath. Unpack result unexpected." }
  return ($candidates | Sort-Object FullName | Select-Object -First 1).FullName
}

function Bump-SemVer {
  param([string]$version, [string]$bump, [string]$prerelease)
  # Accept "1.2.3" or "1.2.3-xxx"; ignore existing prerelease for bumping
  $base = $version.Split("-")[0]
  $parts = $base.Split(".")
  if ($parts.Count -lt 3) { Fail "Invalid solution version '$version'. Expected MAJOR.MINOR.PATCH." }
  [int]$maj = $parts[0]; [int]$min = $parts[1]; [int]$pat = $parts[2]
  switch ($bump) {
    "major" { $maj++; $min=0; $pat=0 }
    "minor" { $min++; $pat=0 }
    "patch" { $pat++ }
  }
  $new = "$maj.$min.$pat"
  if ($prerelease) { $new = "$new-$prerelease" }
  return $new
}

$solutionXmlPath = Get-SolutionXmlPath
[xml]$xml = Get-Content -LiteralPath $solutionXmlPath
# Typical XPath for version element in Solution.xml
$versionNode = $xml.SelectSingleNode("//SolutionManifest/Version")
if (-not $versionNode) { $versionNode = $xml.SelectSingleNode("//Version") }
if (-not $versionNode) { Fail "Version node not found in Solution.xml ($solutionXmlPath)." }

$oldVersion = $versionNode.InnerText.Trim()
$newVersion = Bump-SemVer -version $oldVersion -bump $VersionBump -prerelease $Prerelease

if ($newVersion -ne $oldVersion) {
  Info "Bumping version: $oldVersion → $newVersion"
  $versionNode.InnerText = $newVersion
  $xml.Save($solutionXmlPath)
} else {
  Info "Version unchanged ($oldVersion)."
}

# 4) Remove temporary zip
if (Test-Path $zipPath) { Remove-Item $zipPath -Force; Info "Removed solution.zip" }

# 5) Stage changes
Info "Staging all changes (git add -A)"
git add -A

# If nothing changed, exit gracefully
$staged = (git diff --cached --name-only)
if (-not $staged) { Ok "No changes detected. Nothing to commit or push."; exit 0 }

# 6) Commit
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
$commitMsg = "$Message (version: $newVersion, $ts)"
Info "Committing: $commitMsg"
git commit -m $commitMsg

# 7) Push
Info "Pushing to remote..."
git push

# 8) Optional git tag (vX.Y.Z[-pre])
if ($Tag) {
  $tagName = "v$($newVersion)"
  Info "Creating git tag $tagName"
  git tag -a $tagName -m "Release $tagName"
  git push --tags
}

Ok "Done. Solution updated (version $newVersion) and pushed."
