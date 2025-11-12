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

# --- ALWAYS-CLEANUP FLAGS ---
$__cleanup_zip = $false
$__cleanup_tmp = $false

try {
  # Ensure clean TMP at start
  if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force }
  $__cleanup_tmp = $true

  # 1) Export solution
  Info "Exporting solution '$SolutionName' (managed: $($Managed.IsPresent)) -> $zipPath"
  if ($Managed) {
    pac solution export --name $SolutionName --managed --path $zipPath
  } else {
    pac solution export --name $SolutionName --path $zipPath
  }
  $__cleanup_zip = $true

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

  # >>> 4-segment Dataverse versioning (major.minor.build.revision); bump PATCH=last segment
  function Bump-SemVer {
    param([string]$version, [string]$bump, [string]$prerelease)
    $base = $version.Split("-")[0]
    $parts = ($base.Split(".") | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    $maj = $parts[0]; $min = $parts[1]; $bld = $parts[2]; $rev = $parts[3]
    switch ($bump) {
      "major" { $maj++; $min=0; $bld=0; $rev=0 }
      "minor" { $min++; $bld=0; $rev=0 }
      "patch" { $rev++ }
      default  { }
    }
    $new = "$maj.$min.$bld.$rev"
    if ($prerelease) { $new = "$new-$prerelease" }
    return $new
  }
  # <<<

  # Portable relative-path helper
  function Get-RelativePath([string]$baseFolder, [string]$fullPath) {
    $baseAbs = (Resolve-Path $baseFolder).ProviderPath
    $fullAbs = (Resolve-Path $fullPath).ProviderPath
    if (-not $baseAbs.EndsWith('\')) { $baseAbs += '\' }
    $baseUri = [Uri]$baseAbs
    $fullUri = [Uri]$fullAbs
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace('/', '\')
  }

  # Read version from TMP (fresh export)
  $tmpSolutionXml = Get-SolutionXmlPath $tmpPath
  [xml]$tmpXml = Get-Content -LiteralPath $tmpSolutionXml
  $tmpVersionNode = $tmpXml.SelectSingleNode("//SolutionManifest/Version")
  if (-not $tmpVersionNode) { $tmpVersionNode = $tmpXml.SelectSingleNode("//Version") }
  if (-not $tmpVersionNode) { Fail "Version node not found in TMP Solution.xml ($tmpSolutionXml)." }
  $exportedVersion = $tmpVersionNode.InnerText.Trim()

  # --------------------------------------------------------------------
  # ROBUST DIFF: compare file SETS and SHA-256 hashes (noise filtered)
  # --------------------------------------------------------------------
  $noiseRegex = [regex]'(\.msapp$|_BackgroundImageUri$|_AdditionalUris$|_identity\.json$)'

  function Build-FileMap([string]$baseFolder) {
    if (-not (Test-Path $baseFolder)) { return @{} }
    $files = Get-ChildItem -Path $baseFolder -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { -not $noiseRegex.IsMatch($_.FullName) }
    $map = @{}
    foreach ($f in $files) {
      $rel = Get-RelativePath -baseFolder $baseFolder -fullPath $f.FullName
      $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
      $map[$rel] = $hash
    }
    return $map
  }

  $srcMap = Build-FileMap $srcPath
  $tmpMap = Build-FileMap $tmpPath

  $added   = @($tmpMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) })
  $removed = @($srcMap.Keys | Where-Object { -not $tmpMap.ContainsKey($_) })
  $changed = @($tmpMap.Keys | Where-Object { $srcMap.ContainsKey($_) -and $tmpMap[$_] -ne $srcMap[$_] })

  $hasRealDiff = ($added.Count -or $removed.Count -or $changed.Count)

  if (-not $hasRealDiff) {
    Ok "No real differences between src and latest export (noise ignored). Nothing committed."
    return
  }

  # 3) Auto/explicit version bump – bump in TMP (because TMP will be mirrored to SRC)
  if ($VersionBump -eq "none") { $VersionBump = "patch" }  # auto-bump patch only when real diff exists

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

  # 4) Mirror TMP -> SRC (robocopy: codes 0–7 = success)
  Info "Sync TMP -> SRC"
  & robocopy $tmpPath $srcPath /MIR /NFL /NDL /NJH /NJS | Out-Null
  $rc = $LASTEXITCODE
  if ($rc -gt 7) { Fail "Robocopy failed with exit code $rc." }

  # 5) Stage + commit
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

  Ok "Done. Solution exported, diff-checked (hash-based), versioned and pushed."
}
finally {
  # --- ALWAYS CLEANUP ---
  if ($__cleanup_zip -and (Test-Path $zipPath)) {
    try { Remove-Item $zipPath -Force } catch {}
  }
  if ($__cleanup_tmp -and (Test-Path $tmpPath)) {
    try { Remove-Item $tmpPath -Recurse -Force } catch {}
  }
}
