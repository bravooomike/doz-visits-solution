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

# Paths
$root     = Get-Location
$zipPath  = Join-Path $root "solution.zip"
$srcPath  = Join-Path $root "src"
$tmpPath  = Join-Path $root ".tmp_unpacked"

# Clean temp
if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force }

# 1) Export solution
Info "Exporting solution '$SolutionName' (managed: $($Managed.IsPresent)) -> $zipPath"
if ($Managed) {
  pac solution export --name $SolutionName --managed --path $zipPath
} else {
  pac solution export --name $SolutionName --path $zipPath
}

# 2) Unpack to TMP first (NOT to src)
Info "Unpacking solution -> $tmpPath"
New-Item -ItemType Directory -Force -Path $tmpPath | Out-Null
pac solution unpack --zipFile $zipPath --folder $tmpPath --allowDelete true

# Helpers
function Get-SolutionXmlPath([string]$baseFolder) {
  $candidates = Get-ChildItem -Path $baseFolder -Filter "Solution.xml" -Recurse -File -ErrorAction SilentlyContinue
  if ($candidates.Count -eq 0) { Fail "Solution.xml not found after unpack." }
  return ($candidates | Select-Object -First 1).FullName
}
function Bump-SemVer {
  param([string]$version, [string]$bump, [string]$prerelease)
  $base = $version.Split("-")[0]
  $parts = $base.Split(".")
  [int]$maj = $parts[0]; [int]$min = $parts[1]; [int]$pat = $parts[2]
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

# Read version from TMP (aktualny eksport)
$tmpSolutionXml = Get-SolutionXmlPath $tmpPath
[xml]$tmpXml = Get-Content -LiteralPath $tmpSolutionXml
$tmpVersionNode = $tmpXml.SelectSingleNode("//SolutionManifest/Version")
if (-not $tmpVersionNode) { $tmpVersionNode = $tmpXml.SelectSingleNode("//Version") }
if (-not $tmpVersionNode) { Fail "Version node not found in TMP Solution.xml ($tmpSolutionXml)." }
$exportedVersion = $tmpVersionNode.InnerText.Trim()

# ——————————————————————————————————————————————————
# DIFF: porównaj katalogi TMP vs SRC bez modyfikowania SRC
# ——————————————————————————————————————————————————

# Zbierz pełną listę różnic (ścieżki relatywne) – używamy git --no-index
# jeżeli SRC nie istnieje (pierwszy raz) — traktuj jak różne
$diffList = @()
if (Test-Path $srcPath) {
  $diffList = & git -c core.autocrlf=false -c core.safecrlf=false diff --no-index --name-only -- $srcPath $tmpPath 2>$null
} else {
  $diffList = @("**/*")
}

# Filtry „szumu” (Canvas itp.) – całe pliki, nie linie
$NoisePatterns = @(
  '\.msapp$',
  '_BackgroundImageUri$',
  '_AdditionalUris$',
  '_identity\.json$'
)

# Odfiltruj szum
$realDiff = @()
foreach ($f in $diffList) {
  $rel = $f
  $rel = $rel -replace [regex]::Escape((Get-Location).Path), ''
  $rel = $rel.TrimStart('\','/')
  $isNoise = $false
  foreach ($pat in $NoisePatterns) { if ($rel -imatch $pat) { $isNoise = $true; break } }
  if (-not $isNoise) { $realDiff += $rel }
}

# JEŚLI NIE MA RÓŻNIC → nie dotykamy SRC, sprzątamy i kończymy
if (-not $realDiff -or $realDiff.Count -eq 0) {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force }
  Ok "No real differences between src and latest export (noise ignored). Nothing committed."
  exit 0
}

# 3) Auto/explicit version bump – bumpujemy w TMP (bo za chwilę TMP wlejemy do SRC)
# Jeśli są realne różnice i nie podano -VersionBump → automatycznie podbij PATCH
if ($VersionBump -eq "none" -and $realDiff -and $realDiff.Count -gt 0) {
  $VersionBump = "patch"
}

$newVersion = $exportedVersion
if ($VersionBump -ne "none") {
  $newVersion = Bump-SemVer -version $exportedVersion -bump $VersionBump -prerelease $Prerelease
  if ($newVersion -ne $exportedVersion) {
    Info "Bumping version: $exportedVersion -> $newVersion"
    $tmpVersionNode.InnerText = $newVersion
    $tmpXml.Save($tmpSolutionXml)
  } else {
    Info "Version unchanged ($exportedVersion)."
  }
}

# 4) Skoro są różnice – podmień SRC zawartością TMP
Info "Sync TMP -> SRC"
robocopy $tmpPath $srcPath /MIR /NFL /NDL /NJH /NJS | Out-Null

# 5) Sprzątanie ZIP & TMP
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force }

# 6) Stage + commit
Info "Staging changed files..."
git add -A

$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
$commitMsg = "$Message (version: $newVersion, $ts)"
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

Ok "Done. Solution exported, diff-checked, (optionally) versioned and pushed."
