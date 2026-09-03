# Start MariaDB/MySQL and wait for 127.0.0.1:3306
$ErrorActionPreference = "SilentlyContinue"

Write-Host "Starting MariaDB/MySQL if needed..."

$svcs = @(Get-Service | Where-Object {
  $_.Name -match "maria|mysql" -or $_.DisplayName -match "MariaDB|MySQL"
})

if ($svcs.Count -eq 0) {
  Write-Host "MariaDB does not appear to be installed as a Windows service."
  Write-Host "Install MariaDB, then run this again."
  exit 1
}

foreach ($svc in $svcs) {
  if ($svc.Status -eq "Running") {
    Write-Host ($svc.Name + " is already running")
    continue
  }
  Write-Host ("Starting " + $svc.Name)
  try {
    Set-Service -Name $svc.Name -StartupType Automatic
  } catch {
  }
  try {
    Start-Service -Name $svc.Name
  } catch {
    cmd.exe /c ("net start `"" + $svc.Name + "`"") | Out-Null
  }
}

Write-Host "Waiting for 127.0.0.1:3306 ..."
$elapsed = 0
while ($elapsed -lt 30) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1", 3306, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(400, $false)
    if ($ok) {
      $client.EndConnect($iar)
      $client.Close()
      Write-Host "MariaDB is listening on 127.0.0.1:3306"
      exit 0
    }
    $client.Close()
  } catch {
  }
  Start-Sleep -Seconds 1
  $elapsed += 1
}

Write-Host ""
Write-Host "Port 3306 is still closed. Spire cannot start without the database."
Write-Host "Start MariaDB, then run spire_start.bat again:"
Write-Host "  1. Win+R, type services.msc, Start the MariaDB service"
Write-Host "  2. Or from an Administrator Command Prompt:  net start MariaDB"
exit 1
