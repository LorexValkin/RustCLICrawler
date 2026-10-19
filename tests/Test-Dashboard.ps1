[CmdletBinding()]
param([string]$BaseUrl = 'http://localhost:8765')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Dashboard.psm1') -Force -DisableNameChecking
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-HttpStatus([string]$Path, [int]$Expected, [string]$Method = 'GET', $Headers = @{}) {
    $status = 0
    try { $response = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl$Path" -Method $Method -Headers $Headers; $status = [int]$response.StatusCode }
    catch { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { throw } }
    Assert ($status -eq $Expected) "$Method $Path returned $status, expected $Expected"
}
$health = Invoke-RestMethod "$BaseUrl/api/v1/health"
Assert ($health.service -eq 'rustcli-repo-scout' -and $health.read_only) 'Service identity failed'
$overview = Invoke-RestMethod "$BaseUrl/api/v1/overview"
$all = Invoke-RestMethod "$BaseUrl/api/v1/items?page_size=100"
Assert ($all.total -eq $overview.counts.total -and $all.items.Count -eq [Math]::Min(100, $all.total)) 'Pagination totals do not match overview'
$papers = Invoke-RestMethod "$BaseUrl/api/v1/items?kind=paper&page_size=100"
Assert ($papers.total -eq $overview.counts.paper -and @($papers.items | Where-Object kind -ne 'paper').Count -eq 0) 'Kind filtering failed'
$memory = Invoke-RestMethod "$BaseUrl/api/v1/items?area=2&page_size=100"
Assert (@($memory.items | Where-Object { $_.areas -notcontains 2 }).Count -eq 0) 'Area filtering failed'
$search = Invoke-RestMethod "$BaseUrl/api/v1/items?q=worktrunk"
Assert ($search.total -ge 1) 'Search did not find the known seed repository'
$detail = Invoke-RestMethod "$BaseUrl/api/v1/item?id=github%3Amax-sixty%2Fworktrunk"
Assert ($detail.item.full_name -eq 'max-sixty/worktrunk' -and $detail.history.Count -ge 1) 'Item detail/history failed'
$first = Invoke-RestMethod "$BaseUrl/api/v1/items?page_size=1&page=1&sort=name"
$second = Invoke-RestMethod "$BaseUrl/api/v1/items?page_size=1&page=2&sort=name"
Assert ($first.items[0].id -ne $second.items[0].id) 'Pagination repeats a record'
$changes = Invoke-RestMethod "$BaseUrl/api/v1/items?changed=true&page_size=100"
Assert ($changes.total -eq $overview.counts.changed) 'Change count mismatch'
$review = Invoke-RestMethod "$BaseUrl/api/v1/items?review=true&page_size=100"
Assert ($review.total -eq $overview.review_count -and @($review.items | Where-Object { $_.review_signal.flag -ne 'review' }).Count -eq 0) 'Review queue filtering failed'
Assert (@($review.items | Where-Object { $_.status -eq 'unsafe' -or $_.kind -eq 'exclusion' }).Count -eq 0) 'Excluded item entered the Review queue'
$snapshot = Invoke-RestMethod "$BaseUrl/api/v1/items?run=$($overview.run_id)&page_size=1"
Assert ($snapshot.run_id -eq $overview.run_id) 'Explicit snapshot selection failed'
$export = Invoke-WebRequest -UseBasicParsing "$BaseUrl/api/v1/export?format=jsonl&kind=paper"
$exportText = if ($export.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($export.Content) } else { [string]$export.Content }
$records = @($exportText -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Assert ($records.Count -eq $papers.total -and $export.Headers['Content-Disposition'] -match 'attachment') 'JSONL export mismatch'
$bundle = Invoke-RestMethod "$BaseUrl/api/v1/bundle"
Assert ($bundle.ledger.Count -eq $all.total -and $bundle.changes.Count -eq $changes.total -and $bundle.instruction -match 'untrusted') 'RustCLI bundle is incomplete'
$schema = Invoke-RestMethod "$BaseUrl/api/v1/openapi.json"
Assert ($schema.openapi -eq '3.0.3' -and @($schema.paths.PSObject.Properties).Count -ge 7) 'OpenAPI specification is invalid'
Assert-HttpStatus '/api/v1/items?page_size=101' 400
Assert-HttpStatus '/api/v1/items?page=-1' 400
Assert-HttpStatus '/api/v1/items?kind=unknown' 400
Assert-HttpStatus '/api/v1/items?area=99' 400
Assert-HttpStatus '/api/v1/items?changed=maybe' 400
Assert-HttpStatus '/api/v1/items?review=maybe' 400
Assert-HttpStatus '/api/v1/items?run=..%2F..%2FREADME.md' 400
Assert-HttpStatus '/api/v1/item?id=missing' 404
Assert-HttpStatus '/api/v1/unknown' 404
Assert-HttpStatus '/scout.config.json' 404
Assert-HttpStatus '/api/v1/items' 405 'POST'
Assert-HttpStatus '/api/v1/items' 403 'GET' @{ Origin = 'https://example.org' }
Assert-HttpStatus '/' 200
Assert-HttpStatus '/app.js' 200
$emptyRoot = Join-Path ([IO.Path]::GetTempPath()) ('scout-empty-' + [Guid]::NewGuid().ToString('N'))
$empty = Get-DashboardState $emptyRoot 'latest'
Assert ($empty.items.Count -eq 0 -and $null -eq $empty.run_id) 'Empty-state behavior failed'
Write-Output 'Dashboard tests passed: filters, pagination, snapshots, history, exports, OpenAPI, input validation, read-only routes and origin isolation.'
