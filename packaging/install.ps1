# PadLink native Windows installer. Run in PowerShell 5.1 or later.
param(
    [string]$Prefix = "$env:LOCALAPPDATA\PadLink",
    [string]$Version = "",
    [string]$From = "",
    [string]$StateDir = "",
    [switch]$AddToPath,
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
if (-not [IO.Path]::IsPathRooted($Prefix)) { throw "Prefix must be absolute." }
if ($Uninstall) {
    if (-not (Test-Path "$Prefix\share\padlink\install.json")) { throw "No managed installation at this prefix." }
    $arguments = @("uninstall")
    if ($StateDir) { $arguments += @("--state-dir", $StateDir) }
    & "$Prefix\bin\padlink.exe" @arguments
    exit $LASTEXITCODE
}
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    throw "This release supports native x64 Windows."
}
$repository = "sam-eer12/prod"
$target = "x86_64-pc-windows-msvc"
$stage = Join-Path ([IO.Path]::GetTempPath()) ("padlink-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
function Fetch([string]$url, [string]$file, [long]$limit) {
    & curl.exe --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 --max-filesize $limit --output $file $url
    if ($LASTEXITCODE -ne 0) { throw "Release download failed; the existing installation was preserved." }
}
try {
    $base = "https://github.com/$repository/releases/latest/download"
    if ($Version) {
        if ($Version -notmatch '^[0-9A-Za-z.+-]{1,64}$') { throw "Invalid version." }
        $base = "https://github.com/$repository/releases/download/v$Version"
    }
    if ($From) {
        Copy-Item -LiteralPath "$From\release-manifest.txt" -Destination $stage
        Copy-Item -LiteralPath "$From\release-manifest.sig" -Destination $stage
    } else {
        Fetch "$base/release-manifest.txt" "$stage\release-manifest.txt" 65536
        Fetch "$base/release-manifest.sig" "$stage\release-manifest.sig" 512
    }
    if ((Get-Item "$stage\release-manifest.txt").Length -gt 65536 -or (Get-Item "$stage\release-manifest.sig").Length -gt 512) {
        throw "Release metadata exceeds size limits."
    }
    $data = [IO.File]::ReadAllBytes("$stage\release-manifest.txt")
    $signature = [IO.File]::ReadAllBytes("$stage\release-manifest.sig")
    $provider = New-Object Security.Cryptography.CspParameters
    $provider.ProviderType = 24
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider -ArgumentList $provider
    $rsa.PersistKeyInCsp = $false
    $parameters = New-Object Security.Cryptography.RSAParameters
    $parameters.Modulus = [Convert]::FromBase64String("w5SekQok9rYWdfb9VQjOUeQ47Me0ZsQI6y2uXHqqSD/GBves7fsugntsaPLfJO5ngvpYH7nGdycC4AtbeJ8+f/D5BYjWWHRNdf0v/siI+NgSaKNdDcy7r4ek+dVln4B7g+taezzGaVsQrUvnGnIpwlswsTaXAFZwuB5bS3fPhdhCboBgUYFZIAEOl7nIVQMmKdbudl9JLB846u6mEGTcOybtyyXAVGoMQ3w7SGthJFuL99nzeI+QYrKjGw3GOtML3Bom185VzBNKOAwmYUtTbMiawQN3wd71qlg+M98OIv6JaqhhSN8W9qGUIAMaIYz/XyljjE6GFtJGfFSPvD1PPCBATShYyNKjypisq6crQu3f2xwIjBaC369lO8P2nisoWLhpK4cIrYBTRomI561b/i1VVxiTbO0xPb0uWLiaUOOvXf6xOEq5HKCs9cmVf7alIlGTuSEfBZyVnUO4NDYzZ2Tm9WOOX/QLk0VvsWnLz3+Pjjt65TWS1TvRtV1LjNsN")
    $parameters.Exponent = [Convert]::FromBase64String("AQAB")
    $rsa.ImportParameters($parameters)
    if (-not $rsa.VerifyData($data, "SHA256", $signature)) { throw "Release signature verification failed." }
    $lines = [Text.Encoding]::UTF8.GetString($data).Split([char]10)
    if ($lines[0].Trim() -ne "PADLINK_RELEASE 1" -or $lines[1] -notmatch '^version ([0-9A-Za-z.+-]{1,64})$') {
        throw "Unsupported release metadata."
    }
    $published = $Matches[1]
    if ($Version -and $Version -ne $published) { throw "Release differs from the requested version." }
    $records = @($lines | Where-Object { $_ -match "^artifact $target " })
    if ($records.Count -ne 1) { throw "No unique artifact for this platform." }
    $fields = $records[0].Split(" ")
    if ($fields.Count -ne 10) { throw "Malformed artifact record." }
    $archive = $fields[2]; $size = [long]$fields[3]; $expected = $fields[4]; $url = $fields[9]
    if ($archive -ne "padlink-$published-$target.tar.gz" -or $fields[8] -ne "padlink.exe" -or $url -ne "https://github.com/$repository/releases/download/v$published/$archive") {
        throw "Unexpected archive identity or download origin."
    }
    if ($size -le 0 -or $size -gt 32000000) { throw "Archive exceeds size limits." }
    if ($From) { Copy-Item -LiteralPath "$From\$archive" -Destination $stage } else { Fetch $url "$stage\$archive" $size }
    if ((Get-Item "$stage\$archive").Length -ne $size) { throw "Archive size verification failed." }
    $hasher = [Security.Cryptography.SHA256]::Create()
    $input = [IO.File]::OpenRead("$stage\$archive")
    try { $actual = [BitConverter]::ToString($hasher.ComputeHash($input)).Replace("-", "").ToLowerInvariant() }
    finally { $input.Dispose(); $hasher.Dispose() }
    if ($actual -ne $expected) { throw "Archive checksum verification failed." }
    $entries = @(& tar.exe -tzf "$stage\$archive")
    if ($LASTEXITCODE -ne 0 -or $entries.Count -ne 1 -or $entries[0] -ne "padlink.exe") { throw "Unexpected archive layout." }
    $details = @(& tar.exe -tvzf "$stage\$archive")
    if ($LASTEXITCODE -ne 0 -or $details.Count -ne 1 -or -not $details[0].StartsWith("-")) { throw "Archive binary must be a regular file." }
    & tar.exe -xzf "$stage\$archive" -C $stage -- padlink.exe
    if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed." }
    $arguments = @("_install", "--prefix", $Prefix, "--from", $stage, "--channel", "manual")
    if ($StateDir) { $arguments += @("--state-dir", $StateDir) }
    & "$stage\padlink.exe" @arguments
    if ($LASTEXITCODE -ne 0) { throw "CLI installation failed." }
    $bin = "$Prefix\bin"
    if ($AddToPath) {
        $existing = [string][Environment]::GetEnvironmentVariable("Path", "User")
        if ($existing.Split(";") -notcontains $bin) {
            [Environment]::SetEnvironmentVariable("Path", "$bin;$existing", "User")
        }
        $env:Path = "$bin;$env:Path"
        Write-Host "User PATH configured. Open a new terminal for future sessions."
    } else {
        Write-Host "Add $bin to your user PATH, or rerun this installer with -AddToPath."
    }
    Write-Host "Ready: padlink --version; padlink daemon start; padlink update"
} finally {
    if ($rsa) { $rsa.Dispose() }
    Remove-Item -LiteralPath $stage -Recurse -Force
}

