# Tests for the pure helpers in publish-release.ps1 (tag naming, previous-tag
# selection, create/update decision, notes). No network: the script is
# dot-sourced with -LibraryOnly. Usage: pwsh scripts/tests/publish-release.tests.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot '..') 'publish-release.ps1') -LibraryOnly

$script:cases = 0
$script:failures = 0

function Check([string]$Name, $Got, $Want) {
  $script:cases++
  if ("$Got" -ceq "$Want") {
    Write-Host "ok   $Name"
  } else {
    $script:failures++
    Write-Host "FAIL $Name`n     got:  '$Got'`n     want: '$Want'"
  }
}

Check 'single component: plain v tag' (Get-ReleaseTag 'app' '1.4.0' 1) 'v1.4.0'
Check 'multi component: prefixed tag' (Get-ReleaseTag 'Backend' '1.4.0' 2) 'backend-v1.4.0'
Check 'single component: name is the version' (Get-ReleaseName 'app' '1.4.0' 1) '1.4.0'
Check 'multi component: name has the component' (Get-ReleaseName 'frontend' '2.0.0' 3) 'frontend 2.0.0'

Check 'semver compares numerically' (Compare-Semver '1.10.0' '1.9.9') 1
Check 'semver equal' (Compare-Semver '2.0.0' '2.0.0') 0
Check 'non-semver is not comparable' ($null -eq (Compare-Semver 'v1' '1.0.0')) $true

$tags = @('backend-v1.2.0', 'backend-v1.3.0', 'backend-v1.10.0', 'frontend-v1.9.0', 'backend-vnext', 'v1.3.5')
Check 'previous tag: highest lower version, same component' (Get-PreviousTag $tags 'backend-v' '1.4.0') 'backend-v1.3.0'
Check 'previous tag: ignores higher versions' (Get-PreviousTag $tags 'backend-v' '1.11.0') 'backend-v1.10.0'
Check 'previous tag: none below the first release' ($null -eq (Get-PreviousTag $tags 'backend-v' '1.0.0')) $true
Check 'previous tag: other components ignored' (Get-PreviousTag $tags 'frontend-v' '2.0.0') 'frontend-v1.9.0'
Check 'previous tag: single-component prefix' (Get-PreviousTag $tags 'v' '1.4.0') 'v1.3.5'

$plan = Get-ReleasePlan $null $null 'abc123'
Check 'new version: create release, tag made with it' "$($plan.CreateRelease)/$($plan.MoveTag)/$($plan.AppendMovedNote)" 'True/False/False'

$existing = [pscustomobject]@{ id = 7; body = 'old' }
$plan = Get-ReleasePlan $existing 'abc123' 'ABC123'
Check 're-run at the same commit: only refresh Latest' "$($plan.CreateRelease)/$($plan.MoveTag)/$($plan.AppendMovedNote)" 'False/False/False'

$plan = Get-ReleasePlan $existing 'abc123' 'def456'
Check 'later build of the same version: move tag, note it' "$($plan.CreateRelease)/$($plan.MoveTag)/$($plan.AppendMovedNote)" 'False/True/True'

$plan = Get-ReleasePlan $null 'abc123' 'def456'
Check 'tag without a release at another commit: move, then create' "$($plan.CreateRelease)/$($plan.MoveTag)/$($plan.AppendMovedNote)" 'True/True/False'

$body = Get-ReleaseBody -Version '1.4.0' -BuildNumber '3' -BuildId '42' -DockerImage 'ghcr.io/a/b-api:1.4.0-build3' `
  -EnvTag 'ghcr.io/a/b-api:production' -CommitSha 'abc' -RunUrl 'https://run' -Notes "## What's Changed`n* fix"
Check 'body names the production image' ($body.Contains('``ghcr.io/a/b-api:1.4.0-build3``') -or $body.Contains('`ghcr.io/a/b-api:1.4.0-build3`')) $true
Check 'body keeps generated notes' ($body.Contains("## What's Changed")) $true

$note = Get-MovedNote '4' '0123456789abcdef' 'img:1.4.0-build4' ''
Check 'moved note uses the short commit' ($note.Contains('commit 0123456')) $true

Write-Host ''
Write-Host "$($script:cases - $script:failures)/$($script:cases) passed"
if ($script:failures -gt 0) { exit 1 }
