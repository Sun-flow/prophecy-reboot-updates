# The friend updater: brings this Prophecy-Online folder to the feed's version. The join window
# runs it (Update button, and before Join); it is the only code that installs updates.
#
#   Update-Prophecy.ps1 -Bundle <Prophecy-Online folder> -Url <update address>
#
# Exit code and last line: 0 "RESULT current", 3 "RESULT updated <version>", 2 "RESULT unreachable",
# 1 "RESULT failed <reason>". Design: docs/server/friend-updates.md.
#
# 1. Reads <url>/latest.json.
# 2. Updates itself first: if latest.json names an updater whose SHA-256 differs from this file,
#    it downloads that one, checks the hash, replaces this file and runs the new one in its place.
#    So the rules below (Test-UpdatePath) are always the feed's current rules, and a change to
#    them never needs a hand-made stepping stone again.
# 3. Downloads the payload zip, checks size and SHA-256, checks every entry with Test-UpdatePath,
#    backs up the files it replaces to update-backup\<old version>\ and unpacks.
param(
  [Parameter(Mandatory)][string]$Bundle,
  [Parameter(Mandatory)][string]$Url,
  [switch]$NoSelfUpdate   # set on the run that follows a self-update, so it can't loop
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows Invoke-WebRequest a lot
$Url = $Url.TrimEnd('/')
$verFile = Join-Path $Bundle 'version.txt'
# GitHub only speaks TLS 1.2+, which Windows PowerShell 5.1 doesn't enable by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Which files an update may write, relative to the bundle folder: the root text files and anything
# under Phoenix\Binaries\Win64 (scripts, data, icons, presets), except program files, which only
# tools\ may hold. Never friend.json, Phoenix.exe, the game's DLLs or the paks.
function Test-UpdatePath($rel) {
  if ($rel -match '\.\.|:|^\\') { return $false }
  if ($rel -in @('README.txt', 'UPDATE.txt', 'version.txt', 'friend-update.json')) { return $true }
  if ($rel -match '^Phoenix\\Binaries\\Win64\\tools\\[\w.-]+\.exe$') { return $true }
  if ($rel -match '\.(exe|dll|pdb|sys|bat|cmd|com|scr|msi|pak)$') { return $false }
  return $rel -match '^Phoenix\\Binaries\\Win64\\[\w .\\-]+$'
}

function Get-Sha256($path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }
function Get-Fresh($name, $out, $tag) {
  # The query string gets past the raw file cache (a few minutes) on GitHub.
  Invoke-WebRequest "$Url/$name`?v=$tag" -OutFile $out -TimeoutSec 60 -UseBasicParsing
}
function Done($code, $text) { "RESULT $text"; exit $code }

try {
  $latest = (Invoke-WebRequest "$Url/latest.json?t=$([DateTime]::UtcNow.Ticks)" -TimeoutSec 8 -UseBasicParsing).Content | ConvertFrom-Json
} catch { Done 2 'unreachable' }

try {
  # 2. The updater first.
  if ($latest.updater -and -not $NoSelfUpdate -and (Get-Sha256 $PSCommandPath) -ne ([string]$latest.updater.sha256).ToLower()) {
    'update: getting the new updater ...'
    $tmp = "$PSCommandPath.download"
    Get-Fresh $latest.updater.file $tmp $latest.version
    if ((Get-Sha256 $tmp) -ne ([string]$latest.updater.sha256).ToLower()) { Remove-Item $tmp -Force; throw 'the new updater did not download completely.' }
    Copy-Item $PSCommandPath "$PSCommandPath.old" -Force
    Move-Item $tmp $PSCommandPath -Force
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Bundle $Bundle -Url $Url -NoSelfUpdate
    exit $LASTEXITCODE
  }

  $old = if (Test-Path $verFile) { (Get-Content $verFile -TotalCount 1).Trim() } else { '' }
  if (-not $latest.version -or $latest.version -eq $old) { Done 0 'current' }

  # 3. The payload. A feed from before the updater has only update.zip.
  $pkg = if ($latest.payload) { $latest.payload } else { [pscustomobject]@{ zip = 'update.zip'; size = $latest.size; sha256 = $latest.sha256 } }
  "update: downloading version $($latest.version) ..."
  $tmp = Join-Path $env:TEMP "prophecy-update-$PID.zip"
  try {
    Get-Fresh $pkg.zip $tmp $latest.version
    if ((Get-Item $tmp).Length -ne [long]$pkg.size -or (Get-Sha256 $tmp) -ne ([string]$pkg.sha256).ToLower()) {
      throw 'the download was incomplete.'
    }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
    try {
      $files = @($zip.Entries | Where-Object { $_.Name } | ForEach-Object { @{ entry = $_; rel = $_.FullName -replace '/', '\' } })
      $bad = @($files | Where-Object { -not (Test-UpdatePath $_.rel) } | ForEach-Object { $_.rel })
      if ($bad) { throw "it holds files the updater may not change ($($bad -join ', '))." }
      $backup = Join-Path $Bundle ('update-backup\' + $(if ($old) { $old } else { 'unknown' }))
      foreach ($f in $files) {
        $dest = Join-Path $Bundle $f.rel
        if (Test-Path $dest) {
          New-Item -ItemType Directory -Force (Split-Path (Join-Path $backup $f.rel)) | Out-Null
          Copy-Item $dest (Join-Path $backup $f.rel) -Force
        }
      }
      foreach ($f in $files) {
        $dest = Join-Path $Bundle $f.rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($f.entry, $dest, $true)
      }
    } finally { $zip.Dispose() }
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  Done 3 "updated $($latest.version)"
} catch {
  Done 1 "failed $($_.Exception.Message)"
}
