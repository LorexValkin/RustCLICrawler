Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PlainText([string]$Text, [int]$Limit = 1600) {
    $value = [System.Net.WebUtility]::HtmlDecode(($Text -replace '<[^>]*>', ' '))
    $value = ($value -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '' -replace '\s+', ' ').Trim()
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit).TrimEnd() }
    return $value
}

function Get-ScoutAreas([string]$Text, $Config) {
    $areas = @()
    foreach ($property in $Config.areaTerms.PSObject.Properties) {
        foreach ($term in $property.Value) {
            if ($Text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $areas += [int]$property.Name
                break
            }
        }
    }
    return $areas
}

function Get-ScoutFingerprint($Item) {
    # Only substantive source changes create a new event. Stars remain in daily snapshots.
    $version = if ($Item.kind -eq 'repository') { $Item.last_seen_version } else { $Item.content_hash }
    return "$($Item.id)|$version"
}

function Get-TextHash([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Read-ScoutLedger([string]$Path) {
    $ledger = @{}
    if (Test-Path -LiteralPath $Path) {
        $reader = [IO.File]::OpenText($Path)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $item = $line | ConvertFrom-Json
                    if ($ledger.ContainsKey($item.id)) { throw "Duplicate ledger identity: $($item.id)" }
                    $ledger[$item.id] = $item
                }
            }
        } finally { $reader.Dispose() }
    }
    return $ledger
}

function Write-ScoutJsonLines([string]$Path, [object[]]$Items) {
    $lines = @($Items | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 18 -Compress })
    Write-ScoutAtomic $Path (($lines -join "`n") + $(if ($lines.Count) { "`n" } else { '' }))
}

function Write-ScoutAtomic([string]$Path, [string]$Text) {
    $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path) {
            $backup = "$Path.$([Guid]::NewGuid().ToString('N')).bak"
            try { [IO.File]::Replace($temp, $Path, $backup) }
            finally { if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup } }
        }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function ConvertFrom-ScoutFeed([string]$Content, $Feed) {
    $items = @()
    if ($Feed.format -eq 'huggingface') {
        $parsed = $Content | ConvertFrom-Json
        foreach ($entry in $parsed) {
            $p = $entry.paper
            $items += [pscustomobject]@{ title = [string]$p.title; url = "https://huggingface.co/papers/$($p.id)"; published = [string]$p.publishedAt; abstract = [string]$p.summary }
        }
    } else {
        # Disable DTD resolution; fetched XML is untrusted and must not read local files.
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($Content)), $settings)
        $xml = New-Object Xml.XmlDocument
        $xml.XmlResolver = $null
        try { $xml.Load($reader) } finally { $reader.Dispose() }
        foreach ($entry in $xml.SelectNodes("//*[local-name()='entry' or local-name()='item']")) {
            $titleNode = $entry.SelectSingleNode("*[local-name()='title']")
            $linkNode = $entry.SelectSingleNode("*[local-name()='link'][@rel='alternate']")
            if (-not $linkNode) { $linkNode = $entry.SelectSingleNode("*[local-name()='link'][not(@rel)]") }
            if (-not $titleNode -or -not $linkNode) { continue }
            $url = if ($linkNode.HasAttribute('href')) { $linkNode.GetAttribute('href') } else { $linkNode.InnerText }
            $dateNode = $entry.SelectSingleNode("*[local-name()='updated' or local-name()='pubDate' or local-name()='published']")
            $bodyNode = $entry.SelectSingleNode("*[local-name()='summary' or local-name()='description' or local-name()='content']")
            $items += [pscustomobject]@{ title = $titleNode.InnerText; url = $url; published = $(if ($dateNode) { $dateNode.InnerText } else { '' }); abstract = $(if ($bodyNode) { $bodyNode.InnerText } else { '' }) }
        }
    }
    return $items
}

Export-ModuleMember -Function *
