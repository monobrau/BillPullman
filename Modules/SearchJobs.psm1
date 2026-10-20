#Requires -Version 5.1

$script:PremiumSkuPattern = '(?i)^(SPE_E5|SPE_E5_NOPSTNCONF|ENTERPRISEPREMIUM|ENTERPRISEPREMIUM_NOPSTNCONF|ENTERPRISEPREMIUM_GOV|M365EDU_A5|M365EDU_A5_FACULTY|M365EDU_A5_STUDENT|INFORMATION_PROTECTION_COMPLIANCE|SPE_A5|SPE_G5)$'
$script:PremiumPlanPattern = '(?i)EQUIVIO_ANALYTICS|INFORMATION_PROTECTION_COMPLIANCE|EDISCOVERY'

function Get-PullerFactoryDefaults {
    return [pscustomobject]@{
        notifyTo       = ''
        downloadFolder = ''
        toast          = $true
        maxMessages    = 1000
        locations      = [pscustomobject]@{ mailboxes = $true; publicFolders = $false; teams = $false }
        defaultExport  = 'standardPst'
        defaultCsv     = 'local'
        defaultPurge   = 'recoverable10'
    }
}

function Merge-PullerSettings {
    param($Settings)
    $factory = Get-PullerFactoryDefaults
    if (-not $Settings) { return $factory }
    $locations = $factory.locations
    if ($Settings.locations) {
        $locations = [pscustomobject]@{
            mailboxes     = $(if ($null -ne $Settings.locations.mailboxes) { [bool]$Settings.locations.mailboxes } else { $true })
            publicFolders = [bool]$Settings.locations.publicFolders
            teams         = [bool]$Settings.locations.teams
        }
    }
    $max = 1000
    if ($Settings.maxMessages) {
        $parsed = 0
        if ([int]::TryParse([string]$Settings.maxMessages, [ref]$parsed) -and $parsed -gt 0) { $max = $parsed }
    }
    $export = [string]$Settings.defaultExport
    if ($export -notin @('standardPst', 'purviewPst')) { $export = $factory.defaultExport }
    $csv = [string]$Settings.defaultCsv
    if ($csv -notin @('local', 'purviewReport')) { $csv = $factory.defaultCsv }
    $purge = [string]$Settings.defaultPurge
    if ($purge -notin @('recoverable10', 'premium100')) { $purge = $factory.defaultPurge }
    $toast = $factory.toast
    if ($null -ne $Settings.toast) { $toast = [bool]$Settings.toast }
    return [pscustomobject]@{
        notifyTo       = [string]$Settings.notifyTo
        downloadFolder = [string]$Settings.downloadFolder
        toast          = $toast
        maxMessages    = $max
        locations      = $locations
        defaultExport  = $export
        defaultCsv     = $csv
        defaultPurge   = $purge
    }
}

function Get-PullerEffectiveChoices {
    param(
        $Settings,
        [string]$Tier
    )
    $merged = Merge-PullerSettings $Settings
    $notes = New-Object System.Collections.Generic.List[string]
    $premium = ($Tier -eq 'premium')
    $export = $merged.defaultExport
    $csv = $merged.defaultCsv
    $purge = $merged.defaultPurge
    $locations = [pscustomobject]@{
        mailboxes     = [bool]$merged.locations.mailboxes
        publicFolders = [bool]$merged.locations.publicFolders
        teams         = [bool]$merged.locations.teams
    }
    if (-not $premium) {
        if ($export -eq 'purviewPst') {
            $export = 'standardPst'
            $notes.Add('Purview PST is not included for this tenant. The export default is Standard PST.')
        }
        if ($csv -eq 'purviewReport') {
            $csv = 'local'
            $notes.Add('The Purview report is not included for this tenant. The CSV default is the local metadata file.')
        }
        if ($purge -eq 'premium100') {
            $purge = 'recoverable10'
            $notes.Add('The 100-item purge is not included for this tenant. The purge default is the 10-item recoverable purge.')
        }
        if ($locations.teams) {
            $locations.teams = $false
            $notes.Add('Teams is not available on this license. That location was turned off.')
        }
    }
    if (-not $locations.mailboxes -and -not $locations.publicFolders -and -not $locations.teams) {
        $locations.mailboxes = $true
        $notes.Add('At least one location is required. Mailboxes were turned on.')
    }
    return [pscustomobject]@{
        tier          = $(if ($premium) { 'premium' } else { 'standard' })
        notifyTo      = $merged.notifyTo
        downloadFolder = $merged.downloadFolder
        toast         = $merged.toast
        maxMessages   = $merged.maxMessages
        locations     = $locations
        defaultExport = $export
        defaultCsv    = $csv
        defaultPurge  = $purge
        notes         = @($notes.ToArray())
        allowed       = [pscustomobject]@{
            purviewPst    = $premium
            purviewReport = $premium
            premium100    = $premium
            teams         = $premium
            publicFolders = $true
            standardPst   = $true
            localCsv      = $true
            recoverable10 = $true
        }
    }
}

function Get-PullerPremiumSkuLabel {
    param($Skus)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($sku in @($Skus)) {
        if (-not $sku) { continue }
        $part = [string]$sku.skuPartNumber
        $display = [string]$sku.skuPartNumber
        if ($sku.skuId -and $sku.prepaidUnits) { }
        $capability = $sku.capabilityStatus
        if ($capability -and $capability -ne 'Enabled' -and $capability -ne 'Warning') { continue }
        $hit = $false
        if ($part -match $script:PremiumSkuPattern) { $hit = $true }
        foreach ($plan in @($sku.servicePlans)) {
            $planName = [string]$plan.servicePlanName
            $status = [string]$plan.provisioningStatus
            if ($status -and $status -ne 'Success' -and $status -ne 'PendingActivation') { continue }
            if ($planName -match $script:PremiumPlanPattern) { $hit = $true; $display = $planName }
        }
        if ($hit) { $names.Add($(if ($display) { $display } else { $part })) }
    }
    return @($names.ToArray())
}

function Resolve-PullerLicenseTier {
    param(
        $Skus,
        [string]$ProbeStatus,
        [string]$ProbeError
    )
    $labels = @(Get-PullerPremiumSkuLabel -Skus $Skus)
    $label = ''
    if ($labels.Count -gt 0) { $label = $labels[0] }
    $errorText = [string]$ProbeError
    if ($ProbeStatus -eq 'ok') {
        return [pscustomobject]@{
            tier  = 'premium'
            label = $(if ($label) { $label } else { 'Premium eDiscovery' })
        }
    }
    if ($errorText -match 'pay-as-you-go|pay as you go|billing') {
        return [pscustomobject]@{ tier = 'standard'; label = $(if ($label) { $label } else { 'Standard' }) }
    }
    if ($ProbeStatus -eq 'denied' -or $ProbeStatus -eq 'unknown' -or -not $ProbeStatus) {
        return [pscustomobject]@{ tier = 'standard'; label = $(if ($label) { $label } else { 'Standard' }) }
    }
    return [pscustomobject]@{ tier = 'standard'; label = $(if ($label) { $label } else { 'Standard' }) }
}

function Escape-PullerKqlValue {
    param([string]$Value)
    if (-not $Value) { return '' }
    return ($Value -replace '"', '""').Trim()
}

function Build-PullerComplianceQuery {
    param(
        [string]$Sender,
        [string]$Subject,
        [string]$MessageId,
        [string]$DateFrom,
        [string]$DateTo,
        [string]$RawQuery
    )
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Sender) { $parts.Add(('from:"{0}"' -f (Escape-PullerKqlValue $Sender))) }
    if ($Subject) { $parts.Add(('subject:"{0}"' -f (Escape-PullerKqlValue $Subject))) }
    if ($MessageId) {
        $id = (Escape-PullerKqlValue $MessageId) -replace '[<>]', ''
        $parts.Add(('MessageId:"{0}"' -f $id))
    }
    if ($DateFrom) { $parts.Add(('received>={0}' -f $DateFrom.Trim())) }
    if ($DateTo) { $parts.Add(('received<={0}' -f $DateTo.Trim())) }
    if ($RawQuery -and $RawQuery.Trim()) { $parts.Add(('({0})' -f $RawQuery.Trim())) }
    return ($parts -join ' AND ')
}

function Build-PullerGraphSearch {
    param([string]$ComplianceQuery)
    if (-not $ComplianceQuery) { return '' }
    $graph = $ComplianceQuery -replace '(?i)MessageId:', 'internetMessageId:'
    return $graph
}

function New-PullerSearchName {
    param([string]$Prefix = 'Puller')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 4)
    return ('{0}-{1}-{2}' -f $Prefix, $stamp, $suffix)
}

function Parse-PullerSuccessResults {
    param([string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }
    foreach ($line in ($Text -split '[\r\n;]+')) {
        $trimmed = $line.Trim().TrimStart('{').TrimEnd('}')
        if (-not $trimmed) { continue }
        $bits = $trimmed -split ','
        if ($bits.Count -lt 1) { continue }
        $location = $bits[0].Trim()
        if (-not $location) { continue }
        $count = 0
        if ($bits.Count -gt 1) { [void][int]::TryParse($bits[1].Trim(), [ref]$count) }
        $rows.Add([pscustomobject]@{ Location = $location; ItemCount = $count })
    }
    return @($rows.ToArray())
}

function ConvertTo-PullerCsv {
    param($Rows)
    $list = @($Rows)
    if ($list.Count -eq 0) {
        return "mailbox,sender,subject,received,messageId`r`n"
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('mailbox,sender,subject,received,messageId')
    foreach ($row in $list) {
        $cells = @(
            [string]$row.mailbox,
            [string]$row.sender,
            [string]$row.subject,
            [string]$row.received,
            [string]$row.messageId
        ) | ForEach-Object {
            $text = $_
            if ($null -eq $text) { $text = '' }
            if ($text -match '[",\r\n]') { '"' + ($text -replace '"', '""') + '"' } else { $text }
        }
        $lines.Add(($cells -join ','))
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Get-PullerDownloadFolder {
    param(
        $Settings,
        [string]$Root
    )
    $folder = ''
    if ($Settings -and $Settings.downloadFolder) { $folder = [string]$Settings.downloadFolder }
    if (-not $folder) { $folder = Join-Path $Root 'downloads' }
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $folder).Path
}

function Test-PullerGraphConnected {
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return $false }
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    return ($null -ne $ctx -and $ctx.Account)
}

function Get-PullerGraphToken {
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.PSObject.Properties.Name -contains 'AccessToken' -and $ctx.AccessToken) {
        return [string]$ctx.AccessToken
    }
    try {
        $session = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
        if ($session -and $session.AuthContext) {
            $result = $session.AuthContext.GetTokenAsync('https://graph.microsoft.com', $false).GetAwaiter().GetResult()
            if ($result -and $result.Token) { return [string]$result.Token }
        }
    }
    catch {
        Write-Verbose "Graph token was not exposed: $($_.Exception.Message)"
    }
    return $null
}

function Invoke-PullerGraph {
    param(
        [string]$Method,
        [string]$Uri,
        $Body,
        [hashtable]$Headers
    )
    $params = @{ Method = $Method; Uri = $Uri }
    if ($Body) { $params.Body = $Body }
    if ($Headers) { $params.Headers = $Headers }
    return Invoke-MgGraphRequest @params
}

function Get-PullerLicenseProbe {
    $skus = @()
    $skuError = ''
    try {
        $skuResponse = Invoke-PullerGraph -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'
        $skus = @($skuResponse.value)
    }
    catch {
        $skuError = $_.Exception.Message
    }
    $probeStatus = 'unknown'
    $probeError = ''
    try {
        $null = Invoke-PullerGraph -Method GET -Uri 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases?$top=1'
        $probeStatus = 'ok'
    }
    catch {
        $probeError = $_.Exception.Message
        if ($probeError -match 'pay-as-you-go|pay as you go|billing') { $probeStatus = 'billing' }
        elseif ($probeError -match 'Authorization|Forbidden|401|403|Insufficient|privilege|Access token') { $probeStatus = 'denied' }
        else { $probeStatus = 'unknown' }
    }
    $resolved = Resolve-PullerLicenseTier -Skus $skus -ProbeStatus $probeStatus -ProbeError $probeError
    return [pscustomobject]@{
        tier       = $resolved.tier
        label      = $resolved.label
        probeStatus = $probeStatus
        probeError = $probeError
        skuError   = $skuError
    }
}

function Connect-PullerSession {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is not installed. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'ExchangeOnlineManagement 3.9 or later is not installed. Install it with: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $scopes = @(
        'User.Read',
        'Mail.Read.Shared',
        'Mail.Send',
        'Organization.Read.All',
        'eDiscovery.ReadWrite.All'
    )
    Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Connect-IPPSSession -EnableSearchOnlySession -ErrorAction Stop
    $ctx = Get-MgContext
    $license = Get-PullerLicenseProbe
    return [pscustomobject]@{
        connected   = $true
        account     = [string]$ctx.Account
        tenantId    = [string]$ctx.TenantId
        tier        = $license.tier
        label       = $license.label
        probeStatus = $license.probeStatus
        probeError  = $license.probeError
    }
}

function New-PullerComplianceSearch {
    param(
        [string]$Name,
        [string]$Query,
        [bool]$Mailboxes,
        [bool]$PublicFolders,
        [bool]$Teams,
        [string]$MailboxMode,
        [string[]]$MailboxList
    )
    if (-not $Query) { throw 'Enter a sender, subject, message ID, date, or raw query before searching.' }
    if (-not $Mailboxes -and -not $PublicFolders -and -not $Teams) {
        throw 'Choose at least one location.'
    }
    $params = @{
        Name              = $Name
        ContentMatchQuery = $Query
        Description       = 'Created by Puller'
    }
    $searchMailboxes = $Mailboxes -or $Teams
    if ($searchMailboxes) {
        if ($MailboxMode -eq 'list') {
            $clean = @($MailboxList | Where-Object { $_ -and $_.Trim() })
            if ($clean.Count -eq 0) { throw 'Paste at least one mailbox, or search all mailboxes.' }
            $params.ExchangeLocation = $clean
            $params.AllowNotFoundExchangeLocationsEnabled = $true
        }
        else {
            $params.ExchangeLocation = 'All'
        }
    }
    if ($PublicFolders) { $params.PublicFolderLocation = 'All' }
    New-ComplianceSearch @params | Out-Null
    Start-ComplianceSearch -Identity $Name | Out-Null
    return Get-ComplianceSearch -Identity $Name
}

function Get-PullerComplianceStatus {
    param([string]$Name)
    $search = Get-ComplianceSearch -Identity $Name -ErrorAction Stop
    $results = Parse-PullerSuccessResults -Text ([string]$search.SuccessResults)
    return [pscustomobject]@{
        status   = [string]$search.Status
        items    = $search.Items
        size     = $search.Size
        errors   = [string]$search.Errors
        results  = @($results)
    }
}

function Get-PullerMailboxPreview {
    param(
        [string]$Mailbox,
        [string]$GraphSearch,
        [int]$Top = 5
    )
    $encoded = [uri]::EscapeDataString($GraphSearch)
    $select = 'subject,from,receivedDateTime,internetMessageId,id'
    $uri = "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($Mailbox))/messages?`$search=`"$encoded`"&`$top=$Top&`$select=$select"
    $response = Invoke-PullerGraph -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($response.value)) {
        $sender = ''
        if ($item.from -and $item.from.emailAddress) { $sender = [string]$item.from.emailAddress.address }
        $rows.Add([pscustomobject]@{
            mailbox   = $Mailbox
            sender    = $sender
            subject   = [string]$item.subject
            received  = [string]$item.receivedDateTime
            messageId = [string]$item.internetMessageId
            graphId   = [string]$item.id
        })
    }
    return @($rows.ToArray())
}

function Get-PullerHoldReport {
    param([string[]]$Mailboxes)
    $holds = New-Object System.Collections.Generic.List[object]
    foreach ($mailbox in @($Mailboxes)) {
        if (-not $mailbox) { continue }
        try {
            $box = Get-Mailbox -Identity $mailbox -ErrorAction Stop
        }
        catch {
            $holds.Add([pscustomobject]@{
                mailbox = $mailbox
                holds   = @('Could not read hold status')
                detail  = $_.Exception.Message
            })
            continue
        }
        $flags = New-Object System.Collections.Generic.List[string]
        if ($box.LitigationHoldEnabled) { $flags.Add('Litigation hold') }
        if ($box.RetentionHoldEnabled) { $flags.Add('Retention hold') }
        if ($box.DelayHoldApplied) { $flags.Add('Delay hold') }
        $inPlace = @($box.InPlaceHolds)
        if ($inPlace.Count -gt 0) { $flags.Add('In-place hold') }
        if ($flags.Count -gt 0) {
            $holds.Add([pscustomobject]@{
                mailbox = $mailbox
                holds   = @($flags.ToArray())
                detail  = ''
            })
        }
    }
    return @($holds.ToArray())
}

function Invoke-PullerIppsPurge {
    param(
        [string]$SearchName,
        [bool]$Permanent
    )
    $type = 'SoftDelete'
    if ($Permanent) { $type = 'HardDelete' }
    $existing = Get-ComplianceSearchAction -SearchName $SearchName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*_Purge' }
    foreach ($action in @($existing)) {
        Remove-ComplianceSearchAction -Identity $action.Identity -Confirm:$false -ErrorAction SilentlyContinue
    }
    New-ComplianceSearchAction -SearchName $SearchName -Purge -PurgeType $type -Confirm:$false -Force | Out-Null
    return Get-ComplianceSearchAction -SearchName $SearchName | Where-Object { $_.Name -like '*_Purge' } | Select-Object -First 1
}

function Remove-PullerComplianceSearch {
    param(
        [string]$SearchName,
        [string]$GraphCaseId
    )
    if ($SearchName) {
        Remove-ComplianceSearch -Identity $SearchName -Confirm:$false -ErrorAction Stop
    }
    if ($GraphCaseId) {
        Invoke-PullerGraph -Method DELETE -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$GraphCaseId" | Out-Null
    }
}

function Save-PullerMessageMime {
    param(
        [string]$Mailbox,
        [string]$MessageId,
        [string]$Folder
    )
    $safe = ($MessageId -replace '[^\w\-]', '_')
    if (-not $safe) { $safe = 'message' }
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    $path = Join-Path $Folder ($safe + '.eml')
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Folder ("{0}-{1}.eml" -f $safe, $n)
        $n++
    }
    $uri = "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($Mailbox))/messages/$([uri]::EscapeDataString($MessageId))/`$value"
    Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $path | Out-Null
    return $path
}

function Get-PullerNextMessages {
    param(
        [string]$Mailbox,
        [string]$GraphSearch,
        [string]$NextLink,
        [int]$Top = 3
    )
    if ($NextLink) {
        $uri = $NextLink
    }
    else {
        $encoded = [uri]::EscapeDataString($GraphSearch)
        $uri = "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($Mailbox))/messages?`$search=`"$encoded`"&`$top=$Top&`$select=id,internetMessageId,subject"
    }
    $response = Invoke-PullerGraph -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' }
    return [pscustomobject]@{
        value    = @($response.value)
        nextLink = [string]$response.'@odata.nextLink'
    }
}

function Add-PullerEmlFolderToPst {
    param(
        [string]$PstPath,
        [string]$EmlFolder
    )
    if (-not (Test-Path -LiteralPath $EmlFolder)) { throw 'The message folder was not found.' }
    $outlook = $null
    try {
        $outlook = New-Object -ComObject Outlook.Application
    }
    catch {
        throw 'Classic Outlook is not installed, so the PST was not built. The .eml files were saved.'
    }
    $ns = $outlook.GetNamespace('MAPI')
    $ns.AddStore($PstPath)
    $store = $null
    foreach ($candidate in @($ns.Stores)) {
        if ($candidate.FilePath -and ($candidate.FilePath -eq $PstPath)) { $store = $candidate; break }
    }
    if (-not $store) { $store = @($ns.Stores)[-1] }
    $root = $store.GetRootFolder()
    $folder = $null
    foreach ($child in @($root.Folders)) {
        if ($child.Name -eq 'Puller') { $folder = $child; break }
    }
    if (-not $folder) { $folder = $root.Folders.Add('Puller') }
    $imported = 0
    $failed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $EmlFolder -Filter *.eml -File)) {
        try {
            $shared = $ns.OpenSharedItem($file.FullName)
            $null = $shared.Move($folder)
            $imported++
        }
        catch {
            try {
                $raw = [System.IO.File]::ReadAllText($file.FullName)
                $mail = $folder.Items.Add(0)
                $subject = ''
                if ($raw -match '(?m)^Subject:\s*(.+)$') { $subject = $Matches[1].Trim() }
                $mail.Subject = $(if ($subject) { $subject } else { $file.BaseName })
                $split = $raw -split "`r`n`r`n", 2
                if ($split.Count -lt 2) { $split = $raw -split "`n`n", 2 }
                $mail.Body = $(if ($split.Count -gt 1) { $split[1] } else { $raw })
                $mail.Save()
                $imported++
            }
            catch {
                $failed++
            }
        }
    }
    return [pscustomobject]@{ Imported = $imported; Failed = $failed; PstPath = $PstPath }
}

function New-PullerPurviewCase {
    param(
        [string]$DisplayName,
        [string]$Query,
        [bool]$AllMailboxes,
        [string[]]$MailboxList,
        [bool]$PublicFolders
    )
    $case = Invoke-PullerGraph -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases' -Body @{
        displayName = $DisplayName
    }
    $caseId = [string]$case.id
    $scopes = 'none'
    if ($AllMailboxes) { $scopes = 'allTenantMailboxes' }
    else {
        foreach ($mailbox in @($MailboxList)) {
            if (-not $mailbox) { continue }
            $sourceBody = @{
                dataSource = @{
                    '@odata.type'   = 'microsoft.graph.security.userSource'
                    email           = $mailbox
                    includedSources = 'mailbox'
                }
            }
            Invoke-PullerGraph -Method POST -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$caseId/noncustodialDataSources" -Body $sourceBody | Out-Null
        }
        $scopes = 'allCaseNoncustodialDataSources'
    }
    $searchBody = @{
        displayName     = $DisplayName
        contentQuery    = $Query
        dataSourceScopes = $scopes
    }
    $headers = @{ Prefer = 'include-unknown-enum-members' }
    $search = Invoke-PullerGraph -Method POST -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$caseId/searches" -Body $searchBody -Headers $headers
    return [pscustomobject]@{
        caseId   = $caseId
        searchId = [string]$search.id
        publicFoldersRequested = $PublicFolders
    }
}

function Start-PullerPurviewExport {
    param(
        [string]$CaseId,
        [string]$SearchId,
        [string]$DisplayName,
        [bool]$ReportOnly
    )
    $headers = @{ Prefer = 'include-unknown-enum-members' }
    if ($ReportOnly) {
        try {
            return Invoke-PullerGraph -Method POST -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/exportReport" -Body @{ displayName = $DisplayName } -Headers $headers
        }
        catch {
            $fallback = @{
                displayName       = $DisplayName
                exportCriteria    = 'searchHits'
                exportFormat      = 'msg'
                additionalOptions = 'includeReport'
            }
            return Invoke-PullerGraph -Method POST -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/exportResult" -Body $fallback -Headers $headers
        }
    }
    $body = @{
        displayName       = $DisplayName
        exportCriteria    = 'searchHits'
        exportFormat      = 'pst'
        additionalOptions = 'splitSource'
    }
    return Invoke-PullerGraph -Method POST -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/exportResult" -Body $body -Headers $headers
}

function Invoke-PullerPurviewPurge {
    param(
        [string]$CaseId,
        [string]$SearchId,
        [bool]$Permanent,
        [bool]$Teams
    )
    $headers = @{ Prefer = 'include-unknown-enum-members' }
    $purgeType = 'recoverable'
    if ($Permanent) { $purgeType = 'permanentlyDelete' }
    $uri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/purgeData"
    $mailboxResult = Invoke-PullerGraph -Method POST -Uri $uri -Body @{ purgeType = $purgeType; purgeAreas = 'mailboxes' } -Headers $headers
    $teamsResult = $null
    if ($Teams) {
        $teamsResult = Invoke-PullerGraph -Method POST -Uri $uri -Body @{ purgeType = 'permanentlyDelete'; purgeAreas = 'teamsMessages' } -Headers $headers
    }
    return [pscustomobject]@{ mailboxes = $mailboxResult; teams = $teamsResult }
}

Export-ModuleMember -Function @(
    'Get-PullerFactoryDefaults',
    'Merge-PullerSettings',
    'Get-PullerEffectiveChoices',
    'Get-PullerPremiumSkuLabel',
    'Resolve-PullerLicenseTier',
    'Build-PullerComplianceQuery',
    'Build-PullerGraphSearch',
    'New-PullerSearchName',
    'Parse-PullerSuccessResults',
    'ConvertTo-PullerCsv',
    'Get-PullerDownloadFolder',
    'Test-PullerGraphConnected',
    'Get-PullerGraphToken',
    'Get-PullerLicenseProbe',
    'Connect-PullerSession',
    'New-PullerComplianceSearch',
    'Get-PullerComplianceStatus',
    'Get-PullerMailboxPreview',
    'Get-PullerHoldReport',
    'Invoke-PullerIppsPurge',
    'Remove-PullerComplianceSearch',
    'Save-PullerMessageMime',
    'Get-PullerNextMessages',
    'Add-PullerEmlFolderToPst',
    'New-PullerPurviewCase',
    'Start-PullerPurviewExport',
    'Invoke-PullerPurviewPurge'
)
