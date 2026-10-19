$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../scripts/Scout.psm1') -Force -DisableNameChecking
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$config = Get-Content (Join-Path $PSScriptRoot '../scout.config.json') -Raw | ConvertFrom-Json
$feed = [pscustomobject]@{ format = 'xml' }
$atom = '<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Agent evaluation</title><link href="https://example.org/paper" rel="alternate"/><published>2026-10-19T00:00:00Z</published><summary>Sandbox benchmark</summary></entry></feed>'
$parsed = @(ConvertFrom-ScoutFeed $atom $feed)
Assert ($parsed.Count -eq 1 -and $parsed[0].url -eq 'https://example.org/paper') 'Atom link parsing failed'
$rss = '<rss><channel><item><title>Agent coding</title><link>https://example.org/news</link><description>Memory</description><pubDate>Mon, 19 Oct 2026 10:00:00 GMT</pubDate></item></channel></rss>'
Assert (@(ConvertFrom-ScoutFeed $rss $feed).Count -eq 1) 'RSS parsing failed'
$hf = '[{"paper":{"id":"2610.12345","title":"Agent evaluation","publishedAt":"2026-10-19","summary":"Memory benchmark"}},{"paper":{"id":"2610.12346","title":"Agent skills","publishedAt":"2026-10-19","summary":"Coding efficiency"}}]'
$hfItems = @(ConvertFrom-ScoutFeed $hf ([pscustomobject]@{format='huggingface'}))
Assert ($hfItems.Count -eq 2 -and $hfItems[0].url -eq 'https://huggingface.co/papers/2610.12345') 'Hugging Face array merged independent papers'
$blocked = $false
try { ConvertFrom-ScoutFeed '<!DOCTYPE x [<!ENTITY e SYSTEM "file:///C:/Windows/win.ini">]><rss>&e;</rss>' $feed | Out-Null } catch { $blocked = $true }
Assert $blocked 'XML DTD was not blocked'
$areas = @(Get-ScoutAreas 'Rust worktree benchmark memory encrypted relay' $config)
Assert (($areas -contains 2) -and ($areas -contains 3) -and ($areas -contains 5) -and ($areas -contains 7) -and ($areas -contains 8)) 'Area tagging failed'
Assert ((ConvertTo-PlainText '<b>hello</b> &amp; world') -eq 'hello & world') 'Excerpt cleanup failed'
$one = [pscustomobject]@{ id = 'github:test/repo'; kind = 'repository'; last_seen_version = 'abc'; stars = 1 }
$two = [pscustomobject]@{ id = 'github:test/repo'; kind = 'repository'; last_seen_version = 'abc'; stars = 2 }
Assert ((Get-ScoutFingerprint $one) -eq (Get-ScoutFingerprint $two)) 'Star-only changes should not duplicate source events'
Assert ((Get-TextHash 'one') -ne (Get-TextHash 'two')) 'Content hashing failed'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('repo-scout-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($folder) | Out-Null
try {
    $path = Join-Path $folder 'ledger.jsonl'
    Write-ScoutJsonLines $path @($one)
    Assert ((Read-ScoutLedger $path).Count -eq 1) 'Ledger roundtrip failed'
    Write-ScoutJsonLines $path @($two)
    Assert ((Read-ScoutLedger $path)['github:test/repo'].stars -eq 2) 'Atomic replacement failed'
    Write-ScoutJsonLines $path @($one, $one)
    $blocked = $false
    try { Read-ScoutLedger $path | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Duplicate ledger identities accepted'
    $config.outputDirectory = Join-Path $folder 'output'
    $config.seedRepositories = @('example/scout')
    $config.previouslyReviewed = @()
    $config.repositoryQueries = @()
    $config.maxCandidates = 2
    $config.maxDetailedRepositories = 1
    $fixture = @{
        'rate_limit' = @{ resources = @{ core = @{limit = 5000; remaining = 4900}; search = @{limit = 30; remaining = 30} } }
        'repos/example/scout' = @{ full_name = 'example/scout'; name = 'scout'; html_url = 'https://github.com/example/scout'; private = $false; archived = $false; fork = $false; pushed_at = [DateTime]::UtcNow.ToString('o'); description = 'Rust coding agent benchmark'; topics = @('agent'); license = @{spdx_id = 'MIT'}; stargazers_count = 10 }
        'repos/example/scout/commits?per_page=1' = @(@{sha = 'commit-one'})
        'repos/example/scout/releases?per_page=3' = @()
        'repos/example/scout/contributors?per_page=100&anon=true' = @(@{login = 'test'})
        'repos/example/scout/git/trees/commit-one?recursive=1' = @{ tree = @(); truncated = $false }
    }
    $configFile = Join-Path $folder 'config.json'
    $fixtureFile = Join-Path $folder 'fixtures.json'
    Write-ScoutAtomic $configFile ($config | ConvertTo-Json -Depth 10)
    Write-ScoutAtomic $fixtureFile ($fixture | ConvertTo-Json -Depth 10)
    $runner = Join-Path $PSScriptRoot '../scripts/Run-RepoScout.ps1'
    & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    $output = $config.outputDirectory
    $pointer = Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json
    $first = Get-Content (Join-Path $output ($pointer.directory + '/run.json')) -Raw | ConvertFrom-Json
    Assert ($first.new_or_changed -eq 1) 'First run did not emit one repository'
    & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    $pointer = Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json
    $second = Get-Content (Join-Path $output ($pointer.directory + '/run.json')) -Raw | ConvertFrom-Json
    Assert ($second.new_or_changed -eq 0 -and $second.ledger_count -eq 2) 'Repeated run duplicated unchanged records or lost owner exclusion'
    $fixture['repos/example/scout/commits?per_page=1'][0].sha = 'commit-two'
    $fixture['repos/example/scout/git/trees/commit-two?recursive=1'] = @{tree = @(); truncated = $false}
    Write-ScoutAtomic $fixtureFile ($fixture | ConvertTo-Json -Depth 10)
    & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    $pointer = Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json
    $third = Get-Content (Join-Path $output ($pointer.directory + '/run.json')) -Raw | ConvertFrom-Json
    Assert ($third.new_or_changed -eq 1) 'Source commit update was not emitted'
    # Exercise the same fresh, noninteractive PowerShell process used by Task Scheduler.
    $nativeShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    & $nativeShell -NoLogo -NoProfile -NonInteractive -File $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Fresh scheduler-style process failed'
    $fixture['repos/example/scout/releases?per_page=3'] = @(@{tag_name='v1';published_at='2026-10-19T00:00:00Z';html_url='https://example.org/v1';body='Initial release'})
    Write-ScoutAtomic $fixtureFile ($fixture | ConvertTo-Json -Depth 10)
    & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    $fixture['repos/example/scout/releases?per_page=3'][0].body = 'Prompt caching reduces token cost'
    Write-ScoutAtomic $fixtureFile ($fixture | ConvertTo-Json -Depth 10)
    & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null
    $releasePointer = Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json
    $releaseEvents = @(Get-Content (Join-Path $output $releasePointer.changes) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($releaseEvents.Count -eq 1 -and $releaseEvents[0].release_changed -and $releaseEvents[0].review_signal.flag -eq 'review') ('Release-note-only change was not emitted as a relevant update: ' + (ConvertTo-Json -InputObject $releaseEvents -Depth 8 -Compress))
    $publishedBeforeFailure = (Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json).run_id
    $fixture['rate_limit'].resources.core.limit = 60
    Write-ScoutAtomic $fixtureFile ($fixture | ConvertTo-Json -Depth 10)
    $blocked = $false
    try { & $runner -ConfigPath $configFile -OfflineFixturePath $fixtureFile -RepositoriesOnly | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Unauthenticated quota accepted'
    $afterFailure = Get-Content (Join-Path $output 'latest.json') -Raw | ConvertFrom-Json
    Assert ($afterFailure.run_id -eq $publishedBeforeFailure) 'Failure changed published pointer'
} finally {
    # Validate the absolute target before recursively removing this test's temporary data.
    $resolved = [IO.Path]::GetFullPath($folder)
    $allowedPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'repo-scout-test-'
    if (-not $resolved.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside test directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'Scout tests passed (Atom/RSS, XML security, tagging, atomic ledger, full-run deduplication and commit changes).'
