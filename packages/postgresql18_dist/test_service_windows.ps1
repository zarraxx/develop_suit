$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-ArgValue {
  param(
    [string[]]$ArgsList,
    [string]$Name
  )

  for ($i = 0; $i -lt $ArgsList.Length; $i++) {
    $arg = $ArgsList[$i]
    if ($arg -eq "--$Name") {
      if ($i + 1 -ge $ArgsList.Length) {
        throw "--$Name requires a value"
      }
      return $ArgsList[$i + 1]
    }
    if ($arg.StartsWith("--$Name=")) {
      return $arg.Substring($Name.Length + 3)
    }
  }
  return ""
}

function Invoke-Logged {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  Write-Host "==> $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
  }
}

function Require-Path {
  param([string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue)) {
    throw "missing path: $PathValue"
  }
}

function Wait-PostgreSQL {
  for ($i = 0; $i -lt 60; $i++) {
    & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d postgres -Atqc "SELECT 1;" | Out-Null
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Start-Sleep -Seconds 2
  }

  Get-Service -Name $serviceName -ErrorAction SilentlyContinue | Format-List * | Out-String | Write-Host
  if (Test-Path -LiteralPath $logFile) {
    Get-Content -LiteralPath $logFile -Tail 200 | Write-Host
  }
  throw "PostgreSQL Windows service did not become ready"
}

function Invoke-Psql {
  param([string]$Sql)
  & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d postgres -v ON_ERROR_STOP=1 -c $Sql
  if ($LASTEXITCODE -ne 0) {
    throw "psql failed: $Sql"
  }
}

$archive = Get-ArgValue -ArgsList $args -Name "archive"
$packageDir = Get-ArgValue -ArgsList $args -Name "package-dir"
$oracleBasicArchive = Get-ArgValue -ArgsList $args -Name "oracle-basic-archive"
$db2CliArchive = Get-ArgValue -ArgsList $args -Name "db2-cli-archive"

if ([string]::IsNullOrWhiteSpace($archive) -and [string]::IsNullOrWhiteSpace($packageDir)) {
  throw "--archive or --package-dir is required"
}
if (-not [string]::IsNullOrWhiteSpace($archive) -and -not [string]::IsNullOrWhiteSpace($packageDir)) {
  throw "--archive and --package-dir are mutually exclusive"
}
if ([string]::IsNullOrWhiteSpace($oracleBasicArchive)) {
  throw "--oracle-basic-archive is required"
}
if ([string]::IsNullOrWhiteSpace($db2CliArchive)) {
  throw "--db2-cli-archive is required"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("postgresql18-dist-service-" + [Guid]::NewGuid().ToString("N"))
$serviceName = "postgresql18-ci"
$port = 57432
$dataDir = Join-Path $testRoot "data"
$logFile = Join-Path $testRoot "postgresql.log"
$sqlFile = Join-Path $testRoot "fdw.sql"

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

if (-not [string]::IsNullOrWhiteSpace($archive)) {
  Require-Path $archive
  tar -xf $archive `
    --exclude '*/lib/terminfo' `
    --exclude '*/lib/terminfo/*' `
    --exclude '*/share/terminfo' `
    --exclude '*/share/terminfo/*' `
    -C $testRoot
  if ($LASTEXITCODE -ne 0) {
    throw "failed to extract archive: $archive"
  }
  $packageDir = Get-ChildItem -LiteralPath $testRoot -Directory |
    Where-Object { $_.Name -like "postgresql18_dist-*" } |
    Select-Object -First 1 |
    ForEach-Object { $_.FullName }
}

if ([string]::IsNullOrWhiteSpace($packageDir)) {
  throw "could not locate extracted package"
}
$packageDir = (Resolve-Path -LiteralPath $packageDir).Path
$oracleBasicArchive = (Resolve-Path -LiteralPath $oracleBasicArchive).Path
$db2CliArchive = (Resolve-Path -LiteralPath $db2CliArchive).Path

Require-Path (Join-Path $packageDir "bin\postgres.exe")
Require-Path (Join-Path $packageDir "bin\psql.exe")
Require-Path (Join-Path $packageDir "bin\initdb.exe")
Require-Path (Join-Path $packageDir "bin\pg_ctl.exe")
Require-Path (Join-Path $packageDir "install_service.cmd")
Require-Path (Join-Path $packageDir "uninstall_service.cmd")
Require-Path (Join-Path $packageDir "install_external_dependencies.cmd")
Require-Path (Join-Path $packageDir "share\extension\oracle_fdw.control")
Require-Path (Join-Path $packageDir "share\extension\db2_fdw.control")

$env:PATH = "$packageDir\bin;$packageDir\lib;$env:PATH"

try {
  & sc.exe query $serviceName | Out-Null
  if ($LASTEXITCODE -eq 0) {
    & (Join-Path $packageDir "uninstall_service.cmd") $serviceName | Out-Null
    Start-Sleep -Seconds 3
  }

  Write-Host "==> installing vendor runtime clients"
  Invoke-Logged (Join-Path $packageDir "install_external_dependencies.cmd") @(
    "--oracle-basic-archive", $oracleBasicArchive,
    "--db2-cli-archive", $db2CliArchive
  )

  Write-Host "==> initializing test cluster"
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
  Invoke-Logged (Join-Path $packageDir "bin\initdb.exe") @(
    "--username=postgres",
    "--encoding=UTF8",
    "--auth-local=trust",
    "--auth-host=trust",
    "--no-instructions",
    "-D", $dataDir
  )
  Add-Content -LiteralPath (Join-Path $dataDir "postgresql.conf") -Value @(
    "",
    "# postgresql18_dist service test",
    "listen_addresses = '127.0.0.1'",
    "port = $port",
    "log_destination = 'stderr'",
    "logging_collector = off"
  )

  Write-Host "==> installing Windows service"
  Invoke-Logged (Join-Path $packageDir "install_service.cmd") @(
    $dataDir,
    $serviceName
  )

  Write-Host "==> starting Windows service"
  Invoke-Logged "net.exe" @("start", $serviceName)
  Wait-PostgreSQL

  $sql = @"
CREATE DATABASE dist_service_test;
\connect dist_service_test
CREATE EXTENSION oracle_fdw;
CREATE EXTENSION db2_fdw;
SELECT extname FROM pg_extension WHERE extname IN ('oracle_fdw', 'db2_fdw') ORDER BY extname;
"@
  [System.IO.File]::WriteAllText($sqlFile, $sql)
  Invoke-Logged (Join-Path $packageDir "bin\psql.exe") @(
    "-h", "127.0.0.1",
    "-p", "$port",
    "-U", "postgres",
    "-d", "postgres",
    "-v", "ON_ERROR_STOP=1",
    "-f", $sqlFile
  )

  $extensionCount = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_service_test -Atqc "SELECT count(*) FROM pg_extension WHERE extname IN ('oracle_fdw', 'db2_fdw');"
  if ($extensionCount.Trim() -ne "2") {
    throw "oracle_fdw/db2_fdw were not both activated; count=$extensionCount"
  }

  Write-Host "==> stopping and uninstalling Windows service"
  Invoke-Logged "net.exe" @("stop", $serviceName)
  Start-Sleep -Seconds 3
  Invoke-Logged (Join-Path $packageDir "uninstall_service.cmd") @(
    $serviceName
  )

  & sc.exe query $serviceName | Out-Null
  if ($LASTEXITCODE -eq 0) {
    throw "service still exists after uninstall: $serviceName"
  }
}
finally {
  & net.exe stop $serviceName | Out-Null
  & (Join-Path $packageDir "uninstall_service.cmd") $serviceName | Out-Null
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PostgreSQL 18 dist Windows service test passed"
