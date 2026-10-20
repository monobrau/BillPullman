#Requires -Version 5.1
<#
.SYNOPSIS
    Local web app for searching, exporting, and deleting Microsoft 365 mail.

.DESCRIPTION
    Serves http://127.0.0.1:8780/ on this machine. Sign-in prompts appear here.
    Nothing is stored except local settings, job files, and downloaded mail.

.EXAMPLE
    .\Start-Puller.ps1
    .\Start-Puller.ps1 -Port 8780 -NoBrowser
#>
param(
    [int]$Port = 8780,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:Www = Join-Path $script:Root 'www'
$script:JobsDir = Join-Path $script:Root 'jobs'
$script:SettingsPath = Join-Path $script:Root 'config\settings.json'
$script:Session = $null
Import-Module (Join-Path $script:Root 'Modules\SearchJobs.psm1') -Force
Import-Module (Join-Path $script:Root 'Modules\Notify.psm1') -Force

function Read-PullerBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Write-PullerJson {
    param($Response, $Body, [int]$StatusCode = 200)
    $json = if ($null -eq $Body) { 'null' } else { $Body | ConvertTo-Json -Depth 10 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-PullerText {
    param($Response, [string]$Body, [string]$ContentType = 'text/plain; charset=utf-8', [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-PullerError {
    param($Response, [string]$Message, [int]$StatusCode = 400)
    Write-PullerJson $Response @{ error = $Message } $StatusCode
}

function Get-PullerSettingsObject {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        return Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $example = Join-Path $script:Root 'config\settings.example.json'
    return Get-Content -LiteralPath $example -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-PullerSettingsObject {
    param($Settings)
    $dir = Split-Path -Parent $script:SettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-PullerSessionView {
    $settings = Get-PullerSettingsObject
    $tier = 'standard'
    if ($script:Session) { $tier = [string]$script:Session.tier }
    $choices = Get-PullerEffectiveChoices -Settings $settings -Tier $tier
    return [pscustomobject]@{
        connected   = [bool]($script:Session -and $script:Session.connected)
        account     = $(if ($script:Session) { $script:Session.account } else { '' })
        tenantId    = $(if ($script:Session) { $script:Session.tenantId } else { '' })
        tier        = $choices.tier
        label       = $(if ($script:Session) { $script:Session.label } else { 'Not signed in' })
        probeStatus = $(if ($script:Session) { $script:Session.probeStatus } else { '' })
        choices     = $choices
        settings    = $settings
    }
}

function Get-PullerJobFile {
    param([string]$Id)
    $path = Join-Path $script:JobsDir ($Id + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-PullerJobFile {
    param($Job)
    if (-not (Test-Path -LiteralPath $script:JobsDir)) {
        New-Item -ItemType Directory -Path $script:JobsDir | Out-Null
    }
    $path = Join-Path $script:JobsDir ($Job.id + '.json')
    $Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-PullerJobList {
    if (-not (Test-Path -LiteralPath $script:JobsDir)) { return @() }
    $jobs = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $script:JobsDir -Filter *.json | Sort-Object LastWriteTime -Descending)) {
        $jobs += Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $jobs
}

function Add-PullerNotice {
    param($Job, [string]$Event)
    $settings = Merge-PullerSettings (Get-PullerSettingsObject)
    $already = @($Job.notices)
    if ($already -contains $Event) { return $Job }
    $body = @(
        "Tenant: $($Job.tenantId)",
        "Search: $($Job.name)",
        "Action: $Event",
        "Items: $($Job.items)",
        "Status: $($Job.status)"
    ) -join "`r`n"
    if ($Job.files) { $body += "`r`nFiles:`r`n" + ((@($Job.files) | ForEach-Object { [string]$_ }) -join "`r`n") }
    if ($Job.error) { $body += "`r`nError: $($Job.error)" }
    $null = Send-PullerNotice -Settings $settings -Title "Puller: $($Job.name) $Event" -Body $body
    $Job.notices = @($already + $Event)
    return $Job
}

function Update-PullerSearchProgress {
    param($Job)
    if ($Job.status -ne 'running' -or -not $Job.name) { return $Job }
    $status = Get-PullerComplianceStatus -Name $Job.name
    $Job.complianceStatus = $status.status
    $Job.items = $status.items
    $Job.size = $status.size
    $Job.results = @($status.results)
    if ($status.errors) { $Job.error = $status.errors }
    if ($status.status -eq 'Completed') {
        $Job.status = 'completed'
        $Job = Add-PullerNotice $Job 'search completed'
    }
    elseif ($status.status -match 'Failed|Stopped') {
        $Job.status = 'failed'
        $Job = Add-PullerNotice $Job 'search failed'
    }
    return $Job
}

function Step-PullerStandardExport {
    param($Job)
    $settings = Merge-PullerSettings (Get-PullerSettingsObject)
    $folder = Get-PullerDownloadFolder -Settings $settings -Root $script:Root
    $jobFolder = Join-Path $folder $Job.id
    if (-not (Test-Path -LiteralPath $jobFolder)) { New-Item -ItemType Directory -Path $jobFolder | Out-Null }
    if (-not $Job.work) {
        $mailboxes = @($Job.results | ForEach-Object { [string]$_.Location } | Where-Object { $_ -and $_ -notmatch '^(All|Public)' })
        if ($Job.mailboxMode -eq 'list') { $mailboxes = @($Job.mailboxes) }
        $Job.work = [pscustomobject]@{
            kind = 'standardPst'
            mailboxes = @($mailboxes)
            index = 0
            nextLink = ''
            saved = 0
            emlDir = (Join-Path $jobFolder 'eml')
            pstPath = (Join-Path $jobFolder ($Job.name + '.pst'))
            phase = 'download'
        }
        if (-not (Test-Path -LiteralPath $Job.work.emlDir)) {
            New-Item -ItemType Directory -Path $Job.work.emlDir | Out-Null
        }
    }
    $work = $Job.work
    if ($work.phase -eq 'download') {
        if ($work.index -ge @($work.mailboxes).Count) {
            $work.phase = 'pst'
        }
        else {
            $mailbox = [string]@($work.mailboxes)[$work.index]
            if ([int]$work.saved -ge [int]$settings.maxMessages) {
                $work.phase = 'pst'
                $Job.error = "Stopped at the $($settings.maxMessages) message setting. Raise maxMessages in Settings to continue."
            }
            else {
                $page = Get-PullerNextMessages -Mailbox $mailbox -GraphSearch $Job.graphSearch -NextLink $work.nextLink -Top 3
                foreach ($item in @($page.value)) {
                    if (-not $item.id) { continue }
                    $path = Save-PullerMessageMime -Mailbox $mailbox -MessageId ([string]$item.id) -Folder $work.emlDir
                    $Job.files = @(@($Job.files) + $path)
                    $work.saved = [int]$work.saved + 1
                }
                if ($page.nextLink) { $work.nextLink = $page.nextLink }
                else {
                    $work.index = [int]$work.index + 1
                    $work.nextLink = ''
                }
            }
        }
    }
    if ($work.phase -eq 'pst') {
        try {
            $pst = Add-PullerEmlFolderToPst -PstPath $work.pstPath -EmlFolder $work.emlDir
            $Job.files = @(@($Job.files) + $pst.PstPath)
            $Job.status = 'exported'
            $Job.detail = "PST imported $($pst.Imported); failed $($pst.Failed)."
        }
        catch {
            $Job.status = 'exported'
            $Job.error = $_.Exception.Message
            $Job.detail = 'EML files were saved. The PST was not built.'
        }
        $Job = Add-PullerNotice $Job 'export finished'
        $work.phase = 'done'
    }
    $Job.work = $work
    return $Job
}

function Step-PullerPurviewExport {
    param($Job)
    if (-not $Job.graphCaseId) {
        $all = ($Job.mailboxMode -ne 'list')
        $created = New-PullerPurviewCase -DisplayName $Job.name -Query $Job.query -AllMailboxes $all -MailboxList @($Job.mailboxes) -PublicFolders ([bool]$Job.locations.publicFolders)
        $Job.graphCaseId = $created.caseId
        $Job.graphSearchId = $created.searchId
        if ($created.publicFoldersRequested) {
            $Job.detail = 'Public folders were requested. If the case API ignores them, include them from the Purview case before you rely on the PST.'
        }
        $reportOnly = ($Job.action -eq 'csv' -and $Job.choices.defaultCsv -eq 'purviewReport')
        $started = Start-PullerPurviewExport -CaseId $Job.graphCaseId -SearchId $Job.graphSearchId -DisplayName $Job.name -ReportOnly $reportOnly
        $Job.work = [pscustomobject]@{ kind = 'purview'; operation = $started; phase = 'poll' }
        $Job.detail = 'Purview export started. This page will keep checking it.'
        return $Job
    }
    $opId = ''
    if ($Job.work -and $Job.work.operation -and $Job.work.operation.id) { $opId = [string]$Job.work.operation.id }
    if (-not $opId) {
        $Job.status = 'failed'
        $Job.error = 'Purview did not return an operation id.'
        return (Add-PullerNotice $Job 'export failed')
    }
    $op = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$($Job.graphCaseId)/operations/$opId" -Headers @{ Prefer = 'include-unknown-enum-members' }
    $Job.work.operation = $op
    $state = [string]$op.status
    if ($state -match 'succeeded') {
        $settings = Merge-PullerSettings (Get-PullerSettingsObject)
        $folder = Join-Path (Get-PullerDownloadFolder -Settings $settings -Root $script:Root) $Job.id
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
        $token = Get-PullerGraphToken
        $meta = @($op.exportFileMetadata)
        if ($meta.Count -eq 0 -and $op.additionalProperties) { $meta = @($op.additionalProperties.exportFileMetadata) }
        foreach ($file in $meta) {
            $url = [string]$file.downloadUrl
            $name = [string]$file.fileName
            if (-not $url -or -not $name) { continue }
            $dest = Join-Path $folder $name
            if (-not $token) { throw 'The Purview download needs the Graph access token, and this session did not expose it.' }
            $headers = @{ Authorization = "Bearer $token"; 'X-AllowWithAADToken' = 'true' }
            Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -UseBasicParsing
            $Job.files = @(@($Job.files) + $dest)
        }
        $Job.status = 'exported'
        $Job = Add-PullerNotice $Job 'export finished'
    }
    elseif ($state -match 'failed') {
        $Job.status = 'failed'
        $Job.error = [string]$op.resultInfo
        $Job = Add-PullerNotice $Job 'export failed'
    }
    return $Job
}

function Update-PullerActiveJob {
    param($Job)
    try {
        if ($Job.status -eq 'running') { return (Update-PullerSearchProgress $Job) }
        if ($Job.status -eq 'exporting' -and $Job.action -eq 'standardPst') { return (Step-PullerStandardExport $Job) }
        if ($Job.status -eq 'exporting' -and $Job.action -in @('purviewPst', 'purviewReport')) { return (Step-PullerPurviewExport $Job) }
    }
    catch {
        $Job.status = 'failed'
        $Job.error = $_.Exception.Message
        $Job = Add-PullerNotice $Job 'job failed'
    }
    return $Job
}

function New-PullerJobFromRequest {
    param($Body)
    $tier = 'standard'
    if ($script:Session) { $tier = [string]$script:Session.tier }
    $choices = Get-PullerEffectiveChoices -Settings (Get-PullerSettingsObject) -Tier $tier
    $locations = [pscustomobject]@{
        mailboxes = [bool]$choices.locations.mailboxes
        publicFolders = [bool]$choices.locations.publicFolders
        teams = [bool]$choices.locations.teams
    }
    if ($Body.locations) {
        $locations.mailboxes = [bool]$Body.locations.mailboxes
        $locations.publicFolders = [bool]$Body.locations.publicFolders
        $locations.teams = [bool]$Body.locations.teams
        if (-not $choices.allowed.teams) { $locations.teams = $false }
    }
    $query = Build-PullerComplianceQuery -Sender ([string]$Body.sender) -Subject ([string]$Body.subject) -MessageId ([string]$Body.messageId) -DateFrom ([string]$Body.dateFrom) -DateTo ([string]$Body.dateTo) -RawQuery ([string]$Body.rawQuery)
    $mode = 'all'
    if ([string]$Body.mailboxMode -eq 'list') { $mode = 'list' }
    $mailboxes = @()
    if ($Body.mailboxes) {
        $mailboxes = @(([string]$Body.mailboxes) -split '[,;\s]+' | Where-Object { $_ })
    }
    $name = New-PullerSearchName
    $null = New-PullerComplianceSearch -Name $name -Query $query -Mailboxes ([bool]$locations.mailboxes) -PublicFolders ([bool]$locations.publicFolders) -Teams ([bool]$locations.teams) -MailboxMode $mode -MailboxList $mailboxes
    return [pscustomobject]@{
        id = ([guid]::NewGuid().ToString('N'))
        name = $name
        created = (Get-Date).ToString('o')
        tenantId = $(if ($script:Session) { $script:Session.tenantId } else { '' })
        account = $(if ($script:Session) { $script:Session.account } else { '' })
        query = $query
        graphSearch = (Build-PullerGraphSearch $query)
        tier = $tier
        locations = $locations
        mailboxMode = $mode
        mailboxes = @($mailboxes)
        status = 'running'
        complianceStatus = 'Starting'
        items = 0
        size = 0
        results = @()
        preview = @()
        holds = @()
        files = @()
        notices = @()
        error = ''
        detail = ''
        action = ''
        choices = [pscustomobject]@{
            defaultExport = $(if ($Body.defaultExport) { [string]$Body.defaultExport } else { $choices.defaultExport })
            defaultCsv = $(if ($Body.defaultCsv) { [string]$Body.defaultCsv } else { $choices.defaultCsv })
            defaultPurge = $(if ($Body.defaultPurge) { [string]$Body.defaultPurge } else { $choices.defaultPurge })
        }
        work = $null
        graphCaseId = ''
        graphSearchId = ''
    }
}

function Get-PullerPreviewRows {
    param($Job)
    $mailboxes = @($Job.results | ForEach-Object { [string]$_.Location } | Where-Object { $_ -match '@' })
    if ($mailboxes.Count -eq 0) { $mailboxes = @($Job.mailboxes) }
    $rows = @()
    $limitBoxes = @($mailboxes | Select-Object -First 20)
    foreach ($mailbox in $limitBoxes) {
        if ($rows.Count -ge 100) { break }
        try {
            $rows += @(Get-PullerMailboxPreview -Mailbox $mailbox -GraphSearch $Job.graphSearch -Top 5)
        }
        catch {
            $rows += [pscustomobject]@{
                mailbox = $mailbox
                sender = ''
                subject = 'Preview failed'
                received = ''
                messageId = ''
                graphId = ''
                error = $_.Exception.Message
            }
        }
    }
    return @($rows | Select-Object -First 100)
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Puller is listening on $prefix"
if (-not $NoBrowser) { Start-Process $prefix }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath.TrimEnd('/')
        if (-not $path) { $path = '/' }
        try {
            if ($request.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                $html = Get-Content -LiteralPath (Join-Path $script:Www 'index.html') -Raw -Encoding UTF8
                Write-PullerText $response $html 'text/html; charset=utf-8'
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/session') {
                Write-PullerJson $response (Get-PullerSessionView)
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/connect') {
                $script:Session = Connect-PullerSession
                Write-PullerJson $response (Get-PullerSessionView)
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/settings') {
                Write-PullerJson $response (Get-PullerSessionView)
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/settings') {
                $posted = (Read-PullerBody $request) | ConvertFrom-Json
                $merged = Merge-PullerSettings $posted
                Save-PullerSettingsObject $merged
                Write-PullerJson $response (Get-PullerSessionView)
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/jobs') {
                $summaries = @()
                foreach ($job in @(Get-PullerJobList)) {
                    $summaries += [pscustomobject]@{
                        id = $job.id
                        name = $job.name
                        status = $job.status
                        items = $job.items
                        created = $job.created
                    }
                }
                Write-PullerJson $response @{ jobs = @($summaries) }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/search') {
                if (-not $script:Session) { Write-PullerError $response 'Sign in before searching.' 401; continue }
                $posted = (Read-PullerBody $request) | ConvertFrom-Json
                $job = New-PullerJobFromRequest $posted
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)$' -and $request.HttpMethod -eq 'GET') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                $job = Update-PullerActiveJob $job
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)/preview$' -and $request.HttpMethod -eq 'POST') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                $job.preview = @(Get-PullerPreviewRows $job)
                $job.detail = "Preview rows: $(@($job.preview).Count). Public folder and Teams hits that are not mailbox messages stay in the counts."
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)/csv$' -and $request.HttpMethod -eq 'POST') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                $choice = [string]$job.choices.defaultCsv
                if ($choice -eq 'purviewReport' -and $job.tier -eq 'premium') {
                    $job.action = 'purviewReport'
                    $job.status = 'exporting'
                    $job = Update-PullerActiveJob $job
                }
                else {
                    if (-not $job.preview -or @($job.preview).Count -eq 0) { $job.preview = @(Get-PullerPreviewRows $job) }
                    $settings = Merge-PullerSettings (Get-PullerSettingsObject)
                    $folder = Join-Path (Get-PullerDownloadFolder -Settings $settings -Root $script:Root) $job.id
                    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
                    $csvPath = Join-Path $folder ($job.name + '.csv')
                    Set-Content -LiteralPath $csvPath -Value (ConvertTo-PullerCsv $job.preview) -Encoding UTF8
                    $job.files = @(@($job.files) + $csvPath)
                    $job.status = 'exported'
                    $job.detail = 'Local metadata CSV saved.'
                    $job = Add-PullerNotice $job 'csv saved'
                }
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)/export$' -and $request.HttpMethod -eq 'POST') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                $choice = [string]$job.choices.defaultExport
                if ($choice -eq 'purviewPst' -and $job.tier -ne 'premium') { $choice = 'standardPst' }
                $job.action = $choice
                $job.status = 'exporting'
                $job.work = $null
                $job = Update-PullerActiveJob $job
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)/purge$' -and $request.HttpMethod -eq 'POST') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                $posted = (Read-PullerBody $request) | ConvertFrom-Json
                if ([string]$posted.searchNameConfirm -ne [string]$job.name) {
                    Write-PullerError $response 'Type the search name to confirm the delete.' 400
                    continue
                }
                $mailboxes = @($job.results | ForEach-Object { [string]$_.Location } | Where-Object { $_ -match '@' })
                $holds = @(Get-PullerHoldReport -Mailboxes $mailboxes)
                $job.holds = @($holds)
                if ($holds.Count -gt 0 -and -not $posted.acknowledgeHolds) {
                    $job.detail = 'One or more mailboxes are on hold. Confirm again to continue. Puller does not remove the hold.'
                    Save-PullerJobFile $job
                    Write-PullerJson $response @{ job = $job; needsHoldAck = $true }
                    continue
                }
                $permanent = [bool]$posted.permanent
                $purgeChoice = [string]$job.choices.defaultPurge
                if ($purgeChoice -eq 'premium100' -and $job.tier -eq 'premium') {
                    if (-not $job.graphCaseId) {
                        $all = ($job.mailboxMode -ne 'list')
                        $created = New-PullerPurviewCase -DisplayName $job.name -Query $job.query -AllMailboxes $all -MailboxList @($job.mailboxes) -PublicFolders ([bool]$job.locations.publicFolders)
                        $job.graphCaseId = $created.caseId
                        $job.graphSearchId = $created.searchId
                    }
                    $null = Invoke-PullerPurviewPurge -CaseId $job.graphCaseId -SearchId $job.graphSearchId -Permanent $permanent -Teams ([bool]$job.locations.teams)
                    $job.detail = 'Premium purge accepted. Mailbox cap is 100 items per location. Teams purge is permanent when Teams was checked.'
                }
                else {
                    if ($job.locations.teams) {
                        $job.detail = 'Teams was checked, but this purge uses the 10-item mailbox command and does not delete Teams messages.'
                    }
                    $null = Invoke-PullerIppsPurge -SearchName $job.name -Permanent $permanent
                    $cap = '10 items per mailbox'
                    $job.detail = ((@($job.detail) + "Purge started. Cap is $cap.") | Where-Object { $_ }) -join ' '
                }
                $job.status = 'purged'
                $job = Add-PullerNotice $job 'purge finished'
                Save-PullerJobFile $job
                Write-PullerJson $response @{ job = $job; needsHoldAck = $false }
                continue
            }
            if ($path -match '^/api/jobs/([a-f0-9]+)/remove$' -and $request.HttpMethod -eq 'POST') {
                $job = Get-PullerJobFile $Matches[1]
                if (-not $job) { Write-PullerError $response 'That search was not found.' 404; continue }
                Remove-PullerComplianceSearch -SearchName $job.name -GraphCaseId $job.graphCaseId
                $job.status = 'removed'
                $job.detail = 'The search was removed.'
                $job = Add-PullerNotice $job 'search removed'
                Save-PullerJobFile $job
                Write-PullerJson $response $job
                continue
            }
            Write-PullerError $response 'Not found.' 404
        }
        catch {
            try { Write-PullerError $response $_.Exception.Message 500 } catch { }
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
