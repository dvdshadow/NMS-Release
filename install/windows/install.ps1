# NMS Server Windows installer
# Double-click install.bat at the repo root.
# InstallerRevision 20260903-6

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:InstallerRevision = "20260903-6"

if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE "nms-server" }
if (-not $ShortName) { $ShortName = "NMS" }
if (-not $LongName) { $LongName = "NMS Community Release" }
if (-not $DbHost) { $DbHost = "127.0.0.1" }
if (-not $DbPort) { $DbPort = "3306" }
if (-not $DbName) { $DbName = "nms" }
if (-not $DbUser) { $DbUser = "nms" }
if (-not $DbPassword) { $DbPassword = "" }
if (-not $DbRootPassword) { $DbRootPassword = "" }
if (-not $SpireUser) { $SpireUser = "admin" }
if (-not $SpirePassword) { $SpirePassword = "" }
if (-not $SpirePort) { $SpirePort = 3000 }
if (-not $PublicAddress) { $PublicAddress = "127.0.0.1" }
if (-not $LocalAddress) { $LocalAddress = "127.0.0.1" }
if (-not $Jobs) { $Jobs = [Environment]::ProcessorCount }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$CommonDir = (Resolve-Path (Join-Path $ScriptDir "..\common")).Path
$SourceDir = Join-Path $RepoRoot "Release-NMS-Server"
$QuestsSrc = Join-Path $RepoRoot "Release-NMS-Quests"
$PluginsSrc = Join-Path $RepoRoot "Release-NMS-Plugins"
$MapsUrl = "https://github.com/EQEmu/maps/releases/latest/download/maps.zip"

function Write-Step([string]$Message) {
  Write-Host ("> " + $Message) -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host ("OK  " + $Message) -ForegroundColor Green
}

function Write-WarnMsg([string]$Message) {
  Write-Host ("!   " + $Message) -ForegroundColor Yellow
}

function Die([string]$Message) {
  Write-Host ("ERR " + $Message) -ForegroundColor Red
  exit 1
}

function New-RandomPassword {
  $bytes = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $raw = [Convert]::ToBase64String($bytes)
  $clean = $raw -replace "[^a-zA-Z0-9]", ""
  if ($clean.Length -lt 20) {
    return $clean
  }
  return $clean.Substring(0, 20)
}

function Read-Value {
  param(
    [string]$Label,
    [string]$Default,
    [switch]$Secret
  )
  if ($NonInteractive) {
    return $Default
  }
  if ($Secret) {
    $secure = Read-Host ($Label + " [" + $Default + "]") -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) {
      return $Default
    }
    return $plain
  }
  $value = Read-Host ($Label + " [" + $Default + "]")
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }
  return $value
}

function Confirm-Yes {
  param(
    [string]$Label,
    [bool]$DefaultYes = $true
  )
  if ($NonInteractive) {
    return $DefaultYes
  }
  if ($DefaultYes) {
    $def = "Y"
  } else {
    $def = "N"
  }
  $answer = Read-Host ($Label + " [" + $def + "]")
  if ([string]::IsNullOrWhiteSpace($answer)) {
    $answer = $def
  }
  return $answer -match "^[Yy]"
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-RepoLayout {
  if (-not (Test-Path (Join-Path $SourceDir "CMakeLists.txt"))) {
    Die ("Missing " + $SourceDir)
  }
  if (-not (Test-Path (Join-Path $SourceDir "database\release-peq.zip"))) {
    Die "Missing database\release-peq.zip"
  }
  if (-not (Test-Path $QuestsSrc)) {
    Die ("Missing " + $QuestsSrc)
  }
  if (-not (Test-Path $PluginsSrc)) {
    Die ("Missing " + $PluginsSrc)
  }
}

function Add-MysqlBinToPath {
  param([string]$MysqlExe)
  if (-not $MysqlExe) {
    return
  }
  $binDir = Split-Path -Parent $MysqlExe
  if ($env:Path -notlike ("*" + $binDir + "*")) {
    $env:Path = $binDir + ";" + $env:Path
  }
}

function Get-MysqlExe {
  $cmd = Get-Command mysql -ErrorAction SilentlyContinue
  if ($cmd) {
    Add-MysqlBinToPath $cmd.Source
    return $cmd.Source
  }
  $cmd = Get-Command mariadb -ErrorAction SilentlyContinue
  if ($cmd) {
    Add-MysqlBinToPath $cmd.Source
    return $cmd.Source
  }

  $roots = @()
  if (${env:ProgramFiles}) { $roots += ${env:ProgramFiles} }
  if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
  if (${env:ProgramW6432}) { $roots += ${env:ProgramW6432} }
  $roots = $roots | Select-Object -Unique

  foreach ($root in $roots) {
    $dirs = @()
    $dirs += Get-ChildItem -Path $root -Directory -Filter "MariaDB*" -ErrorAction SilentlyContinue
    $mysqlRoot = Join-Path $root "MySQL"
    if (Test-Path $mysqlRoot) {
      $dirs += Get-ChildItem -Path $mysqlRoot -Directory -Filter "MySQL Server*" -ErrorAction SilentlyContinue
    }
    foreach ($dir in $dirs) {
      foreach ($exeName in @("mysql.exe", "mariadb.exe")) {
        $exe = Join-Path $dir.FullName ("bin\" + $exeName)
        if (Test-Path $exe) {
          Add-MysqlBinToPath $exe
          return $exe
        }
      }
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
    Write-WarnMsg "Not elevated - cannot auto-install MariaDB/Perl. Re-run as Administrator or pass -SkipDeps after installing them yourself."
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

  $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = $machinePath + ";" + $userPath

  $mysqlExe = Get-MysqlExe
  if ($mysqlExe) {
    Write-Ok ("Found MariaDB/MySQL client: " + $mysqlExe)
  } else {
    Write-WarnMsg "MariaDB may be installed, but mysql.exe was not on PATH yet. The next step will search Program Files."
  }

  Start-DatabaseService
}

function Get-DatabaseServices {
  return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match "maria|mysql" -or $_.DisplayName -match "MariaDB|MySQL"
  })
}

function Test-MysqlPortOpen {
  param(
    [string]$TargetHost = "127.0.0.1",
    [int]$TargetPort = 3306
  )
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
    if (-not $ok) {
      $client.Close()
      return $false
    }
    $client.EndConnect($iar)
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Ensure-MariaDbWindowsInstance {
  $mysql = Get-MysqlExe
  if (-not $mysql) {
    return
  }
  $binDir = Split-Path -Parent $mysql
  $installRoot = Split-Path -Parent $binDir
  $dataDir = Join-Path $installRoot "data"
  $services = Get-DatabaseServices
  if ($services.Count -gt 0) {
    return
  }

  Write-Step "MariaDB files are installed, but no Windows service exists yet. Creating one."
  $installDb = Join-Path $binDir "mariadb-install-db.exe"
  if (-not (Test-Path $installDb)) {
    $installDb = Join-Path $binDir "mysql_install_db.exe"
  }
  $mysqld = Join-Path $binDir "mysqld.exe"
  if (-not (Test-Path $mysqld)) {
    $mysqld = Join-Path $binDir "mariadbd.exe"
  }

  $hasData = $false
  if (Test-Path $dataDir) {
    $hasData = (@(Get-ChildItem -Path $dataDir -ErrorAction SilentlyContinue).Count -gt 0)
  }

  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    if ((Test-Path $installDb) -and -not $hasData) {
      $installArgs = @(
        ("--datadir=" + $dataDir),
        "--service=MariaDB",
        ("--port=" + $DbPort)
      )
      if ($DbRootPassword) {
        $installArgs += ("--password=" + $DbRootPassword)
      }
      Write-Step ("Initializing MariaDB instance with " + (Split-Path -Leaf $installDb))
      & $installDb @installArgs | Out-Host
    } elseif (Test-Path $mysqld) {
      Write-Step "Registering existing MariaDB data directory as a Windows service"
      & $mysqld --install MariaDB | Out-Host
    } else {
      Write-WarnMsg "Could not find mariadb-install-db.exe or mysqld.exe next to mysql.exe."
    }
  } finally {
    $ErrorActionPreference = $old
  }
}

function Start-DatabaseService {
  Ensure-MariaDbWindowsInstance
  $services = Get-DatabaseServices
  if ($services.Count -eq 0) {
    Write-WarnMsg "No MariaDB/MySQL Windows service was found yet."
    return
  }
  foreach ($svc in $services) {
    if ($svc.Status -eq "Running") {
      Write-Ok ("Database service already running: " + $svc.Name)
      continue
    }
    Write-Step ("Starting database service " + $svc.Name)
    try {
      Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue
      Start-Service -Name $svc.Name -ErrorAction Stop
    } catch {
      Write-WarnMsg ("Start-Service failed for " + $svc.Name + ", trying net start")
      cmd.exe /c ("net start `"" + $svc.Name + "`"") | Out-Null
    }
  }
}

function Wait-DatabaseReady {
  param([int]$Seconds = 45)
  Write-Step ("Waiting up to " + $Seconds + " seconds for MariaDB to accept connections")
  $elapsed = 0
  while ($elapsed -lt $Seconds) {
    $svcRunning = @(Get-DatabaseServices | Where-Object { $_.Status -eq "Running" }).Count -gt 0
    if ((Test-MysqlPortOpen -TargetHost "127.0.0.1" -TargetPort ([int]$DbPort)) -or $svcRunning) {
      if (Test-MysqlPortOpen -TargetHost "127.0.0.1" -TargetPort ([int]$DbPort)) {
        Write-Ok ("MariaDB is listening on 127.0.0.1:" + $DbPort)
        return $true
      }
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
  }
  return $false
}

function Invoke-MysqlExe {
  param(
    [string]$MysqlExe,
    [string[]]$MysqlArgs
  )
  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $output = & $MysqlExe @MysqlArgs 2>&1
    $script:LastMysqlExit = $LASTEXITCODE
    return $output
  } finally {
    $ErrorActionPreference = $old
  }
}

function Invoke-Mysql {
  param(
    [string]$User,
    [string]$Password,
    [string]$Database = "",
    [string]$Sql = "",
    [switch]$AllowFailure
  )
  $mysql = Get-MysqlExe
  if (-not $mysql) {
    Die "mysql client not found on PATH / under Program Files"
  }

  $mysqlArgs = @("-u$User", "-h$DbHost", "-P$DbPort")
  if ($Password) {
    $mysqlArgs += "-p$Password"
  }
  if ($Database) {
    $mysqlArgs += $Database
  }
  if ($Sql) {
    $mysqlArgs += "-e"
    $mysqlArgs += $Sql
  }

  [void](Invoke-MysqlExe -MysqlExe $mysql -MysqlArgs $mysqlArgs)
  if ($script:LastMysqlExit -ne 0 -and -not $AllowFailure) {
    Die ("mysql command failed (exit " + $script:LastMysqlExit + ")")
  }
}

function Test-MysqlRootLogin {
  param(
    [string]$MysqlExe,
    [string]$Password
  )
  $attempts = @(
    @("-uroot", "-h127.0.0.1", "-P$DbPort", "-e", "SELECT 1"),
    @("-uroot", "-hlocalhost", "-P$DbPort", "-e", "SELECT 1"),
    @("-uroot", "-e", "SELECT 1")
  )
  if ($Password) {
    $attempts = @(
      @("-uroot", "-p$Password", "-h127.0.0.1", "-P$DbPort", "-e", "SELECT 1"),
      @("-uroot", "-p$Password", "-hlocalhost", "-P$DbPort", "-e", "SELECT 1"),
      @("-uroot", "-p$Password", "-e", "SELECT 1")
    ) + $attempts
  }
  foreach ($probeArgs in $attempts) {
    [void](Invoke-MysqlExe -MysqlExe $MysqlExe -MysqlArgs $probeArgs)
    if ($script:LastMysqlExit -eq 0) {
      return $true
    }
  }
  return $false
}

function Configure-Database {
  Write-Step ("Configuring database " + $DbName)
  $mysql = Get-MysqlExe
  if (-not $mysql) {
    Die "mysql client not found. Install MariaDB and re-run."
  }

  Start-DatabaseService
  if (-not (Wait-DatabaseReady -Seconds 45)) {
    Write-WarnMsg "MariaDB did not open port 3306 yet. Will still try to log in."
  }

  $rootPass = $DbRootPassword
  $loggedIn = $false
  $tries = 0
  while (-not $loggedIn -and $tries -lt 8) {
    $loggedIn = Test-MysqlRootLogin -MysqlExe $mysql -Password $rootPass
    if (-not $loggedIn) {
      Start-DatabaseService
      Start-Sleep -Seconds 3
      $tries += 1
    }
  }
  if (-not $loggedIn) {
    Die "Cannot connect to MariaDB on 127.0.0.1:3306. Open Services, start the MariaDB service, then re-run install.bat."
  }

  $bootstrap = "CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  Invoke-Mysql -User "root" -Password $rootPass -Sql $bootstrap
  Invoke-Mysql -User "root" -Password $rootPass -Sql ("CREATE USER '" + $DbUser + "'@'localhost' IDENTIFIED BY '" + $DbPassword + "';") -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql ("CREATE USER '" + $DbUser + "'@'%' IDENTIFIED BY '" + $DbPassword + "';") -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql ("ALTER USER '" + $DbUser + "'@'localhost' IDENTIFIED BY '" + $DbPassword + "';") -AllowFailure
  Invoke-Mysql -User "root" -Password $rootPass -Sql ("ALTER USER '" + $DbUser + "'@'%' IDENTIFIED BY '" + $DbPassword + "';") -AllowFailure
  $grants = @(
    ("GRANT ALL PRIVILEGES ON ``" + $DbName + "``.* TO '" + $DbUser + "'@'localhost';"),
    ("GRANT ALL PRIVILEGES ON ``" + $DbName + "``.* TO '" + $DbUser + "'@'%';"),
    "FLUSH PRIVILEGES;"
  ) -join " "
  Invoke-Mysql -User "root" -Password $rootPass -Sql $grants

  if ($SkipDbImport) {
    Write-WarnMsg "Skipping database import"
    return
  }

  $countSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DbName';"
  $countOut = Invoke-MysqlExe -MysqlExe $mysql -MysqlArgs @("-u$DbUser", "-p$DbPassword", "-h$DbHost", "-P$DbPort", "-N", "-e", $countSql)
  $tableCount = 0
  if ($countOut) {
    [void][int]::TryParse((($countOut | Select-Object -First 1).ToString()), [ref]$tableCount)
  }
  if ($tableCount -gt 100) {
    Write-WarnMsg ("Database already has " + $tableCount + " tables - skipping import")
    return
  }

  $tmp = Join-Path $env:TEMP ("nms-db-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    Write-Step "Unpacking release-peq.zip"
    Expand-Archive -Path (Join-Path $SourceDir "database\release-peq.zip") -DestinationPath $tmp -Force
    $sqlFile = Get-ChildItem -Path $tmp -Filter *.sql -Recurse | Select-Object -First 1
    if (-not $sqlFile) {
      Die "No .sql found inside release-peq.zip"
    }
    Write-Step ("Importing " + $sqlFile.Name + " (this can take several minutes)")
    $quotedMysql = '"' + $mysql + '"'
    $quotedSql = '"' + $sqlFile.FullName + '"'
    $cmdLine = $quotedMysql + " -u" + $DbUser + " -p" + $DbPassword + " -h" + $DbHost + " -P" + $DbPort + " " + $DbName + " < " + $quotedSql
    cmd.exe /c $cmdLine
    if ($LASTEXITCODE -ne 0) {
      Die "Database import failed"
    }
    Write-Ok "Database imported"
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

function Find-CMake {
  $cmd = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($vsPath) {
      $try = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
      if (Test-Path $try) {
        return $try
      }
    }
  }
  return $null
}

function Build-Server {
  if ($SkipBuild) {
    Write-WarnMsg "Skipping build"
    $world = Join-Path $SourceDir "Build\bin\Release\world.exe"
    if (-not (Test-Path $world)) {
      Die ("Missing " + $world)
    }
    return
  }

  Write-Step "Building server with CMake / Visual Studio"
  $cmake = Find-CMake
  if (-not $cmake) {
    Die "CMake not found. Install Visual Studio 2022 with the Desktop development with C++ workload."
  }

  Push-Location $SourceDir
  try {
    & $cmake -S . -B Build -G "Visual Studio 17 2022" -A x64 -DEQEMU_BUILD_LOGIN=ON
    if ($LASTEXITCODE -ne 0) {
      Die "CMake configure failed"
    }
    & $cmake --build Build --config Release --parallel $Jobs
    if ($LASTEXITCODE -ne 0) {
      Die "CMake build failed"
    }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path (Join-Path $SourceDir "Build\bin\Release\world.exe"))) {
    Die "Build finished but world.exe is missing"
  }
  Write-Ok "Server built"
}

function New-RuntimeLayout {
  Write-Step ("Creating runtime directory " + $InstallDir)
  $dirs = @(
    "bin",
    "logs",
    "shared",
    "maps",
    "quests",
    "export",
    "import",
    "backups",
    "assets\opcodes",
    "assets\patches",
    "plugins"
  )
  foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $dir) | Out-Null
  }
}

function Install-Binaries {
  Write-Step ("Installing binaries into " + (Join-Path $InstallDir "bin"))
  $srcBin = Join-Path $SourceDir "Build\bin\Release"
  $names = @(
    "world",
    "zone",
    "ucs",
    "queryserv",
    "loginserver",
    "shared_memory",
    "eqlaunch",
    "export_client_files",
    "import_client_files"
  )
  foreach ($name in $names) {
    $src = Join-Path $srcBin ($name + ".exe")
    if (Test-Path $src) {
      Copy-Item $src (Join-Path $InstallDir ("bin\" + $name + ".exe")) -Force
    } else {
      Write-WarnMsg ("Optional binary not found: " + $name + ".exe")
    }
  }
}

function Copy-Tree {
  param(
    [string]$From,
    [string]$To,
    [string[]]$Exclude = @(".git", "README.md", "LICENSE")
  )
  New-Item -ItemType Directory -Force -Path $To | Out-Null
  Get-ChildItem -Path $From -Force | Where-Object { $Exclude -notcontains $_.Name } | ForEach-Object {
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
  Copy-Tree -From $QuestsSrc -To (Join-Path $InstallDir "quests")
  $pluginsDest = Join-Path $InstallDir "quests\plugins"
  New-Item -ItemType Directory -Force -Path $pluginsDest | Out-Null
  Copy-Tree -From $PluginsSrc -To $pluginsDest
  Copy-Tree -From $pluginsDest -To (Join-Path $InstallDir "plugins")
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

function Expand-Template {
  param(
    [string]$Src,
    [string]$Dst,
    [hashtable]$Map
  )
  $content = Get-Content -Raw $Src
  foreach ($key in $Map.Keys) {
    $content = $content.Replace("{{" + $key + "}}", [string]$Map[$key])
  }
  Set-Content -Path $Dst -Value $content -Encoding ASCII
}

function Write-Configs {
  param([string]$WorldKey)
  Write-Step "Writing eqemu_config.json and login.json"
  $map = @{
    DB_HOST        = $DbHost
    DB_PORT        = $DbPort
    DB_NAME        = $DbName
    DB_USER        = $DbUser
    DB_PASSWORD    = $DbPassword
    WORLD_KEY      = $WorldKey
    SHORT_NAME     = $ShortName
    LONG_NAME      = $LongName
    PUBLIC_ADDRESS = $PublicAddress
    LOCAL_ADDRESS  = $LocalAddress
    CODE_PATH      = ($SourceDir -replace "\\", "/")
    SPIRE_PORT     = $SpirePort
  }
  Expand-Template -Src (Join-Path $CommonDir "eqemu_config.json.template") -Dst (Join-Path $InstallDir "eqemu_config.json") -Map $map
  Expand-Template -Src (Join-Path $CommonDir "login.json.template") -Dst (Join-Path $InstallDir "login.json") -Map $map
}

function Download-Maps {
  if ($SkipMaps) {
    Write-WarnMsg "Skipping maps download"
    return
  }
  if (Test-Path (Join-Path $InstallDir "maps\package.json")) {
    Write-WarnMsg "Maps already present - skipping download"
    return
  }
  Write-Step ("Downloading maps (~1 GB) from " + $MapsUrl)
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
  if (-not $asset) {
    Die "Could not find spire-windows-amd64.exe.zip on Spire releases"
  }
  $tmp = Join-Path $env:TEMP ("spire-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp "spire.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $bin = Get-ChildItem $tmp -Filter "spire-windows-amd64.exe" -Recurse | Select-Object -First 1
    if (-not $bin) {
      Die "Spire binary missing from release zip"
    }
    Copy-Item $bin.FullName (Join-Path $InstallDir "spire.exe") -Force
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
  Write-Ok ("Spire installed to " + (Join-Path $InstallDir "spire.exe"))
}

function Initialize-Spire {
  Write-Step ("Initializing Spire admin user (" + $SpireUser + ")")
  Push-Location $InstallDir
  try {
    $buildPath = Join-Path $SourceDir "Build"
    & .\spire.exe spire:init $SpireUser $SpirePassword --compile-server=true ("--compile-build-location=" + $buildPath)
  } catch {
    Write-WarnMsg ("spire:init returned an error (may already be initialized): " + $_)
  } finally {
    Pop-Location
  }
}

function Write-HelperScripts {
  Write-Step "Writing helper scripts"
  $start = @(
    "@echo off",
    "cd /d `"%~dp0`"",
    "spire.exe eqemu-server:launcher start",
    "echo Server is starting",
    "timeout /T 3 /NOBREAK > nul"
  )
  $stop = @(
    "@echo off",
    "cd /d `"%~dp0`"",
    "spire.exe eqemu-server:launcher stop",
    "echo Server is stopping",
    "timeout /T 3 /NOBREAK > nul"
  )
  $restart = @(
    "@echo off",
    "cd /d `"%~dp0`"",
    "spire.exe eqemu-server:launcher restart",
    "echo Server is restarting",
    "timeout /T 3 /NOBREAK > nul"
  )
  $spireStart = @(
    "@echo off",
    "cd /d `"%~dp0`"",
    "TASKKILL /IM spire.exe /F >nul 2>&1",
    "if not exist logs mkdir logs",
    "start `"NMS Spire`" /min spire.exe",
    ("echo Spire starting on http://127.0.0.1:" + $SpirePort)
  )
  $spireStop = @(
    "@echo off",
    "TASKKILL /IM spire.exe /F",
    "echo Spire stopped"
  )
  $spireWeb = @(
    "@echo off",
    ("start http://127.0.0.1:" + $SpirePort)
  )
  $spireAdmin = @(
    "@echo off",
    ("start http://127.0.0.1:" + $SpirePort + "/admin")
  )
  Set-Content -Path (Join-Path $InstallDir "server_start.bat") -Value $start -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "server_stop.bat") -Value $stop -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "server_restart.bat") -Value $restart -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "spire_start.bat") -Value $spireStart -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "spire_stop.bat") -Value $spireStop -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "spire_web.bat") -Value $spireWeb -Encoding ASCII
  Set-Content -Path (Join-Path $InstallDir "spire_web_admin.bat") -Value $spireAdmin -Encoding ASCII
}

function Write-InstallConfig {
  param([string]$WorldKey)
  $yaml = @(
    "# Generated by NMS install/windows/install.ps1 - keep this private.",
    ("server_path: `"" + $InstallDir + "`""),
    ("code_path: `"" + $SourceDir + "`""),
    ("mysql_host: `"" + $DbHost + "`""),
    ("mysql_port: `"" + $DbPort + "`""),
    ("mysql_database_name: `"" + $DbName + "`""),
    ("mysql_username: `"" + $DbUser + "`""),
    ("mysql_password: `"" + $DbPassword + "`""),
    ("mysql_root_password: `"" + $DbRootPassword + "`""),
    ("spire_admin_user: `"" + $SpireUser + "`""),
    ("spire_admin_password: `"" + $SpirePassword + "`""),
    ("spire_web_port: `"" + $SpirePort + "`""),
    ("short_name: `"" + $ShortName + "`""),
    ("long_name: `"" + $LongName + "`""),
    ("public_address: `"" + $PublicAddress + "`""),
    ("local_address: `"" + $LocalAddress + "`""),
    ("world_key: `"" + $WorldKey + "`"")
  )
  Set-Content -Path (Join-Path $InstallDir "install_config.yaml") -Value $yaml -Encoding ASCII
}

function Show-Banner {
  Write-Host ""
  Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
  Write-Host "|  NMS Server Windows Installer                                                |" -ForegroundColor Cyan
  Write-Host ("|  Revision " + $script:InstallerRevision + "                                                         |") -ForegroundColor Cyan
  Write-Host "|  Builds this release + installs Spire for admin / content editing            |" -ForegroundColor Cyan
  Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Cyan
  Write-Host ("Source:   " + $SourceDir) -ForegroundColor Cyan
  Write-Host ("Install:  " + $InstallDir) -ForegroundColor Cyan
  Write-Host ""
}

function Show-Finish {
  Write-Host ""
  Write-Host "Install complete." -ForegroundColor Green
  Write-Host ""
  Write-Host ("Runtime folder:  " + $InstallDir) -ForegroundColor Green
  Write-Host ("Credentials:     " + (Join-Path $InstallDir "install_config.yaml")) -ForegroundColor Green
  Write-Host ""
  Write-Host "1) Double-click spire_start.bat" -ForegroundColor Green
  Write-Host ("2) Open spire_web_admin.bat  (http://127.0.0.1:" + $SpirePort + "/admin)") -ForegroundColor Green
  Write-Host "3) Start the server from Spire, or run server_start.bat" -ForegroundColor Green
  Write-Host ""
  Write-Host "Client:" -ForegroundColor Green
  Write-Host "  - Point eqhost.txt at your loginserver (RoF2 uses port 5999)" -ForegroundColor Green
  Write-Host "  - Copy Release-NMS-Client\ClientFiles over your RoF2 client" -ForegroundColor Green
  Write-Host "  - Run bin\export_client_files.exe and copy the generated client data files" -ForegroundColor Green
  Write-Host ""
  Write-Host "GM after first login:" -ForegroundColor Green
  Write-Host "  UPDATE account SET status = 250 WHERE name = 'yourlogin';" -ForegroundColor Green
  Write-Host ""
}

Write-Host ("NMS Windows installer revision " + $script:InstallerRevision) -ForegroundColor Yellow
Require-RepoLayout
Show-Banner

if (-not $NonInteractive) {
  if (-not (Confirm-Yes "Continue with installation?" $true)) {
    Die "Aborted"
  }
}

$InstallDir = Read-Value "Server install directory" $InstallDir
$ShortName = Read-Value "Server short name" $ShortName
$LongName = Read-Value "Server long name" $LongName
$PublicAddress = Read-Value "Public address (WAN/LAN IP clients use)" $PublicAddress
$LocalAddress = Read-Value "Local address" $LocalAddress
$DbName = (Read-Value "Database name" $DbName).ToLower()
$DbName = $DbName -replace "[^a-z0-9_]", ""
$DbUser = Read-Value "Database username" $DbUser
if (-not $DbPassword) {
  $DbPassword = New-RandomPassword
}
$DbPassword = Read-Value "Database password" $DbPassword -Secret
if (-not $UseExistingMysql) {
  if (Confirm-Yes "Attempt to install/configure local MariaDB?" $true) {
    if (-not $DbRootPassword) {
      $DbRootPassword = New-RandomPassword
    }
    $DbRootPassword = Read-Value "MariaDB root password" $DbRootPassword -Secret
  } else {
    $UseExistingMysql = [switch]$true
  }
}
if (-not $SpirePassword) {
  $SpirePassword = New-RandomPassword
}
$SpireUser = Read-Value "Spire admin username" $SpireUser
$SpirePassword = Read-Value "Spire admin password" $SpirePassword -Secret
$SpirePort = [int](Read-Value "Spire HTTP port" "$SpirePort")
if (-not $SkipMaps) {
  if (-not (Confirm-Yes "Download EQEmu maps pack (~1 GB)?" $true)) {
    $SkipMaps = [switch]$true
  }
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
