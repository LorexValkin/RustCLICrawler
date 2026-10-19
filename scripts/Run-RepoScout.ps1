[CmdletBinding()]
param([string]$ConfigPath, [switch]$RepositoriesOnly, [string]$OfflineFixturePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Scout.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Relevance.psm1') -Force
$scoutProfile = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../rustcli.profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '../scout.config.json' }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$output = if ([IO.Path]::IsPathRooted($config.outputDirectory)) { [IO.Path]::GetFullPath($config.outputDirectory) } else { [IO.Path]::GetFullPath((Join-Path $root $config.outputDirectory)) }
$fixtures = if ($OfflineFixturePath) { Get-Content -LiteralPath $OfflineFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if ($fixtures -and -not $RepositoriesOnly) { throw 'Offline fixture mode requires -RepositoriesOnly; no network is permitted.' }
[IO.Directory]::CreateDirectory($output) | Out-Null
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $output '.run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { throw 'Another scout run is active; refusing concurrent ledger writes.' }
$start = [DateTime]::UtcNow
$date = (Get-Date).ToString('yyyy-MM-dd')
$runId = (Get-Date).ToString('yyyy-MM-dd_HHmmss_fff')
$runDir = Join-Path $output "runs/$runId"
[IO.Directory]::CreateDirectory($runDir) | Out-Null
$script:calls = 0
$script:githubLimits = $null
$errors = New-Object 'Collections.Generic.List[object]'
$events = New-Object 'Collections.Generic.List[object]'
$checked = New-Object 'Collections.Generic.List[object]'
$sources = New-Object 'Collections.Generic.List[object]'

function Assert-Budget {
    if (([DateTime]::UtcNow - $start).TotalMinutes -ge $config.maxMinutes) { throw 'Run time budget exhausted' }
}
function Get-Github([string]$Endpoint) {
    Assert-Budget
    if ($script:calls -ge $config.maxGithubCalls) { throw 'GitHub call budget exhausted' }
    if ($Endpoint -notmatch '^(rate_limit$|repos/|search/repositories\?)' -or $Endpoint -match '[\s"\r\n]') { throw 'Invalid read-only endpoint' }
    if ($script:githubLimits -and $Endpoint -ne 'rate_limit') {
        $pool = if ($Endpoint.StartsWith('search/')) { $script:githubLimits.search } else { $script:githubLimits.core }
        if ($pool.remaining -le 0) { throw 'Authenticated GitHub request pool exhausted; deferred to a later run' }
        $pool.remaining--
    }
    $script:calls++
    if ($fixtures) {
        $property = $fixtures.PSObject.Properties[$Endpoint]
        if (-not $property) { throw "Missing offline fixture endpoint: $Endpoint" }
        return $property.Value
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command gh.exe -ErrorAction Stop).Source
    $psi.Arguments = 'api --hostname github.com --method GET "' + $Endpoint + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'GitHub request timed out' }
        $text = $stdout.GetAwaiter().GetResult()
        $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            if ($script:githubLimits -and $diagnostic -match '(?i)rate limit|HTTP 429') {
                $script:githubLimits.core.remaining = 0
                $script:githubLimits.search.remaining = 0
            }
            throw ('GitHub request failed (exit ' + $process.ExitCode + '): ' + (ConvertTo-PlainText $diagnostic 300))
        }
        $parsed = $text | ConvertFrom-Json
        foreach ($record in $parsed) { Write-Output $record }
    } finally { $process.Dispose() }
}
function Save-Observation($Item) {
    $previous = if ($ledger.ContainsKey($Item.id)) { $ledger[$Item.id] } else { $null }
    if ($Item.kind -eq 'repository') {
        $sourceChanged = $previous -and $previous.last_seen_version -ne $Item.last_seen_version
        if ($previous -and $previous.last_seen_version -like 'push:*' -and $previous.PSObject.Properties['last_push_at'] -and $previous.last_push_at -eq $Item.last_push_at) { $sourceChanged = $false }
        $releaseChanged = $false
        $changedReleaseFields = @()
        if ($previous -and $previous.PSObject.Properties['release'] -and $previous.release -and $Item.release -and ($previous.release.tag -ne $Item.release.tag -or $previous.release.notes -ne $Item.release.notes)) { $changedReleaseFields += 'release' }
        if ($previous -and $previous.PSObject.Properties['stable_release'] -and $previous.stable_release -and $Item.stable_release -and ($previous.stable_release.tag -ne $Item.stable_release.tag -or $previous.stable_release.notes -ne $Item.stable_release.notes)) { $changedReleaseFields += 'stable_release' }
        $releaseChanged = $changedReleaseFields.Count -gt 0
        $Item | Add-Member -NotePropertyName source_changed -NotePropertyValue ([bool]$sourceChanged) -Force
        $Item | Add-Member -NotePropertyName release_changed -NotePropertyValue ([bool]$releaseChanged) -Force
        $Item | Add-Member -NotePropertyName release_changed_fields -NotePropertyValue $changedReleaseFields -Force
    }
    if ($ledger.ContainsKey($Item.id)) {
        $old = $ledger[$Item.id]
        $Item.first_seen = $old.first_seen
        if ((Get-ScoutFingerprint $old) -ne (Get-ScoutFingerprint $Item) -or ($Item.kind -eq 'repository' -and $Item.release_changed)) {
            $Item.changed_since_last = if ($Item.kind -eq 'repository' -and $Item.release_changed) { "Release or release notes changed: $($old.release.tag) -> $($Item.release.tag). Source: $($Item.last_seen_version)" } else { "Source changed from $($old.last_seen_version) to $($Item.last_seen_version)" }
            $events.Add($Item)
        }
    } elseif ($Item.kind -eq 'repository' -and $config.previouslyReviewed -contains $Item.full_name) {
        $Item.changed_since_last = ''
        $Item.status = 'reviewed'
        $Item.uncertain += ' Owner previously reviewed this project; no previous SHA/tag supplied, so this run establishes a baseline without claiming a major change.'
    } else {
        $Item.changed_since_last = 'First observation; no historical comparison available'
        $events.Add($Item)
    }
    $ledger[$Item.id] = $Item
    $Item | Add-Member -NotePropertyName review_signal -NotePropertyValue (Get-RustcliReviewSignal $Item $scoutProfile) -Force
    $checked.Add($Item)
}
try {
    $ledgerPath = Join-Path $output 'ledger.jsonl'
    $ledger = Read-ScoutLedger $ledgerPath
    foreach ($legacy in @($ledger.Values | Where-Object { $_.kind -eq 'paper' -and $_.url -like 'https://huggingface.co/papers/*' -and $_.url -notmatch '^https://huggingface.co/papers/\d{4}\.\d{4,5}(v\d+)?$' })) {
        $legacy.status = 'skip'
        $legacy.uncertain = 'Legacy feed-array parsing defect combined multiple papers. Preserved for history; excluded from review. Correct individual papers are collected separately.'
    }
    $rate = Get-Github 'rate_limit'
    if ($rate.resources.core.limit -le 60) { throw 'Authenticated GitHub access is required. Configure gh login before scheduling this collector.' }
    $script:githubLimits = [pscustomobject]@{ core = $rate.resources.core; search = $rate.resources.search }
    $rateAtStart = $script:githubLimits | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $sources.Add(@{ url = 'https://api.github.com/rate_limit'; status = 'authenticated'; core_limit = $rate.resources.core.limit; search_limit = $rate.resources.search.limit })
    if (-not $ledger.ContainsKey('owner-exclusion:jcode')) {
        $ledger['owner-exclusion:jcode'] = [pscustomobject]@{ id = 'owner-exclusion:jcode'; kind = 'exclusion'; title = 'jcode'; url = ''; first_seen = $date; last_checked = $date; last_seen_version = ''; status = 'unsafe'; reason = 'Owner explicitly excluded as unsafe. Exact upstream and evidence URL not supplied; no independent finding asserted.' }
    }
    $repos = @{}
    # Existing records get priority so new search results cannot starve change tracking.
    $names = @($scoutProfile.priorityRepositories) + @($config.previouslyReviewed) + @($config.seedRepositories) + @($ledger.Values | Where-Object { $_.kind -eq 'repository' -and $_.status -ne 'unsafe' } | Sort-Object last_checked | Select-Object -ExpandProperty full_name)
    foreach ($name in ($names | Select-Object -Unique)) {
        # Reserve half the candidate budget for fresh discovery on every run.
        if ($repos.Count -ge [Math]::Floor($config.maxCandidates / 2)) { break }
        try {
            $m = Get-Github "repos/$name"
            if ($m.private) { throw 'Private repository excluded from public research collection' }
            $repos[$m.full_name] = $m
        }
        catch { $errors.Add(@{ source = "https://api.github.com/repos/$name"; error = $_.Exception.Message }) }
    }
    $queries = @($config.repositoryQueries)
    # Rotate the first discovery topic hourly so a full candidate budget cannot starve later topics.
    $queryOffset = if ($queries.Count) { [int]([Math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalHours) % $queries.Count) } else { 0 }
    foreach ($query in @($(for ($queryIndex = 0; $queryIndex -lt $queries.Count; $queryIndex++) { $queries[($queryIndex + $queryOffset) % $queries.Count] }))) {
        if ($repos.Count -ge $config.maxCandidates) { break }
        $q = [Uri]::EscapeDataString("$query archived:false fork:false pushed:>=$((Get-Date).AddDays(-$config.lookbackDays).ToString('yyyy-MM-dd'))")
        $endpoint = "search/repositories?q=$q&sort=updated&order=desc&per_page=8"
        try {
            $result = Get-Github $endpoint
            $sources.Add(@{ url = "https://api.github.com/$endpoint"; status = 'ok' })
            foreach ($m in $result.items) { if ($repos.Count -lt $config.maxCandidates) { $repos[$m.full_name] = $m } }
        } catch { $errors.Add(@{ source = "https://api.github.com/$endpoint"; error = $_.Exception.Message }) }
    }
    $shortlisted = 0
    foreach ($m in ($repos.Values | Sort-Object @{Expression = { if ($scoutProfile.priorityRepositories -contains $_.full_name) { 0 } else { 1 } }}, @{Expression = { $priorSort = $ledger['github:' + $_.full_name.ToLowerInvariant()]; if ($priorSort -and $priorSort.PSObject.Properties['last_source_checked']) { $priorSort.last_source_checked } else { '' } }}, @{Expression = 'stargazers_count'; Descending = $true})) {
        if (([DateTime]::UtcNow - $start).TotalMinutes -ge $config.maxMinutes) {
            $errors.Add(@{ source = 'run-budget'; error = 'Time budget reached; publishing collected observations as a partial run.' })
            break
        }
        $id = 'github:' + $m.full_name.ToLowerInvariant()
        $prior = if ($ledger.ContainsKey($id)) { $ledger[$id] } else { $null }
        $excluded = $config.excludedRepositoryNames -contains $m.name
        $stale = ([DateTime]$m.pushed_at) -lt (Get-Date).AddDays(-90)
        $skip = $m.archived -or $m.fork -or ($stale -and (-not $prior -or $prior.status -ne 'watch'))
        $description = ConvertTo-PlainText ([string]$m.description)
        $areas = @(Get-ScoutAreas ($m.full_name + ' ' + $description + ' ' + ($m.topics -join ' ')) $config)
        $item = [pscustomobject][ordered]@{
            id = $id; kind = 'repository'; full_name = $m.full_name; url = $m.html_url
            first_seen = $date; last_checked = $date; last_seen_version = ''; areas = $areas
            summary = $description; license = $(if ($m.license) { $m.license.spdx_id } else { 'unknown' })
            stars = $m.stargazers_count; star_delta = $(if ($prior) { $m.stargazers_count - $prior.stars } else { $null })
            contributors = $(if ($prior -and $prior.PSObject.Properties['contributors']) { $prior.contributors } else { $null }); last_push = ([DateTime]$m.pushed_at).ToString('yyyy-MM-dd'); last_push_at = [string]$m.pushed_at; release_cadence = $(if ($prior -and $prior.PSObject.Properties['release_cadence']) { $prior.release_cadence } else { 'not checked' })
            mechanisms = @(); already_in_rustcli = 'Automatic collection only; compare with the supplied RustCLI baseline before recommending adoption.'
            safety_flags = @(); scores = @{ relevance = [Math]::Min(3, $areas.Count); novelty = $null; maturity = $null; maintenance = $(if (-not $stale) { 2 } else { 0 }) }
            recommendation = 'watch'; status = 'candidate'; changed_since_last = ''; uncertain = 'Novelty, mechanism quality, contributor total and issue responsiveness require review. No safety clearance implied.'
            evidence_urls = @("https://api.github.com/repos/$($m.full_name)"); review_level = 'metadata'; release = $(if ($prior -and $prior.PSObject.Properties['release']) { $prior.release } else { $null })
            last_source_checked = $(if ($prior -and $prior.PSObject.Properties['last_source_checked']) { $prior.last_source_checked } else { '' })
            stable_release = $(if ($prior -and $prior.PSObject.Properties['stable_release']) { $prior.stable_release } else { $null }); recent_changes = @(); change_log_truncated = $false
        }
        if ($skip) { $item.status = 'skip'; $item.recommendation = 'skip'; $item.uncertain = 'Excluded by archive/fork/90-day activity filter.' }
        if ($prior -and $prior.status -in @('reviewed', 'watch', 'audit') -and -not $skip) { $item.status = $prior.status }
        if ($excluded) { $item.status = 'unsafe'; $item.recommendation = 'unsafe'; $item.safety_flags = @(@{ issue = 'Owner exclusion; not independently verified'; evidence_url = $null }) }
        if (-not $skip -and -not $excluded -and $shortlisted -lt $config.maxDetailedRepositories) {
            $shortlisted++
            $item.last_source_checked = [DateTime]::UtcNow.ToString('o')
            try {
                $priority = $scoutProfile.priorityRepositories -contains $m.full_name
                $commitLimit = if ($priority) { 15 } else { 1 }
                $commits = @(Get-Github "repos/$($m.full_name)/commits?per_page=$commitLimit")
                $sha = $commits[0].sha
                $item.last_seen_version = $sha
                if ($priority -and $prior -and $prior.last_seen_version -match '^[0-9a-f]{40}$' -and $prior.last_seen_version -ne $sha) {
                    $foundPrior = $false
                    foreach ($commit in $commits) {
                        if ($commit.sha -eq $prior.last_seen_version) { $foundPrior = $true; break }
                        $item.recent_changes += @{sha=$commit.sha;message=(ConvertTo-PlainText $commit.commit.message 900);url=$commit.html_url}
                    }
                    $item.change_log_truncated = -not $foundPrior
                }
                $releases = @(Get-Github "repos/$($m.full_name)/releases?per_page=3")
                $item.release_cadence = ($releases | ForEach-Object { "$($_.tag_name)@$($_.published_at)" }) -join '; '
                if ($releases.Count) { $item.release = @{ tag = $releases[0].tag_name; published = $releases[0].published_at; url = $releases[0].html_url; notes = (ConvertTo-PlainText $releases[0].body 6000) } } else { $item.release = $null }
                if ($priority) {
                    try {
                        $stable = Get-Github "repos/$($m.full_name)/releases/latest"
                        $item.stable_release = @{ tag=$stable.tag_name;published=$stable.published_at;url=$stable.html_url;notes=(ConvertTo-PlainText $stable.body 6000) }
                    } catch { $item.uncertain += ' Latest stable release unavailable; recent releases are retained.' }
                }
                $contributors = @(Get-Github "repos/$($m.full_name)/contributors?per_page=100&anon=true")
                $item.contributors = $contributors.Count
                $item.review_level = 'source-triage'
                $item.uncertain = 'Automated source triage, not a deep review. Contributors is a lower bound when 100. Dependency install paths, issue responsiveness, novelty and efficacy are unverified.'
                if (-not $prior -or $prior.last_seen_version -ne $sha) {
                    $tree = Get-Github "repos/$($m.full_name)/git/trees/$sha`?recursive=1"
                    $paths = @($tree.tree | Where-Object { $_.type -eq 'blob' -and ($_.path -match '^(README\.md|package\.json|pyproject\.toml|Cargo\.toml|install\.(sh|ps1)|setup\.py|scripts/install\.(sh|ps1))$') } | Select-Object -First 5)
                    foreach ($file in $paths) {
                        if ($file.size -gt 200000) { continue }
                        $blob = Get-Github "repos/$($m.full_name)/git/blobs/$($file.sha)"
                        if ($blob.encoding -ne 'base64') { continue }
                        $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($blob.content))
                        $fileUrl = "$($m.html_url)/blob/$sha/$($file.path)"
                        $item.evidence_urls += $fileUrl
                        $lineNumber = 0
                        foreach ($line in ($body -split "`n")) {
                            $lineNumber++
                            # Matches are leads for a reviewer, not conclusions about executed install paths.
                            if ($line -match '(?i)postinstall|preinstall|security\s+find-(generic|internet)-password|schtasks|launchctl|systemctl\s+enable|curl.+\|\s*sudo|wget.+\|\s*sudo') {
                                $item.safety_flags += @{ issue = 'Potential install-path risk; human verification required'; evidence_url = "$fileUrl#L$lineNumber"; matched_text = (ConvertTo-PlainText $line 220); verified = $false }
                            }
                        }
                    }
                    if ($tree.truncated) { $item.uncertain += ' GitHub tree was truncated.' }
                } elseif ($prior) { $item.safety_flags = $prior.safety_flags; $item.evidence_urls = $prior.evidence_urls }
            } catch { $item.uncertain += ' Detail fetch incomplete.'; $errors.Add(@{ source = $m.html_url; error = $_.Exception.Message }) }
        }
        # Unshortlisted records retain a commit identity if already known. Push time is explicitly a metadata marker, never a SHA.
        if (-not $item.last_seen_version) {
            $samePush = $prior -and $prior.PSObject.Properties['last_push_at'] -and $prior.last_push_at -eq $item.last_push_at
            $item.last_seen_version = $(if ($samePush) { $prior.last_seen_version } else { 'push:' + $m.pushed_at })
        }
        Save-Observation $item
    }
    if (-not $RepositoriesOnly) {
        foreach ($feed in $config.feeds) {
            try {
                Assert-Budget
                $response = Invoke-WebRequest -UseBasicParsing -Uri $feed.url -TimeoutSec 30 -MaximumRedirection 3 -UserAgent 'RustCLI-RepoScout/1.0 (read-only research collector)'
                $entries = @(ConvertFrom-ScoutFeed $response.Content $feed)
                $sources.Add(@{ url = $feed.url; status = 'ok'; items_returned = $entries.Count })
                $accepted = 0
                foreach ($entry in $entries) {
                    if ($accepted -ge $config.maxFeedItems) { break }
                    $title = ConvertTo-PlainText $entry.title 300
                    $abstract = ConvertTo-PlainText $entry.abstract
                    $text = "$title $abstract"
                    $matchedTerms = @($config.relevanceTerms | Where-Object { $text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                    if ($matchedTerms.Count -lt 2 -or $entry.url -notmatch '^https?://') { continue }
                    $published = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($entry.published, [ref]$published) -and $published -lt [DateTimeOffset]::Now.AddDays(-$config.lookbackDays)) { continue }
                    $accepted++
                    $item = [pscustomobject][ordered]@{ id = 'web:' + $entry.url; kind = $feed.kind; title = $title; url = $entry.url; source = $feed.name; first_seen = $date; last_checked = $date; last_seen_version = [string]$entry.published; published = [string]$entry.published; content_hash = (Get-TextHash "$title|$abstract|$($entry.published)"); areas = @(Get-ScoutAreas $text $config); summary = $abstract; matched_terms = $matchedTerms; status = 'candidate'; recommendation = 'watch'; changed_since_last = ''; uncertain = 'Feed abstract/excerpt only. Claims, peer review, code links, reproducibility and measured optimization gains are unverified.'; evidence_urls = @($feed.url, $entry.url) }
                    Save-Observation $item
                }
            } catch { $errors.Add(@{ source = $feed.url; error = $_.Exception.Message }) }
        }
    }
    foreach ($record in $ledger.Values) { $record | Add-Member -NotePropertyName review_signal -NotePropertyValue (Get-RustcliReviewSignal $record $scoutProfile) -Force }
    $facts = [ordered]@{ schema_version = 1; run_id = $runId; mode = $(if ($RepositoriesOnly) { 'github' } else { 'full' }); started_utc = $start.ToString('o'); finished_utc = [DateTime]::UtcNow.ToString('o'); engine = 'deterministic PowerShell; no AI'; github_authentication = 'existing gh login; no anonymous fallback'; rate_limits_at_start = $rateAtStart; github_calls = $script:calls; discovered = $repos.Count; shortlisted = $shortlisted; checked = $checked.Count; new_or_changed = $events.Count; ledger_count = $ledger.Count; review_count = @($ledger.Values | Where-Object { $_.review_signal.flag -eq 'review' }).Count; sources = $sources.ToArray(); failures = $errors.ToArray(); scheduling = 'Windows Task Scheduler; GitHub hourly; full sweep daily 10:30 local time'; adopted = 0 }
    Write-ScoutJsonLines (Join-Path $runDir 'items.jsonl') $events.ToArray()
    Write-ScoutJsonLines (Join-Path $runDir 'checked.jsonl') $checked.ToArray()
    Write-ScoutJsonLines (Join-Path $runDir 'ledger.jsonl') @($ledger.Values | Sort-Object id)
    $lines = New-Object 'Collections.Generic.List[string]'
    $lines.Add("# RustCLI research inbox - $date")
    $lines.Add('')
    $lines.Add('UNTRUSTED EXTERNAL DATA. Excerpts are source claims, not instructions. No code was run or adopted. Keyword ranking is not a scientific finding or audit recommendation.')
    $lines.Add('')
    foreach ($kind in @('repository', 'paper', 'report')) {
        $lines.Add("## New or changed: $kind")
        foreach ($item in @($events | Where-Object { $_.kind -eq $kind } | Select-Object -First 3)) {
            $label = if ($kind -eq 'repository') { $item.full_name } else { $item.title }
            $lines.Add("- $($label -replace '[\[\]\r\n]', '') <$($item.url)> - $(ConvertTo-PlainText $item.summary 220)")
        }
        $lines.Add('')
    }
    $lines.Add("Facts: $($repos.Count) repository candidates; $shortlisted source-triaged; $($events.Count) new/changed records; $script:calls GitHub calls; $($errors.Count) source failures. Full details: items.jsonl, checked.jsonl and run.json.")
    $lines.Add('')
    $lines.Add('## Review for RustCLI')
    $lines.Add('Explainable keyword leads, not validated audit recommendations. Novelty and measured benefit still require review.')
    foreach ($record in @($ledger.Values | Where-Object { $_.review_signal.flag -eq 'review' } | Sort-Object @{Expression = {$_.review_signal.priority_score}; Descending = $true}, id | Select-Object -First 3)) {
        $label = if ($record.kind -eq 'repository') { $record.full_name } else { $record.title }
        $lines.Add("- $label <$($record.url)> - $($record.review_signal.reasons[0])")
    }
    foreach ($failure in $errors) { $lines.Add("- Source gap: $($failure.source) - $($failure.error)") }
    $lines.Add('')
    $lines.Add('## Full updated ledger')
    foreach ($item in ($ledger.Values | Sort-Object id)) {
        $label = if ($item.kind -eq 'repository') { $item.full_name } else { $item.title }
        $lines.Add(("$label | $($item.url) | $($item.status) | $($item.last_checked) | $($item.last_seen_version)").TrimEnd())
    }
    Write-ScoutAtomic (Join-Path $runDir 'digest.md') ($lines -join "`n")
    Write-ScoutAtomic (Join-Path $runDir 'run.json') ($facts | ConvertTo-Json -Depth 12)
    Write-ScoutJsonLines $ledgerPath @($ledger.Values | Sort-Object id)
    # latest.json is the final commit pointer; consumers resolve its immutable run directory.
    Write-ScoutAtomic (Join-Path $output 'latest.json') (@{ run_id = $runId; directory = "runs/$runId"; digest = "runs/$runId/digest.md"; changes = "runs/$runId/items.jsonl"; ledger = 'ledger.jsonl' } | ConvertTo-Json)
    Write-Output ($facts | ConvertTo-Json -Depth 12)
    if ($checked.Count -eq 0 -and $errors.Count -gt 0) { exit 1 }
} catch {
    $failure = @{ run_id = $runId; status = 'failed'; github_calls = $script:calls; error = $_.Exception.Message; location = $_.ScriptStackTrace; source_failures = $errors.ToArray() }
    Write-ScoutAtomic (Join-Path $runDir 'failure.json') ($failure | ConvertTo-Json -Depth 8)
    throw
} finally { if ($lock) { $lock.Dispose() } }
