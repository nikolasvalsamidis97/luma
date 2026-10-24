$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
$output = Join-Path $repo 'dist/Luma-Windows-x64'
$archive = Join-Path $repo 'dist/Luma-Windows-x64.zip'
# For developers only; end users receive the runtime and VLC in the archive.
dotnet run --project (Join-Path $root 'Luma.Checks') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core checks failed.' }
dotnet publish (Join-Path $root 'Luma.Windows/Luma.Windows.csproj') -c Release -r win-x64 --self-contained true -o $output
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
foreach ($required in @('Luma.exe','coreclr.dll','PresentationFramework.dll','libvlc/win-x64/libvlc.dll','libvlc/win-x64/libvlccore.dll')) {
 if (!(Test-Path (Join-Path $output $required))) { throw "Missing bundled component: $required" }
}
Copy-Item (Join-Path $root 'INSTALL.txt') (Join-Path $output 'START-HERE.txt')
Compress-Archive -Path $output -DestinationPath $archive -Force
Get-FileHash $archive -Algorithm SHA256
Write-Output "Created $archive"
