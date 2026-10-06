# Put Git Bash, jq and yq on PATH for the bash steps of the reusable
# workflows (dev-ci.yml detect, promote.yml setup) on a Windows runner.
# Usage: setup-tools.ps1   (writes to GITHUB_PATH when set; always prints it)
#
# - Git Bash: GITHUB_PATH gets Git's bin folder, so `shell: bash` resolves to
#   Git Bash rather than C:\Windows\System32\bash.exe (WSL), which comes first
#   on a default Windows PATH.
# - jq and yq: pinned releases, checked against their SHA256 and kept in the
#   runner tool cache, so a self-hosted runner downloads them once.
# - jq.exe writes CRLF line endings unless given -b, which breaks every
#   `read` loop in the scripts. `jq` on PATH is a small bash wrapper that
#   always passes -b; the binary itself is jq-windows.exe.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tools = @(
  @{
    Name    = 'yq'
    Version = '4.44.6'
    Url     = 'https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_windows_amd64.exe'
    Sha256  = 'd9219f7ea2f0d9b72d8dc16c2a61eb2b30599dc19ee71c41c4f5691dbf3e7c9a'
    File    = 'yq.exe'
  },
  @{
    Name    = 'jq'
    Version = '1.7.1'
    Url     = 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe'
    Sha256  = '7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab'
    File    = 'jq-windows.exe'
  }
)

function Find-GitBashBin {
  # git.exe lives in Git\cmd, Git\bin or Git\mingw64\bin; bash.exe in Git\bin.
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($git) {
    $dir = Split-Path -Parent $git.Source
    while ($dir) {
      if (Test-Path (Join-Path $dir 'bin\bash.exe')) { return (Join-Path $dir 'bin') }
      $parent = Split-Path -Parent $dir
      if ($parent -eq $dir) { break }
      $dir = $parent
    }
  }
  $default = Join-Path $env:ProgramFiles 'Git\bin'
  if (Test-Path (Join-Path $default 'bash.exe')) { return $default }
  throw 'Git Bash not found: install Git for Windows on the runner (bash.exe is expected in <Git>\bin).'
}

function Test-Sha256([string]$Path, [string]$Expected) {
  (Test-Path $Path) -and ((Get-FileHash -Algorithm SHA256 $Path).Hash -eq $Expected.ToUpperInvariant())
}

$cacheRoot = if ($env:RUNNER_TOOL_CACHE) { $env:RUNNER_TOOL_CACHE } else { Join-Path $env:TEMP 'tool-cache' }
$paths = @(Find-GitBashBin)

foreach ($t in $tools) {
  $dir = Join-Path $cacheRoot "deploytrack\$($t.Name)-$($t.Version)"
  $exe = Join-Path $dir $t.File
  if (Test-Sha256 $exe $t.Sha256) {
    Write-Host "$($t.Name) $($t.Version): cached at $exe"
  } else {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Download beside the target and rename, so a half-written file never
    # looks like a cached tool.
    $tmp = "$exe.$PID.download"
    Write-Host "$($t.Name) $($t.Version): downloading $($t.Url)"
    Invoke-WebRequest -UseBasicParsing -Uri $t.Url -OutFile $tmp
    if (-not (Test-Sha256 $tmp $t.Sha256)) {
      $got = (Get-FileHash -Algorithm SHA256 $tmp).Hash
      Remove-Item -Force $tmp
      throw "$($t.Name) download failed its checksum: expected $($t.Sha256), got $got"
    }
    Move-Item -Force $tmp $exe
  }
  if ($t.Name -eq 'jq') {
    # Wrapper so bash scripts calling `jq` get LF output (see top of file).
    $wrapper = "#!/usr/bin/env bash`nexec `"`$(dirname `"`$0`")/$($t.File)`" -b `"`$@`"`n"
    [System.IO.File]::WriteAllText((Join-Path $dir 'jq'), $wrapper, (New-Object System.Text.UTF8Encoding $false))
  }
  $paths += $dir
}

foreach ($p in $paths) {
  Write-Host "PATH += $p"
  if ($env:GITHUB_PATH) {
    [System.IO.File]::AppendAllText($env:GITHUB_PATH, "$p`n", (New-Object System.Text.UTF8Encoding $false))
  }
}
