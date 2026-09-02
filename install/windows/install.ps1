#Requires -Version 5.1
<#
.SYNOPSIS
  NMS Server Windows installer

.DESCRIPTION
  Builds this repository's custom EQEmu-based server, imports the bundled
  database, installs quests/plugins, downloads maps + Spire, and writes a
  ready-to-run server folder (Spire-compatible layout).

  Inspired by Akkadius / EQEmu Spire installers, adapted for the NMS release.

.EXAMPLE
  # From an elevated PowerShell prompt at the repo root:
  .\install\windows\install.ps1

.EXAMPLE
  .\install\windows\install.ps1 -NonInteractive -DbPassword 'secret' -SpirePassword 'admin'
#>

[CmdletBinding()]
param(
  [string]$InstallDir = $(Join-Path $env:USERPROFILE "nms-server"),
  [string]$ShortName = "NMS",
  [string]$LongName = "NMS Community Release",
  [string]$DbHost = "127.0.0.1",
  [string]$DbPort = "3306",
  [string]$DbName = "nms",
  [string]$DbUser = "nms",
  [string]$DbPassword = "",
  [string]$DbRootPassword = "",
  [string]$SpireUser = "admin",
  [string]$SpirePassword = "",
  [int]$SpirePort = 3000,
  [string]$PublicAddress = "127.0.0.1",
  [string]$LocalAddress = "127.0.0.1",
  [switch]$SkipDeps,
  [switch]$SkipBuild,
  [switch]$SkipMaps,
  [switch]$SkipDbImport,
  [switch]$UseExistingMysql,
  [switch]$NonInteractive,
  [int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$CommonDir = (Resolve-Path (Join-Path $ScriptDir "..\common")).Path
$SourceDir = Join-Path $RepoRoot "Release-NMS-Server"
$QuestsSrc = Join-Path $RepoRoot "Release-NMS-Quests"
$PluginsSrc = Join-Path $RepoRoot "Release-NMS-Plugins"
$MapsUrl = "https://github.com/EQEmu/maps/releases/latest/download/maps.zip"

function Write-Step($msg) { Write-Host "› $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host "✗ $msg" -ForegroundColor Red; exit 1 }

function New-RandomPassword {
  $bytes = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return ([Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', '').Substring(0, 20)
}

function Read-Value([string]$Label, [string]$Default, [switch]$Secret) {
  if ($NonInteractive) { return $Default }
  if ($Secret) {
    $secure = Read-Host "$Label [$Default]" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { return $Default }
    return $plain
  }
  $value = Read-Host "$Label [$Default]"
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value
}

function Confirm-Yes([string]$Label, [bool]$DefaultYes = $true) {
  if ($NonInteractive) { return $DefaultYes }
  $def = if ($DefaultYes) { "Y" } else { "N" }
  $answer = Read-Host "$Label [$def]"
  if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $def }
  return $answer -match '^[Yy]'
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-RepoLayout {
  if (-not (Test-Path (Join-Path $SourceDir "CMakeLists.txt"))) { Die "Missing $SourceDir" }
  if (-not (Test-Path (Join-Path $SourceDir "database\release-peq.zip"))) { Die "Missing database\release-peq.zip" }
  if (-not (Test-Path $QuestsSrc)) { Die "Missing $QuestsSrc" }
  if (-not (Test-Path $PluginsSrc)) { Die "Missing $PluginsSrc" }
}

function Get-MysqlExe {
  $candidates = @(
    "mysql",
    (Join-Path ${env:ProgramFiles} "MariaDB 11.4\bin\mysql.exe"),
    (Join-Path ${env:ProgramFiles} "MariaDB 11.3\bin\mysql.exe"),
    (Join-Path ${env:ProgramFiles} "MariaDB 10.11\bin\mysql.exe"),
    (Join-Path ${env:ProgramFiles} "MariaDB 10.6\bin\mysql.exe"),
    (Join-Path ${env:ProgramFiles} "MySQL\MySQL Server 8.0\bin\mysql.exe")
  )
  foreach ($c in $candidates) {
    if ($c -eq "mysql") {
      $cmd = Get-Command mysql -ErrorAction SilentlyContinue
      if ($cmd) { return $cmd.Source }
    } elseif (Test-Path $c) {
      return $c
    }
  }
  return $null
}

function Install-Deps {
  if ($SkipDeps) {
    Write-WarnMsg "Skipping dependency installation"
    return
  }
  if (-not (Test-IsAdmin)) {
    Write-WarnMsg "Not elevated — cannot auto-install MariaDB/Perl. Re-run as Administrator or pass -SkipDeps after installing them yourself."
    return
  }

  Write-Step "Installing runtime dependencies via winget when available"

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    if (-not $UseExistingMysql) {
      winget install --id MariaDB.Server -e --accept-package-agreements --accept-source-agreements | Out-Host
    }
    if (-not (Test-Path "C:\Strawberry\perl\bin\perl.exe")) {
      winget install --id StrawberryPerl.StrawberryPerl -e --accept-package-agreements --accept-source-agreements | Out-Host
    }
  } else {
    Write-WarnMsg "winget not found. Install MariaDB 10.6+ and Strawberry Perl manually, then re-run with -SkipDeps -UseExistingMysql"
  }

  # Refresh PATH for this session
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Invoke-Mysql {
  param(
    [string]$User,
    [string]$Password,
    [string]$Database = "",
    [Parameter(ValueFromPipeline)][string]$Sql,
    [string]$InputFile = "",
    [switch]$AllowFailure
  )
  $mysql = Get-MysqlExe
  if (-not $mysql) { Die "mysql client not found on PATH / under Program Files" }

  $args = @("-u$user", "-h$DbHost", "-P$DbPort")
  if ($Password) { $args += "-p$Password" }
  if ($Database) { $args += $Database }

  if ($InputFile) {
    Get-Content -Raw $InputFile | & $mysql @args
  } else {
    $Sql | & $mysql @args
  }
  if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
    Die "mysql command failed (exit $LASTEXITCODE)"
  }
}

function Configure-Database {
  Write-Step "Configuring database $DbName"
  $mysql = Get-MysqlExe
  if (-not $mysql) { Die "mysql client not found. Install MariaDB and re-run." }

  $rootPass = $DbRootPassword
  # Probe root
  $probeArgs = @("-uroot", "-h$DbHost", "-P$DbPort", "-e", "SELECT 1")
  if ($rootPass) { $probeArgs = @("-uroot", "-p$rootPass", "-h$DbHost", "-P$DbPort", "-e", "SELECT 1") }
  & $mysql @probeArgs 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Die "Cannot connect as MySQL root. Set -DbRootPassword or use HeidiSQL/MariaDB to create the database manually."
  }

  $bootstrap = @"
CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
"@
  Invoke-Mysql -User "root" -Password $rootPass -Sql $bootstrap
  # Best-effort user create across MariaDB/MySQL versions
  Invoke-Mysql -User "root" -Password $rootPass -Sql "CREATE USER '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';" -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql "CREATE USER '$DbUser'@'%' IDENTIFIED BY '$DbPassword';" -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql "ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';" -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql "ALTER USER '$DbUser'@'%' IDENTIFIED BY '$DbPassword';" -AllowFailure
  $grants = @"
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'%';
FLUSH PRIVILEGES;
"@
  Invoke-Mysql -User "root" -Password $rootPass -Sql $grants

  if ($SkipDbImport) {
    Write-WarnMsg "Skipping database import"
    return
  }

  $countSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DbName';"
  $countOut = & $mysql "-u$DbUser" "-p$DbPassword" "-h$DbHost" "-P$DbPort" "-N" "-e" $countSql
  $tableCount = 0
  if ($countOut) { [int]::TryParse(($countOut | Select-Object -First 1), [ref]$tableCount) | Out-Null }
  if ($tableCount -gt 100) {
    Write-WarnMsg "Database already has $tableCount tables — skipping import"
    return
  }

  $tmp = Join-Path $env:TEMP ("nms-db-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    Write-Step "Unpacking release-peq.zip"
    Expand-Archive -Path (Join-Path $SourceDir "database\release-peq.zip") -DestinationPath $tmp -Force
    $sqlFile = Get-ChildItem -Path $tmp -Filter *.sql -Recurse | Select-Object -First 1
    if (-not $sqlFile) { Die "No .sql found inside release-peq.zip" }
    Write-Step "Importing $($sqlFile.Name) (this can take several minutes)"
    $argList = @("-u$DbUser", "-p$DbPassword", "-h$DbHost", "-P$DbPort", $DbName)
    # Stream the dump via cmd redirection so we do not load ~500 MB into PowerShell memory.
    $argString = ($argList | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    cmd.exe /c "`"$mysql`" $argString < `"$($sqlFile.FullName)`""
    if ($LASTEXITCODE -ne 0) { Die "Database import failed" }
    Write-Ok "Database imported"
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

function Find-CMake {
  $cmd = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($vsPath) {
      $try = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
      if (Test-Path $try) { return $try }
    }
  }
  return $null
}

function Build-Server {
  if ($SkipBuild) {
    Write-WarnMsg "Skipping build"
    $world = Join-Path $SourceDir "Build\bin\Release\world.exe"
    if (-not (Test-Path $world)) { Die "Missing $world" }
    return
  }

  Write-Step "Building server with CMake / Visual Studio"
  $cmake = Find-CMake
  if (-not $cmake) {
    Die "CMake not found. Install Visual Studio 2022 with the 'Desktop development with C++' workload."
  }

  Push-Location $SourceDir
  try {
    & $cmake -S . -B Build -G "Visual Studio 17 2022" -A x64 -DEQEMU_BUILD_LOGIN=ON
    if ($LASTEXITCODE -ne 0) { Die "CMake configure failed" }
    & $cmake --build Build --config Release --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { Die "CMake build failed" }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path (Join-Path $SourceDir "Build\bin\Release\world.exe"))) {
    Die "Build finished but world.exe is missing"
  }
  Write-Ok "Server built"
}

function New-RuntimeLayout {
  Write-Step "Creating runtime directory $InstallDir"
  @(
    "bin", "logs", "shared", "maps", "quests", "export", "import", "backups",
    "assets\opcodes", "assets\patches", "plugins"
  ) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $_) | Out-Null
  }
}

function Install-Binaries {
  Write-Step "Installing binaries into $InstallDir\bin"
  $srcBin = Join-Path $SourceDir "Build\bin\Release"
  $names = @(
    "world", "zone", "ucs", "queryserv", "loginserver",
    "shared_memory", "eqlaunch", "export_client_files", "import_client_files"
  )
  foreach ($name in $names) {
    $src = Join-Path $srcBin ($name + ".exe")
    if (Test-Path $src) {
      Copy-Item $src (Join-Path $InstallDir "bin\$name.exe") -Force
    } else {
      Write-WarnMsg "Optional binary not found: $name.exe"
    }
  }
}

function Copy-Tree([string]$From, [string]$To, [string[]]$Exclude = @(".git", "README.md", "LICENSE")) {
  New-Item -ItemType Directory -Force -Path $To | Out-Null
  Get-ChildItem -Path $From -Force | Where-Object {
    $Exclude -notcontains $_.Name
  } | ForEach-Object {
    $dest = Join-Path $To $_.Name
    if ($_.PSIsContainer) {
      Copy-Item $_.FullName $dest -Recurse -Force
    } else {
      Copy-Item $_.FullName $dest -Force
    }
  }
}

function Install-QuestsAndPlugins {
  Write-Step "Installing quests and plugins"
  if (Test-Path (Join-Path $InstallDir "quests")) {
    Remove-Item (Join-Path $InstallDir "quests\*") -Recurse -Force -ErrorAction SilentlyContinue
  }
  Copy-Tree $QuestsSrc (Join-Path $InstallDir "quests")
  $pluginsDest = Join-Path $InstallDir "quests\plugins"
  New-Item -ItemType Directory -Force -Path $pluginsDest | Out-Null
  Copy-Tree $PluginsSrc $pluginsDest
  Copy-Tree $pluginsDest (Join-Path $InstallDir "plugins")
}

function Install-Assets {
  Write-Step "Installing opcodes and patch files"
  $patchSrc = Join-Path $SourceDir "utils\patches"
  Copy-Item (Join-Path $patchSrc "*.conf") (Join-Path $InstallDir "assets\patches\") -Force
  Copy-Item (Join-Path $patchSrc "opcodes.conf") (Join-Path $InstallDir "assets\opcodes\") -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $patchSrc "mail_opcodes.conf") (Join-Path $InstallDir "assets\opcodes\") -Force -ErrorAction SilentlyContinue
  $loginUtil = Join-Path $SourceDir "loginserver\login_util"
  Copy-Item (Join-Path $loginUtil "login_opcodes.conf") (Join-Path $InstallDir "assets\opcodes\") -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $loginUtil "login_opcodes_sod.conf") (Join-Path $InstallDir "assets\opcodes\") -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $InstallDir "assets\opcodes\login_opcodes.conf") $InstallDir -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $InstallDir "assets\opcodes\login_opcodes_sod.conf") $InstallDir -Force -ErrorAction SilentlyContinue
}

function Expand-Template([string]$Src, [string]$Dst, [hashtable]$Map) {
  $content = Get-Content -Raw $Src
  foreach ($key in $Map.Keys) {
    $content = $content.Replace("{{$key}}", [string]$Map[$key])
  }
  Set-Content -Path $Dst -Value $content -Encoding UTF8
}

function Write-Configs([string]$WorldKey) {
  Write-Step "Writing eqemu_config.json and login.json"
  $map = @{
    DB_HOST         = $DbHost
    DB_PORT         = $DbPort
    DB_NAME         = $DbName
    DB_USER         = $DbUser
    DB_PASSWORD     = $DbPassword
    WORLD_KEY       = $WorldKey
    SHORT_NAME      = $ShortName
    LONG_NAME       = $LongName
    PUBLIC_ADDRESS  = $PublicAddress
    LOCAL_ADDRESS   = $LocalAddress
    CODE_PATH       = ($SourceDir -replace '\\', '/')
    SPIRE_PORT      = $SpirePort
  }
  Expand-Template (Join-Path $CommonDir "eqemu_config.json.template") (Join-Path $InstallDir "eqemu_config.json") $map
  Expand-Template (Join-Path $CommonDir "login.json.template") (Join-Path $InstallDir "login.json") $map
}

function Download-Maps {
  if ($SkipMaps) {
    Write-WarnMsg "Skipping maps download"
    return
  }
  if (Test-Path (Join-Path $InstallDir "maps\package.json")) {
    Write-WarnMsg "Maps already present — skipping download"
    return
  }
  Write-Step "Downloading maps (~1 GB) from $MapsUrl"
  $zip = Join-Path $env:TEMP "nms-maps.zip"
  Invoke-WebRequest -Uri $MapsUrl -OutFile $zip
  Write-Step "Extracting maps"
  Expand-Archive -Path $zip -DestinationPath (Join-Path $InstallDir "maps") -Force
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Write-Ok "Maps installed"
}

function Download-Spire {
  Write-Step "Downloading latest Spire release"
  $release = Invoke-RestMethod "https://api.github.com/repos/EQEmu/spire/releases/latest"
  $asset = $release.assets | Where-Object { $_.name -eq "spire-windows-amd64.exe.zip" } | Select-Object -First 1
  if (-not $asset) { Die "Could not find spire-windows-amd64.exe.zip on Spire releases" }
  $tmp = Join-Path $env:TEMP ("spire-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp "spire.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $bin = Get-ChildItem $tmp -Filter "spire-windows-amd64.exe" -Recurse | Select-Object -First 1
    if (-not $bin) { Die "Spire binary missing from release zip" }
    Copy-Item $bin.FullName (Join-Path $InstallDir "spire.exe") -Force
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
  Write-Ok "Spire installed to $InstallDir\spire.exe"
}

function Initialize-Spire {
  Write-Step "Initializing Spire admin user ($SpireUser)"
  Push-Location $InstallDir
  try {
    & .\spire.exe spire:init $SpireUser $SpirePassword --compile-server=true "--compile-build-location=$(Join-Path $SourceDir 'Build')"
  } catch {
    Write-WarnMsg "spire:init returned an error (may already be initialized): $_"
  } finally {
    Pop-Location
  }
}

function Write-HelperScripts {
  Write-Step "Writing helper scripts"
  @"
@echo off
cd /d "%~dp0"
spire.exe eqemu-server:launcher start
echo Server is starting
timeout /T 3 /NOBREAK > nul
"@ | Set-Content (Join-Path $InstallDir "server_start.bat") -Encoding ASCII

  @"
@echo off
cd /d "%~dp0"
spire.exe eqemu-server:launcher stop
echo Server is stopping
timeout /T 3 /NOBREAK > nul
"@ | Set-Content (Join-Path $InstallDir "server_stop.bat") -Encoding ASCII

  @"
@echo off
cd /d "%~dp0"
spire.exe eqemu-server:launcher restart
echo Server is restarting
timeout /T 3 /NOBREAK > nul
"@ | Set-Content (Join-Path $InstallDir "server_restart.bat") -Encoding ASCII

  @"
@echo off
cd /d "%~dp0"
TASKKILL /IM spire.exe /F >nul 2>&1
if not exist logs mkdir logs
start "NMS Spire" /min spire.exe
echo Spire starting on http://127.0.0.1:$SpirePort
"@ | Set-Content (Join-Path $InstallDir "spire_start.bat") -Encoding ASCII

  @"
@echo off
TASKKILL /IM spire.exe /F
echo Spire stopped
"@ | Set-Content (Join-Path $InstallDir "spire_stop.bat") -Encoding ASCII

  @"
@echo off
start http://127.0.0.1:$SpirePort
"@ | Set-Content (Join-Path $InstallDir "spire_web.bat") -Encoding ASCII

  @"
@echo off
start http://127.0.0.1:$SpirePort/admin
"@ | Set-Content (Join-Path $InstallDir "spire_web_admin.bat") -Encoding ASCII
}

function Write-InstallConfig([string]$WorldKey) {
  $yaml = @"
# Generated by NMS install/windows/install.ps1 — keep this private.
server_path: "$InstallDir"
code_path: "$SourceDir"
mysql_host: "$DbHost"
mysql_port: "$DbPort"
mysql_database_name: "$DbName"
mysql_username: "$DbUser"
mysql_password: "$DbPassword"
mysql_root_password: "$DbRootPassword"
spire_admin_user: "$SpireUser"
spire_admin_password: "$SpirePassword"
spire_web_port: "$SpirePort"
short_name: "$ShortName"
long_name: "$LongName"
public_address: "$PublicAddress"
local_address: "$LocalAddress"
world_key: "$WorldKey"
"@
  $path = Join-Path $InstallDir "install_config.yaml"
  Set-Content -Path $path -Value $yaml -Encoding UTF8
}

function Show-Banner {
  Write-Host @"

--------------------------------------------------------------------------------
|  NMS Server Windows Installer                                                |
|  Builds this release + installs Spire for admin / content editing            |
--------------------------------------------------------------------------------
Source:   $SourceDir
Install:  $InstallDir

"@ -ForegroundColor Cyan
}

function Show-Finish {
  Write-Host @"

Install complete.

Runtime folder:  $InstallDir
Credentials:     $InstallDir\install_config.yaml

1) Double-click spire_start.bat
2) Open spire_web_admin.bat  (http://127.0.0.1:$SpirePort/admin)
3) Start the server from Spire, or run server_start.bat

Client:
  - Point eqhost.txt at your loginserver (RoF2 uses port 5999)
  - Copy Release-NMS-Client\ClientFiles over your RoF2 client
  - Run bin\export_client_files.exe and copy the generated client data files

GM after first login:
  UPDATE account SET status = 250 WHERE name = 'yourlogin';

"@ -ForegroundColor Green
}

# ---------------- main ----------------
Require-RepoLayout
Show-Banner

if (-not $NonInteractive) {
  if (-not (Confirm-Yes "Continue with installation?" $true)) { Die "Aborted" }
}

$InstallDir = Read-Value "Server install directory" $InstallDir
$ShortName = Read-Value "Server short name" $ShortName
$LongName = Read-Value "Server long name" $LongName
$PublicAddress = Read-Value "Public address (WAN/LAN IP clients use)" $PublicAddress
$LocalAddress = Read-Value "Local address" $LocalAddress
$DbName = (Read-Value "Database name" $DbName).ToLower() -replace '[^a-z0-9_]', ''
$DbUser = Read-Value "Database username" $DbUser
if (-not $DbPassword) { $DbPassword = New-RandomPassword }
$DbPassword = Read-Value "Database password" $DbPassword -Secret
if (-not $UseExistingMysql) {
  if (Confirm-Yes "Attempt to install/configure local MariaDB?" $true) {
    if (-not $DbRootPassword) { $DbRootPassword = New-RandomPassword }
    $DbRootPassword = Read-Value "MariaDB root password" $DbRootPassword -Secret
  } else {
    $UseExistingMysql = $true
  }
}
if (-not $SpirePassword) { $SpirePassword = New-RandomPassword }
$SpireUser = Read-Value "Spire admin username" $SpireUser
$SpirePassword = Read-Value "Spire admin password" $SpirePassword -Secret
$SpirePort = [int](Read-Value "Spire HTTP port" "$SpirePort")
if (-not $SkipMaps) {
  if (-not (Confirm-Yes "Download EQEmu maps pack (~1 GB)?" $true)) { $SkipMaps = $true }
}

$WorldKey = (New-RandomPassword) + (New-RandomPassword)

Install-Deps
Configure-Database
Build-Server
New-RuntimeLayout
Install-Binaries
Install-QuestsAndPlugins
Install-Assets
Write-Configs -WorldKey $WorldKey
Download-Maps
Download-Spire
Write-HelperScripts
Write-InstallConfig -WorldKey $WorldKey
Initialize-Spire
Show-Finish
