Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Relevance.psm1') -Force
$scoutProfile = Get-Content (Join-Path $PSScriptRoot '../rustcli.profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Record([string]$Summary, [string]$Name = 'example/project') { return [pscustomobject]@{kind='repository'; full_name=$Name; summary=$Summary; url="https://github.com/$Name"; status='candidate'; source_changed=$false;release_changed=$false} }
$basic = Get-RustcliReviewSignal (Record 'Multi-agent orchestration with memory and worktrees') $scoutProfile
Assert ($basic.flag -eq 'fyi') 'Existing RustCLI capabilities alone triggered Review'
$efficiency = Get-RustcliReviewSignal (Record 'Reduce token usage with prompt caching and context compaction') $scoutProfile
Assert ($efficiency.flag -eq 'review' -and $efficiency.matches.Count -ge 2) 'Efficiency lead was not identified'
$skills = Get-RustcliReviewSignal (Record 'Custom skills for code review and verification') $scoutProfile
Assert ($skills.flag -eq 'review') 'Review skill lead was not identified'
$multi = Get-RustcliReviewSignal (Record 'Multi-agent coordination benchmarks and skill evaluation') $scoutProfile
Assert ($multi.flag -eq 'review') 'Multi-agent improvements were not identified'
$judge = Get-RustcliReviewSignal (Record 'Judge calibration with paired evaluation and held-out tests') $scoutProfile
Assert ($judge.flag -eq 'review' -and $judge.matches[0].rustcli_component) 'Judge calibration lead missing component mapping'
$hermes = Record 'Context compaction and agent skills' 'NousResearch/hermes-agent'
Assert ((Get-RustcliReviewSignal $hermes $scoutProfile).flag -eq 'fyi') 'Known reviewed baseline was re-recommended'
$hermes.release_changed = $true
$hermes | Add-Member -NotePropertyName release -NotePropertyValue @{notes='Context compaction and agent skills';url='https://example.org/hermes-release'}
Assert ((Get-RustcliReviewSignal $hermes $scoutProfile).flag -eq 'review') 'Relevant tracked harness release was suppressed'
$bad = Record 'Prompt caching and agent skills'
$bad.status = 'unsafe'
Assert ((Get-RustcliReviewSignal $bad $scoutProfile).flag -eq 'excluded') 'Unsafe project entered Review queue'
$paper = [pscustomobject]@{kind='paper';title='Allocating test-time compute under imperfect verifiers';summary='Controlled comparisons';status='candidate';url='https://arxiv.org/abs/example'}
Assert ((Get-RustcliReviewSignal $paper $scoutProfile).flag -eq 'review') 'Efficiency paper was not flagged'
$commitLead = Record 'Generic agent harness' 'openai/codex'
$commitLead | Add-Member -NotePropertyName recent_changes -NotePropertyValue @([pscustomobject]@{message='Add Windows sandbox isolation';url='https://github.com/openai/codex/commit/example'})
$commitLead.source_changed = $true
$commitSignal = Get-RustcliReviewSignal $commitLead $scoutProfile
Assert ($commitSignal.flag -eq 'review' -and $commitSignal.matches[0].evidence_field -eq 'commit') 'Relevant upstream commit did not preserve its evidence'
$unrelated = Record 'Agent skills and prompt caching' 'NousResearch/hermes-agent'
$unrelated.source_changed = $true
$unrelated | Add-Member -NotePropertyName stable_release -NotePropertyValue @{notes='Prompt caching';url='https://example.org/old-release'}
$unrelated | Add-Member -NotePropertyName recent_changes -NotePropertyValue @([pscustomobject]@{message='Correct a documentation typo';url='https://example.org/typo'})
Assert ((Get-RustcliReviewSignal $unrelated $scoutProfile).flag -eq 'fyi') 'Unchanged historical release notes promoted an unrelated upstream commit'
Write-Output 'Relevance tests passed: overlap suppression, efficiencies, skills, multi-agent improvements, upstream updates, exclusions and research papers.'
