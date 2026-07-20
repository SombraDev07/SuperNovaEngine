# Fetch Khronos glTF-Sample-Assets Sponza into assets/models/sponza/
$ErrorActionPreference = "Stop"
$dir = Join-Path $PSScriptRoot "..\assets\models\sponza"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$base = "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/Sponza/glTF"
$gltfPath = Join-Path $dir "Sponza.gltf"
Write-Host "Downloading Sponza.gltf..."
Invoke-WebRequest -Uri "$base/Sponza.gltf" -OutFile $gltfPath -UseBasicParsing
$gltf = Get-Content $gltfPath -Raw | ConvertFrom-Json
$uris = New-Object System.Collections.Generic.HashSet[string]
foreach ($b in $gltf.buffers) { if ($b.uri) { [void]$uris.Add([string]$b.uri) } }
foreach ($img in $gltf.images) { if ($img.uri) { [void]$uris.Add([string]$img.uri) } }
$i = 0
foreach ($uri in ($uris | Sort-Object)) {
    $i++
    $out = Join-Path $dir $uri
    $parent = Split-Path $out -Parent
    if ($parent -and !(Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path $out) { Write-Host "[$i/$($uris.Count)] skip $uri"; continue }
    Write-Host "[$i/$($uris.Count)] $uri"
    Invoke-WebRequest -Uri "$base/$($uri -replace '\\','/')" -OutFile $out -UseBasicParsing
}
Write-Host "Done. Run: zig build run -- --sponza"
