param(
    [string]$PackageDirectory = "build/package"
)

$ErrorActionPreference = "Stop"

$zip = Join-Path $PackageDirectory "Download-Beast-Windows.zip"
$sidecar = "$zip.sha256"

if (!(Test-Path $zip) -or !(Test-Path $sidecar)) {
    throw "Package or checksum file is missing."
}

$actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$expected = (Get-Content -Raw $sidecar).Trim()

if ($expected -ne "$actual  Download-Beast-Windows.zip") {
    throw "Independent SHA-256 verification failed."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $zip).Path)

try {
    $names = @($archive.Entries | ForEach-Object {
        $_.FullName.Replace('\', '/')
    })

    foreach ($required in @(
        "Download Beast.exe",
        "build-manifest.json",
        "THIRD_PARTY_NOTICES.txt"
    )) {
        if ($names -notcontains $required) {
            throw "Missing ZIP entry: $required"
        }
    }

    if (!($names | Where-Object { $_ -like "data/*" })) {
        throw "Flutter data directory is missing."
    }

    if (!($names | Where-Object { $_ -match '\.dll$' })) {
        throw "Runtime DLLs are missing."
    }

    $entry = $archive.GetEntry("build-manifest.json")
    $stream = $entry.Open()

    try {
        $reader = [IO.StreamReader]::new($stream)
        try {
            $manifest = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    $headCommit = (git rev-parse HEAD).Trim()

    if ($manifest.commit -cne $headCommit) {
        throw "Manifest commit mismatch."
    }

    if ($manifest.flutter -ne "3.47.5" -or $manifest.dart -ne "3.13.4") {
        throw "Manifest toolchain mismatch."
    }
} finally {
    $archive.Dispose()
}

Write-Host "Independent package and checksum verification PASSED."
