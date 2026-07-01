param(
  [string] $WinSWVersion = "2.12.0",
  [Parameter(Mandatory = $true)]
  [string] $OutDir,
  [string] $RuntimeIdentifier = "win-x64"
)

$ErrorActionPreference = "Stop"

function Invoke-Logged {
  param(
    [Parameter(Mandatory = $true)]
    [string] $FilePath,
    [string[]] $Arguments
  )

  Write-Host "==> $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: ${FilePath}"
  }
}

$workDir = Join-Path (Get-Location) "winsw-msvc-work"
$archivePath = Join-Path $workDir "winsw-${WinSWVersion}.zip"
$sourceDir = Join-Path $workDir "winsw-${WinSWVersion}"
$outBinDir = Join-Path $OutDir "bin"
$outConfDir = Join-Path $OutDir "conf"

Remove-Item -Recurse -Force $workDir, $OutDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $workDir, $outBinDir, $outConfDir | Out-Null

$url = "https://github.com/winsw/winsw/archive/refs/tags/v${WinSWVersion}.zip"
Invoke-Logged "curl.exe" @("-L", "--fail", "--retry", "3", "-o", $archivePath, $url)
Expand-Archive -Path $archivePath -DestinationPath $workDir -Force

$projectPath = Join-Path $sourceDir "src/WinSW/WinSW.csproj"
if (-not (Test-Path $projectPath)) {
  throw "Missing WinSW project: ${projectPath}"
}

Invoke-Logged "dotnet" @(
  "publish",
  $projectPath,
  "-c", "Release",
  "-f", "net6.0-windows",
  "-r", $RuntimeIdentifier,
  "--self-contained", "true",
  "-p:PlatformTarget=x64",
  "-p:PublishSingleFile=true",
  "-p:CheckEolTargetFramework=false",
  "-p:TreatWarningsAsErrors=false",
  "-p:DebugType=None",
  "-p:DebugSymbols=false"
)

$publishedExe = Join-Path $sourceDir "artifacts/publish/WinSW-x64.exe"
if (-not (Test-Path $publishedExe)) {
  $publishedExe = Get-ChildItem -Path (Join-Path $sourceDir "artifacts") -Recurse -Filter "WinSW*.exe" |
    Sort-Object FullName |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not (Test-Path $publishedExe)) {
  throw "Unable to find published WinSW executable"
}

Copy-Item -Force $publishedExe (Join-Path $outBinDir "winsw.exe")

@"
<service>
  <id>winsw-package-test</id>
  <name>WinSW Package Test</name>
  <description>Minimal WinSW configuration shipped for package smoke tests.</description>
  <executable>%SystemRoot%\System32\cmd.exe</executable>
  <arguments>/c exit 0</arguments>
  <logpath>%BASE%</logpath>
</service>
"@ | Set-Content -Encoding ASCII -Path (Join-Path $outBinDir "winsw.xml")

Copy-Item -Force (Join-Path $outBinDir "winsw.xml") (Join-Path $outConfDir "winsw.sample.xml")

Invoke-Logged (Join-Path $outBinDir "winsw.exe") @("version")
Remove-Item -Force (Join-Path $outBinDir "winsw.wrapper.log") -ErrorAction SilentlyContinue
