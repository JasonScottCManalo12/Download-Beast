param(
  [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$FlutterRoot
)

$ErrorActionPreference = "Stop"
$releasePath = [IO.Path]::GetFullPath($ReleaseDirectory)
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$flutterPath = [IO.Path]::GetFullPath($FlutterRoot)
if (-not (Test-Path -LiteralPath $releasePath -PathType Container)) {
  throw "Windows release directory does not exist: $releasePath"
}
if (-not (Test-Path -LiteralPath $flutterPath -PathType Container)) {
  throw "Flutter SDK directory does not exist: $flutterPath"
}
[IO.Directory]::CreateDirectory($outputPath) | Out-Null

$expectedExe = Join-Path $releasePath "Download Beast.exe"
$builtExe = Join-Path $releasePath "download_beast.exe"
if (-not (Test-Path -LiteralPath $expectedExe -PathType Leaf)) {
  if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) {
    throw "Expected Windows executable not found in $releasePath"
  }
  Rename-Item -LiteralPath $builtExe -NewName "Download Beast.exe"
}

$toolchain = (& (Join-Path $flutterPath "bin/flutter.bat") --version --machine | ConvertFrom-Json)
$pubspecVersion = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
if (-not $pubspecVersion) { throw "Could not read app version from pubspec.yaml" }
$manifest = [ordered]@{
  product = "Download Beast"
  version = $pubspecVersion
  commit = (& git rev-parse HEAD).Trim()
  flutter = $toolchain.frameworkVersion
  dart = $toolchain.dartSdkVersion
}
$manifestPath = Join-Path $releasePath "build-manifest.json"
$manifest | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $manifestPath

$noticePath = Join-Path $releasePath "THIRD_PARTY_NOTICES.txt"
"Third-party license notices for Download Beast dependencies.`n" |
  Set-Content -Encoding utf8 -LiteralPath $noticePath
$packages = Get-Content -Raw .dart_tool/package_config.json | ConvertFrom-Json
foreach ($package in $packages.packages) {
  $rootUri = [Uri]$package.rootUri
  if (-not $rootUri.IsAbsoluteUri) { continue }
  $packageRoot = $rootUri.LocalPath
  $licenses = Get-ChildItem -LiteralPath $packageRoot -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(LICENSE|NOTICE|COPYING)(\.|$)' }
  foreach ($license in $licenses) {
    Add-Content -Encoding utf8 -LiteralPath $noticePath "`n===== $($package.name) / $($license.Name) =====`n"
    Get-Content -Raw -LiteralPath $license.FullName | Add-Content -Encoding utf8 -LiteralPath $noticePath
  }
}
$flutterLicense = Join-Path $flutterPath "LICENSE"
if (Test-Path -LiteralPath $flutterLicense -PathType Leaf) {
  Add-Content -Encoding utf8 -LiteralPath $noticePath "`n===== Flutter SDK / LICENSE =====`n"
  Get-Content -Raw -LiteralPath $flutterLicense | Add-Content -Encoding utf8 -LiteralPath $noticePath
}

$zipName = "Download-Beast-Windows.zip"
$zipPath = Join-Path $outputPath $zipName
$sidecarName = "$zipName.sha256"
$sidecarPath = Join-Path $outputPath $sidecarName
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $sidecarPath)) {
  throw "Refusing to overwrite an existing package or checksum in $outputPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $releasePath,
  $zipPath,
  [System.IO.Compression.CompressionLevel]::Optimal,
  $false
)

$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
  if ($names -notcontains "Download Beast.exe") { throw "ZIP is missing Download Beast.exe" }
  if (-not ($names | Where-Object { $_ -like "data/*" })) { throw "ZIP is missing Flutter data files" }
  if (-not ($names | Where-Object { $_ -match '\.dll$' })) { throw "ZIP is missing runtime DLLs" }
  if ($names -notcontains "THIRD_PARTY_NOTICES.txt") { throw "ZIP is missing third-party notices" }
  if ($names -notcontains "build-manifest.json") { throw "ZIP is missing build manifest" }
  $manifestEntry = $archive.GetEntry("build-manifest.json")
  $stream = $manifestEntry.Open()
  try {
    $reader = [IO.StreamReader]::new($stream)
    try { $embeddedManifest = $reader.ReadToEnd() | ConvertFrom-Json }
    finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
  if ($embeddedManifest.commit -ne $manifest.commit -or
      $embeddedManifest.flutter -ne "3.47.5" -or
      $embeddedManifest.dart -ne "3.13.4") {
    throw "ZIP manifest commit or toolchain provenance is invalid"
  }
} finally {
  $archive.Dispose()
}

$digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($sidecarPath, "$digest  $zipName`n", [Text.Encoding]::ASCII)
$sidecar = Get-Content -Raw -LiteralPath $sidecarPath
$pattern = "^([0-9a-f]{64})  $([regex]::Escape($zipName))`n$"
$match = [regex]::Match($sidecar, $pattern)
if (-not $match.Success -or $match.Groups[1].Value -ne $digest) {
  throw "External SHA-256 sidecar is malformed or does not match the ZIP"
}

Write-Host "Commit: $($manifest.commit)"
Write-Host "Flutter: $($manifest.flutter); Dart: $($manifest.dart)"
Write-Host "ZIP: $zipPath"
Write-Host "ZIP SHA-256: $digest"
