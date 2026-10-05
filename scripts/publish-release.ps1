<#
.SYNOPSIS
Publish (or update) the GitHub Release that matches what production runs.

.DESCRIPTION
Called by promote.yml after a build is promoted to the last pipeline stage.

  Tag    v{version}, or {component}-v{version} when the repo has more than
         one component. It points at the build's commit.
  Name   "1.4.0", or "backend 1.4.0".
  Notes  The production image details, then GitHub's generated notes since
         the previous tag of the same component.
  Latest Always: the most recent production promote is the Latest release.

If the tag already exists at another commit (a later build of the same
version reached production), the tag is moved to this build's commit and
the release notes say so. Re-running the same promote changes nothing but
the Latest flag.

Runs on Windows PowerShell 5.1 (the self-hosted runner) and PowerShell 7
(the script tests). Dot-source with -LibraryOnly to load the functions only.
#>
param(
  [string]$Repo = $env:REPO,
  [string]$Token = $env:GH_TOKEN,
  [string]$Component = $env:COMPONENT,
  [string]$Version = $env:VERSION,
  [string]$ComponentCount = $env:COMPONENT_COUNT,
  [string]$CommitSha = $env:COMMIT_SHA,
  [string]$BuildNumber = $env:BUILD_NUMBER,
  [string]$BuildId = $env:BUILD_ID,
  [string]$DockerImage = $env:DOCKER_IMAGE,
  [string]$EnvTag = $env:ENV_TAG,
  [string]$RunUrl = $env:RUN_URL,
  [switch]$DryRun,
  [switch]$LibraryOnly
)

function ConvertTo-SemverParts([string]$Value) {
  if ($Value -notmatch '^\d+\.\d+\.\d+$') { return $null }
  $parts = $Value.Split('.')
  return @([int]$parts[0], [int]$parts[1], [int]$parts[2])
}

# -1, 0 or 1; $null when either side is not major.minor.patch.
function Compare-Semver([string]$A, [string]$B) {
  $pa = ConvertTo-SemverParts $A
  $pb = ConvertTo-SemverParts $B
  if ($null -eq $pa -or $null -eq $pb) { return $null }
  for ($i = 0; $i -lt 3; $i++) {
    if ($pa[$i] -lt $pb[$i]) { return -1 }
    if ($pa[$i] -gt $pb[$i]) { return 1 }
  }
  return 0
}

function Get-TagPrefix([string]$Component, [int]$ComponentCount) {
  if ($ComponentCount -gt 1) { return "$($Component.ToLowerInvariant())-v" }
  return 'v'
}

function Get-ReleaseTag([string]$Component, [string]$Version, [int]$ComponentCount) {
  return "$(Get-TagPrefix $Component $ComponentCount)$Version"
}

function Get-ReleaseName([string]$Component, [string]$Version, [int]$ComponentCount) {
  if ($ComponentCount -gt 1) { return "$($Component.ToLowerInvariant()) $Version" }
  return $Version
}

# The highest tag with the same prefix whose version is below $Version, so the
# generated notes cover only this component's changes. $null when none.
function Get-PreviousTag([string[]]$Tags, [string]$Prefix, [string]$Version) {
  $best = $null
  $bestVersion = $null
  foreach ($tag in $Tags) {
    if (-not $tag -or -not $tag.StartsWith($Prefix)) { continue }
    $v = $tag.Substring($Prefix.Length)
    $cmp = Compare-Semver $v $Version
    if ($null -eq $cmp -or $cmp -ge 0) { continue }
    if ($null -eq $best -or (Compare-Semver $v $bestVersion) -gt 0) {
      $best = $tag
      $bestVersion = $v
    }
  }
  return $best
}

# What to do given the existing release (or $null) and the commit the tag
# points at ($null when the tag does not exist).
function Get-ReleasePlan($ExistingRelease, [string]$ExistingTagSha, [string]$CommitSha) {
  $moveTag = [bool]$ExistingTagSha -and ($ExistingTagSha -ne $CommitSha)
  return [pscustomobject]@{
    MoveTag         = $moveTag
    CreateRelease   = ($null -eq $ExistingRelease)
    AppendMovedNote = ($null -ne $ExistingRelease) -and $moveTag
  }
}

function Get-ReleaseBody {
  param([string]$Version, [string]$BuildNumber, [string]$BuildId, [string]$DockerImage,
        [string]$EnvTag, [string]$CommitSha, [string]$RunUrl, [string]$Notes)
  $lines = @(
    "**Running in production:** ``$DockerImage``",
    '',
    "- Version: $Version (build $BuildNumber)",
    "- Environment tag: ``$EnvTag``",
    "- Commit: $CommitSha",
    "- DeployTrack build: $BuildId"
  )
  if ($RunUrl) { $lines += "- Promote run: $RunUrl" }
  if ($Notes) {
    $lines += ''
    $lines += $Notes.Trim()
  }
  return ($lines -join "`n")
}

function Get-MovedNote([string]$BuildNumber, [string]$CommitSha, [string]$DockerImage, [string]$RunUrl) {
  $short = $CommitSha
  if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
  $note = "**Update:** production now runs build $BuildNumber (``$DockerImage``, commit $short); the tag was moved to it."
  if ($RunUrl) { $note += " [Promote run]($RunUrl)" }
  return $note
}

if ($LibraryOnly) { return }

# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($pair in @(@('REPO', $Repo), @('GH_TOKEN', $Token), @('VERSION', $Version), @('COMMIT_SHA', $CommitSha))) {
  if ([string]::IsNullOrWhiteSpace($pair[1])) { throw "$($pair[0]) is required" }
}
$count = 1
if ($ComponentCount) { $count = [int]$ComponentCount }

$api = "https://api.github.com/repos/$Repo"
$headers = @{
  Authorization          = "Bearer $Token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}

function Invoke-GitHub([string]$Method, [string]$Path, $Body) {
  $params = @{ Method = $Method; Uri = "$api$Path"; Headers = $headers; UseBasicParsing = $true }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $params.ContentType = 'application/json; charset=utf-8'
  }
  if ($DryRun -and $Method -ne 'GET') {
    Write-Host "DRY RUN: $Method $Path $(if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 5 -Compress })"
    return $null
  }
  return Invoke-RestMethod @params
}

# GET that returns $null on 404.
function Get-GitHubOrNull([string]$Path) {
  try {
    return Invoke-GitHub 'GET' $Path $null
  } catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and [int]$response.StatusCode -eq 404) { return $null }
    throw
  }
}

$tag = Get-ReleaseTag $Component $Version $count
$name = Get-ReleaseName $Component $Version $count

$release = Get-GitHubOrNull "/releases/tags/$tag"
$tagSha = $null
$ref = Get-GitHubOrNull "/git/ref/tags/$tag"
if ($null -ne $ref) {
  $tagSha = [string]$ref.object.sha
  if ($ref.object.type -eq 'tag') {
    # Annotated tag: resolve to the commit it points at.
    $tagSha = [string](Invoke-GitHub 'GET' "/git/tags/$tagSha" $null).object.sha
  }
}

$plan = Get-ReleasePlan $release $tagSha $CommitSha
Write-Host "Release $tag ($name): create=$($plan.CreateRelease) moveTag=$($plan.MoveTag) tagSha=$tagSha commit=$CommitSha"

if ($plan.MoveTag) {
  Invoke-GitHub 'PATCH' "/git/refs/tags/$tag" @{ sha = $CommitSha; force = $true } | Out-Null
}

if ($plan.CreateRelease) {
  $prefix = Get-TagPrefix $Component $count
  $tags = @(git tag --list "$prefix*")
  $previous = Get-PreviousTag $tags $prefix $Version
  $notesRequest = @{ tag_name = $tag; target_commitish = $CommitSha }
  if ($previous) { $notesRequest.previous_tag_name = $previous }
  $notes = ''
  try {
    $generated = Invoke-RestMethod -Method POST -Uri "$api/releases/generate-notes" -Headers $headers -UseBasicParsing `
      -ContentType 'application/json; charset=utf-8' `
      -Body ([System.Text.Encoding]::UTF8.GetBytes(($notesRequest | ConvertTo-Json -Compress)))
    $notes = [string]$generated.body
  } catch {
    Write-Warning "Could not generate release notes: $_"
  }
  $body = Get-ReleaseBody -Version $Version -BuildNumber $BuildNumber -BuildId $BuildId -DockerImage $DockerImage `
    -EnvTag $EnvTag -CommitSha $CommitSha -RunUrl $RunUrl -Notes $notes
  $release = Invoke-GitHub 'POST' '/releases' @{
    tag_name         = $tag
    target_commitish = $CommitSha
    name             = $name
    body             = $body
    make_latest      = 'true'
  }
} else {
  $update = @{ make_latest = 'true' }
  if ($plan.AppendMovedNote) {
    $update.body = ([string]$release.body).TrimEnd() + "`n`n" + (Get-MovedNote $BuildNumber $CommitSha $DockerImage $RunUrl)
  }
  $release = Invoke-GitHub 'PATCH' "/releases/$($release.id)" $update
}

$url = ''
if ($null -ne $release) { $url = [string]$release.html_url }
Write-Host "GitHub release: $url"
if ($env:GITHUB_OUTPUT) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "release_url=$url" + [Environment]::NewLine, $utf8)
  [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "release_tag=$tag" + [Environment]::NewLine, $utf8)
}
