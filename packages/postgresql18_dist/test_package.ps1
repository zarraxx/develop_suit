$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-ArgumentValue {
  param(
    [string[]]$ArgsList,
    [string]$Name
  )

  for ($i = 0; $i -lt $ArgsList.Length; $i++) {
    $arg = $ArgsList[$i]
    if ($arg -eq "--$Name" -or $arg -eq "--arch" -and $Name -eq "target") {
      if ($i + 1 -ge $ArgsList.Length) {
        throw "--$Name requires a value"
      }
      return $ArgsList[$i + 1]
    }
    if ($arg.StartsWith("--$Name=")) {
      return $arg.Substring($Name.Length + 3)
    }
    if ($Name -eq "target" -and $arg.StartsWith("--arch=")) {
      return $arg.Substring(7)
    }
  }

  return ""
}

$target = Get-ArgumentValue -ArgsList $args -Name "target"
$packageDir = Get-ArgumentValue -ArgsList $args -Name "package-dir"
$archive = Get-ArgumentValue -ArgsList $args -Name "archive"

if ([string]::IsNullOrWhiteSpace($target)) {
  throw "--target is required"
}
if ($target -notin @("mingw64", "windows", "x86_64-w64-windows-gnu")) {
  throw "test_package.ps1 only supports mingw64/windows targets"
}
if (-not [string]::IsNullOrWhiteSpace($packageDir) -and -not [string]::IsNullOrWhiteSpace($archive)) {
  throw "--package-dir and --archive are mutually exclusive"
}

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [string]::IsNullOrWhiteSpace($archive)) {
  if (-not (Test-Path -LiteralPath $archive)) {
    throw "archive not found: $archive"
  }
  $testRoot = Join-Path $rootDir "build\test\x86_64-w64-windows-gnu"
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  tar -xf $archive -C $testRoot
  $packageDir = Get-ChildItem -LiteralPath $testRoot -Directory | Select-Object -First 1 | ForEach-Object { $_.FullName }
}

if ([string]::IsNullOrWhiteSpace($packageDir)) {
  throw "--package-dir or --archive is required"
}
if (-not (Test-Path -LiteralPath $packageDir)) {
  throw "package directory not found: $packageDir"
}
$packageDir = (Resolve-Path -LiteralPath $packageDir).Path

function Require-Path {
  param([string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue)) {
    throw "missing path: $PathValue"
  }
}

function Extension-Enabled {
  param([string]$Name)
  Test-Path -LiteralPath (Join-Path $packageDir "share\extension\$Name.control")
}

Require-Path (Join-Path $packageDir "bin\postgres.exe")
Require-Path (Join-Path $packageDir "bin\psql.exe")
Require-Path (Join-Path $packageDir "bin\pg_ctl.exe")
Require-Path (Join-Path $packageDir "bin\initdb.exe")
Require-Path (Join-Path $packageDir "share\extension\plpgsql.control")

$env:PATH = "$packageDir\bin;$packageDir\lib;$env:PATH"
$env:PROJ_DATA = Join-Path $packageDir "share\proj"
$env:GDAL_DATA = Join-Path $packageDir "share\gdal"

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("postgresql18-dist-test-" + [Guid]::NewGuid().ToString("N"))
$dataDir = Join-Path $testRoot "data"
$logFile = Join-Path $testRoot "postgresql.log"
$sqlFile = Join-Path $testRoot "test.sql"
$port = 56432

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$sharedPreload = @()
if (Test-Path -LiteralPath (Join-Path $packageDir "lib\pgaudit.dll")) {
  $sharedPreload += "pgaudit"
}
if (Test-Path -LiteralPath (Join-Path $packageDir "lib\pg_stat_monitor.dll")) {
  $sharedPreload += "pg_stat_monitor"
}

& (Join-Path $packageDir "bin\initdb.exe") --username=postgres --auth-local=trust --auth-host=trust --no-instructions -D $dataDir | Out-Null

$postgresArgs = @(
  "-F",
  "-p", "$port",
  "-c", "listen_addresses=127.0.0.1",
  "-c", "log_destination=stderr",
  "-c", "logging_collector=off",
  "-c", "compute_query_id=on",
  "-c", "pgaudit.log=read,write,ddl",
  "-c", "pgaudit.log_catalog=on"
)
if ($sharedPreload.Count -gt 0) {
  $postgresArgs += @("-c", "shared_preload_libraries=$($sharedPreload -join ',')")
}
$postgresArgString = ($postgresArgs | ForEach-Object {
  if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join ' '

try {
  & (Join-Path $packageDir "bin\pg_ctl.exe") -D $dataDir -l $logFile -o $postgresArgString -w start | Out-Null

  $sql = @(
    "CREATE DATABASE dist_test;",
    "\connect dist_test",
    "CREATE TABLE dist_random_data AS SELECT gs AS id, ((random() * 100)::integer) AS n, format('row-%s postgresql windows search', gs) AS content FROM generate_series(1, 64) AS gs;"
  )

  if (Extension-Enabled "postgis") {
    $sql += @(
      "CREATE EXTENSION postgis;",
      "CREATE TABLE dist_points AS SELECT id, ST_SetSRID(ST_MakePoint(id::double precision, id::double precision), 4326) AS geom FROM generate_series(1, 8) AS id;"
    )
  }
  if (Extension-Enabled "vector") {
    $sql += @(
      "CREATE EXTENSION vector;",
      "CREATE TABLE dist_vectors (id integer PRIMARY KEY, embedding vector(3));",
      "INSERT INTO dist_vectors VALUES (1, '[0,0,0]'), (2, '[1,1,1]'), (3, '[3,3,3]');"
    )
  }
  if (Extension-Enabled "pgroonga") {
    $sql += @(
      "CREATE EXTENSION pgroonga;",
      "CREATE TABLE dist_docs (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, content text NOT NULL);",
      "INSERT INTO dist_docs(content) VALUES ('postgresql extension testing with pgroonga'), ('graph search with postgresql and groonga'), ('plain text row');",
      "CREATE INDEX dist_docs_content_idx ON dist_docs USING pgroonga (content);"
    )
  }
  if (Extension-Enabled "pgaudit") {
    $sql += @(
      "CREATE EXTENSION pgaudit;",
      "SELECT /* codex_audit_probe */ count(*) FROM dist_random_data;"
    )
  }
  if (Extension-Enabled "pg_stat_monitor") {
    $sql += @(
      "CREATE EXTENSION pg_stat_monitor;",
      "SELECT pg_stat_monitor_reset();",
      "SELECT /* codex_monitor_probe */ count(*) FROM dist_random_data WHERE n >= 0;"
    )
  }

  [System.IO.File]::WriteAllLines($sqlFile, $sql)

  & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d postgres -v ON_ERROR_STOP=1 -f $sqlFile | Out-Null

  $count = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_test -Atqc "SELECT count(*) FROM dist_random_data;"
  if ($count.Trim() -ne "64") {
    throw "unexpected row count: $count"
  }

  if (Extension-Enabled "postgis") {
    $srid = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_test -Atqc "SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_MakePoint(116.397,39.908),4326),3857));"
    if ($srid.Trim() -ne "3857") {
      throw "unexpected PostGIS transform SRID: $srid"
    }
  }
  if (Extension-Enabled "vector") {
    $nearest = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_test -Atqc "SELECT id FROM dist_vectors ORDER BY embedding <-> '[1,1,1]'::vector LIMIT 1;"
    if ($nearest.Trim() -ne "2") {
      throw "unexpected vector nearest-neighbor result: $nearest"
    }
  }
  if (Extension-Enabled "pgroonga") {
    $matches = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_test -Atqc "SELECT count(*) FROM dist_docs WHERE content &@~ 'postgresql';"
    if ([int]$matches.Trim() -lt 2) {
      throw "unexpected PGroonga match count: $matches"
    }
  }
  if (Extension-Enabled "pg_stat_monitor") {
    $monitor = & (Join-Path $packageDir "bin\psql.exe") -h 127.0.0.1 -p $port -U postgres -d dist_test -Atqc "SELECT EXISTS (SELECT 1 FROM pg_stat_monitor WHERE query LIKE '%codex_monitor_probe%' AND calls > 0);"
    if ($monitor.Trim() -ne "t") {
      throw "pg_stat_monitor probe query was not recorded"
    }
  }
  if (Extension-Enabled "pgaudit") {
    Start-Sleep -Seconds 1
    $logText = Get-Content -LiteralPath $logFile -Raw
    if ($logText -notmatch "AUDIT:" -or $logText -notmatch "codex_audit_probe") {
      throw "pgaudit probe query was not recorded in $logFile"
    }
  }
}
finally {
  & (Join-Path $packageDir "bin\pg_ctl.exe") -D $dataDir -m immediate stop | Out-Null
}

Write-Host "PostgreSQL 18 dist package test passed: x86_64-w64-windows-gnu"
