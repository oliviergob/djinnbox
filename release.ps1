$ErrorActionPreference = "Stop"

$version = (Get-Content (Join-Path $PSScriptRoot "VERSION") -Raw).Trim()
if (-not $version) { Write-Error "VERSION file is empty"; exit 1 }

$tag = "v$version"
$exe = Join-Path $PSScriptRoot "Output\djinnbox-setup.exe"

if (-not (Test-Path $exe)) {
    Write-Error "Output\djinnbox-setup.exe not found — compile djinnbox-setup.iss with Inno Setup first"
    exit 1
}

Write-Host "Releasing $tag..."

git push origin main
git tag $tag
git push origin $tag
gh release create $tag $exe --title "Djinnbox $tag" --notes "Djinnbox Dev Environment $tag"

Write-Host "Done. Release: $tag"
