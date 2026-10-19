Set-StrictMode -Version Latest
function Get-ProfileValue($Item, [string]$Name, $Default = '') {
    if ($Item -is [Collections.IDictionary] -and $Item.Contains($Name)) { return $Item[$Name] }
    if ($null -ne $Item -and $Item.PSObject.Properties[$Name]) { return $Item.$Name }
    return $Default
}
function Get-RustcliReviewSignal($Item, $RustcliProfile) {
    $kind = Get-ProfileValue $Item 'kind'
    $name = Get-ProfileValue $Item 'full_name'
    $excluded = $kind -eq 'exclusion' -or (Get-ProfileValue $Item 'status') -in @('unsafe', 'skip')
    $signal = [ordered]@{ flag = 'fyi'; priority_score = 0; rules_version = $RustcliProfile.version; reasons = @(); matches = @(); upstream_watch = $RustcliProfile.priorityRepositories -contains $name; source_changed = [bool](Get-ProfileValue $Item 'source_changed' $false); release_changed = [bool](Get-ProfileValue $Item 'release_changed' $false); novelty = 'unverified'; requires_owner_approval = $true }
    if ($excluded) { $signal.flag = 'excluded'; $signal.reasons = @('Owner exclusion or repository activity filter. Not a review recommendation.'); return [pscustomobject]$signal }
    $hasUpdate = $signal.source_changed -or $signal.release_changed
    $segments = @(@{text=([string](Get-ProfileValue $Item 'full_name') + ' ' + [string](Get-ProfileValue $Item 'title') + ' ' + [string](Get-ProfileValue $Item 'summary'));url=(Get-ProfileValue $Item 'url');field='title/summary'})
    foreach ($releaseField in @('release', 'stable_release')) {
        $release = Get-ProfileValue $Item $releaseField $null
        if ($release) { $segments += @{text=[string](Get-ProfileValue $release 'notes');url=(Get-ProfileValue $release 'url');field=$releaseField} }
    }
    foreach ($change in @(Get-ProfileValue $Item 'recent_changes' @())) { $segments += @{text=[string]$change.message;url=$change.url;field='commit'} }
    if ($signal.upstream_watch) {
        if ($hasUpdate) {
            $changedFields = @(Get-ProfileValue $Item 'release_changed_fields' @())
            $segments = @($segments | Where-Object { $_.field -eq 'commit' -or ($signal.release_changed -and ($changedFields -contains $_.field -or (-not $changedFields.Count -and $_.field -in @('release','stable_release')))) })
        } else { $segments = @() }
    }
    foreach ($rule in $RustcliProfile.rules) {
        if ($rule.id -eq 'native-compatibility' -and -not $signal.upstream_watch) { continue }
        foreach ($segment in $segments) {
            $match = [regex]::Match($segment.text, $rule.pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds(100))
            if ($match.Success) {
                $signal.priority_score += [int]$rule.weight
                $signal.matches += [pscustomobject]@{ id = $rule.id; name = $rule.name; rustcli_component = $rule.component; matched_text = $match.Value; evidence_url = $segment.url; evidence_field=$segment.field }
                $signal.reasons += "$($rule.name) -> $($rule.component)"
                break
            }
        }
    }
    $alreadyReviewed = $RustcliProfile.previouslyReviewed -contains $name
    if ($signal.priority_score -ge $RustcliProfile.reviewThreshold -and (-not $alreadyReviewed -or $hasUpdate)) { $signal.flag = 'review' }
    if ($signal.upstream_watch) {
        if ($hasUpdate -and $signal.priority_score -ge $RustcliProfile.reviewThreshold) { $signal.reasons = @('Tracked harness changed; check adapter compatibility and the relevant release notes.') + $signal.reasons }
        elseif (-not $hasUpdate) { $signal.reasons = @('Priority harness watch. No new version change established in this observation.') + $signal.reasons }
    }
    if ($alreadyReviewed -and -not $hasUpdate) { $signal.reasons = @('Previously reviewed. No major change is established by this baseline; kept out of the Review queue.') + $signal.reasons }
    if (-not $signal.reasons.Count) { $signal.reasons = @('General discovery lead. No specific RustCLI improvement rule matched; existing worktrees, memory and orchestration alone do not trigger Review.') }
    return [pscustomobject]$signal
}
Export-ModuleMember -Function Get-RustcliReviewSignal
