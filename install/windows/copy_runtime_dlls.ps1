# Copy DLLs that world.exe / zone.exe need into the runtime bin folder.
# 0xc0000135 means Windows could not find one of these libraries.
# InstallerRevision 20260903-12

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) {
  if ($env:NMS_REPO_ROOT) {
    $RepoRoot = $env:NMS_REPO_ROOT
  } else {
    $RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
  }
}
if (-not $InstallDir) {
  $InstallDir = Join-Path $env:USERPROFILE "nms-server"
}
$SourceDir = Join-Path $RepoRoot "Release-NMS-Server"
$DestBin = Join-Path $InstallDir "bin"

if (-not (Test-Path $DestBin)) {
  Write-Host ("ERR Missing runtime bin folder: " + $DestBin) -ForegroundColor Red
  exit 1
}

function Copy-DllsFromDir {
  param([string]$From)
  $copied = 0
  if (-not (Test-Path $From)) {
    return 0
  }
  $files = @(Get-ChildItem -Path $From -Filter "*.dll" -File -ErrorAction SilentlyContinue)
  foreach ($file in $files) {
    Copy-Item $file.FullName (Join-Path $DestBin $file.Name) -Force
    $copied += 1
  }
  if ($copied -gt 0) {
    Write-Host ("OK  " + $copied + " DLL(s) from " + $From) -ForegroundColor Green
  }
  return $copied
}

Write-Host ("> Copying runtime DLLs into " + $DestBin) -ForegroundColor Cyan
$total = 0

$buildBins = @(
  (Join-Path $SourceDir "Build\bin\Release"),
  (Join-Path $SourceDir "Build\bin")
)
foreach ($dir in $buildBins) {
  $total += Copy-DllsFromDir -From $dir
}

$vcpkgDirs = @(
  (Join-Path $SourceDir "vcpkg\vcpkg-export-x64\installed\x64-windows\bin"),
  (Join-Path $SourceDir "vcpkg\vcpkg-export-x64\installed\x64-windows\tools"),
  (Join-Path $SourceDir "vcpkg\vcpkg-export-x64\installed\x64-windows\tools\openssl"),
  (Join-Path $SourceDir "vcpkg\vcpkg-export-x86\installed\x86-windows\bin")
)
foreach ($dir in $vcpkgDirs) {
  $total += Copy-DllsFromDir -From $dir
}

foreach ($arch in @("x64", "x86")) {
  $perlRoot = Join-Path $SourceDir ("perl\" + $arch)
  $total += Copy-DllsFromDir -From (Join-Path $perlRoot "perl\bin")
  $total += Copy-DllsFromDir -From (Join-Path $perlRoot "c\bin")
}

$mariaRoots = @()
if (${env:ProgramFiles}) { $mariaRoots += ${env:ProgramFiles} }
if (${env:ProgramFiles(x86)}) { $mariaRoots += ${env:ProgramFiles(x86)} }
foreach ($root in $mariaRoots) {
  $dirs = @(Get-ChildItem -Path $root -Directory -Filter "MariaDB*" -ErrorAction SilentlyContinue)
  foreach ($dir in $dirs) {
    $total += Copy-DllsFromDir -From (Join-Path $dir.FullName "lib")
    $total += Copy-DllsFromDir -From (Join-Path $dir.FullName "bin")
  }
}

Write-Host ("OK  Copied " + $total + " DLL(s) total") -ForegroundColor Green
if ($total -eq 0) {
  Write-Host "ERR No DLLs were found. Confirm the repo still has vcpkg\ and perl\ after the compile." -ForegroundColor Red
  exit 1
}

$needed = @("libsodium.dll", "libmariadb.dll", "lua51.dll", "zlib1.dll", "perl524.dll")
foreach ($name in $needed) {
  if (Test-Path (Join-Path $DestBin $name)) {
    Write-Host ("OK  " + $name) -ForegroundColor Green
  } else {
    Write-Host ("!   Missing " + $name + " (may still start if that library was linked statically)") -ForegroundColor Yellow
  }
}

Write-Host "Double-click bin\world.exe once. If a DLL is still missing, Windows will name it." -ForegroundColor Yellow
exit 0
