param(
  [Parameter(Mandatory = $true)]
  [string] $PackageDir
)

$ErrorActionPreference = "Stop"

$packageRoot = (Resolve-Path $PackageDir).Path
$redisService = "middleware-redis-ci"
$minioService = "middleware-minio-ci"
$redisDataDir = Join-Path $env:TEMP "${redisService}-data"
$minioDataDir = Join-Path $env:TEMP "${minioService}-data"
$redisPassword = "middleware-ci-secret"
$minioRootUser = "minioadmin"
$minioRootPassword = "minioadmin"

function Invoke-Logged {
  param(
    [Parameter(Mandatory = $true)]
    [string] $FilePath,
    [string[]] $Arguments = @()
  )

  Write-Host "==> $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: ${FilePath}"
  }
}

function Cleanup-Service {
  param(
    [string] $ServiceName,
    [string] $UninstallScript
  )

  if (Test-Path $UninstallScript) {
    cmd.exe /c "`"$UninstallScript`" $ServiceName" | Write-Host
  } else {
    sc.exe stop $ServiceName | Out-Null
    sc.exe delete $ServiceName | Out-Null
  }
}

function Wait-Redis {
  $redisCli = Join-Path $packageRoot "bin/redis-cli.exe"
  for ($i = 0; $i -lt 60; $i++) {
    $output = & $redisCli -h 127.0.0.1 -p 6379 -a $redisPassword ping 2>$null
    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match "PONG") {
      return
    }
    Start-Sleep -Seconds 1
  }
  throw "Redis service did not become ready"
}

function Wait-Minio {
  for ($i = 0; $i -lt 90; $i++) {
    try {
      curl.exe --connect-timeout 2 --max-time 5 -fsS "http://127.0.0.1:9000/minio/health/live" | Out-Null
      if ($LASTEXITCODE -eq 0) {
        return
      }
    } catch {
    }
    Start-Sleep -Seconds 1
  }
  throw "MinIO service did not become ready"
}

$installRedis = Join-Path $packageRoot "install_redis_service.cmd"
$uninstallRedis = Join-Path $packageRoot "uninstall_redis_service.cmd"
$installMinio = Join-Path $packageRoot "install_minio_service.cmd"
$uninstallMinio = Join-Path $packageRoot "uninstall_minio_service.cmd"
$redisCli = Join-Path $packageRoot "bin/redis-cli.exe"

foreach ($path in @(
  $installRedis,
  $uninstallRedis,
  $installMinio,
  $uninstallMinio,
  (Join-Path $packageRoot "bin/redis-server.exe"),
  $redisCli,
  (Join-Path $packageRoot "bin/minio.exe"),
  (Join-Path $packageRoot "bin/winsw.exe")
)) {
  if (-not (Test-Path $path)) {
    throw "Missing required file: ${path}"
  }
}

try {
  Cleanup-Service $redisService $uninstallRedis
  Cleanup-Service $minioService $uninstallMinio
  Remove-Item -Recurse -Force $redisDataDir, $minioDataDir -ErrorAction SilentlyContinue

  Write-Host "-- installing Redis service"
  Invoke-Logged "cmd.exe" @("/c", "`"$installRedis`" $redisService `"$redisDataDir`" $redisPassword")
  Invoke-Logged "net.exe" @("start", $redisService)
  Wait-Redis
  Invoke-Logged $redisCli @("-h", "127.0.0.1", "-p", "6379", "-a", $redisPassword, "set", "middleware-service-ci", "ok")
  $value = & $redisCli -h 127.0.0.1 -p 6379 -a $redisPassword get middleware-service-ci
  if (($value -join "`n") -notmatch "ok") {
    throw "Redis service get check failed"
  }
  Invoke-Logged "cmd.exe" @("/c", "`"$uninstallRedis`" $redisService")

  Write-Host "-- installing MinIO service"
  Invoke-Logged "cmd.exe" @("/c", "`"$installMinio`" $minioService `"$minioDataDir`" $minioRootUser $minioRootPassword")
  Invoke-Logged "net.exe" @("start", $minioService)
  Wait-Minio
  curl.exe --connect-timeout 5 --max-time 10 -fsS "http://127.0.0.1:9000/minio/health/live" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "MinIO health check failed"
  }
  Invoke-Logged "cmd.exe" @("/c", "`"$uninstallMinio`" $minioService")

  Write-Host "-- middleware Windows service test passed"
} finally {
  Cleanup-Service $redisService $uninstallRedis
  Cleanup-Service $minioService $uninstallMinio
  Remove-Item -Recurse -Force $redisDataDir, $minioDataDir -ErrorAction SilentlyContinue
}
