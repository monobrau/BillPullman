#Requires -Version 5.1
#Requires -Modules Pester

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\SearchJobs.psm1'
Import-Module $modulePath -Force

Describe 'Puller query and defaults' {
    It 'builds a compliance query from the simple fields' {
        $query = Build-PullerComplianceQuery -Sender 'a@contoso.com' -Subject 'Invoice' -MessageId '<abc@contoso.com>' -DateFrom '2026-01-01' -DateTo '2026-01-31' -RawQuery 'hasattachment:true'
        $query | Should -Be 'from:"a@contoso.com" AND subject:"Invoice" AND MessageId:"abc@contoso.com" AND received>=2026-01-01 AND received<=2026-01-31 AND (hasattachment:true)'
    }

    It 'returns an empty query when every field is blank' {
        Build-PullerComplianceQuery | Should -Be ''
    }

    It 'maps MessageId onto the Graph search property' {
        Build-PullerGraphSearch 'MessageId:"abc"' | Should -Be 'internetMessageId:"abc"'
    }

    It 'keeps factory defaults when settings are empty' {
        $choices = Get-PullerEffectiveChoices -Settings $null -Tier 'standard'
        $choices.defaultExport | Should -Be 'standardPst'
        $choices.defaultCsv | Should -Be 'local'
        $choices.defaultPurge | Should -Be 'recoverable10'
        $choices.locations.mailboxes | Should -Be $true
        $choices.locations.publicFolders | Should -Be $false
        $choices.locations.teams | Should -Be $false
        $choices.allowed.purviewPst | Should -Be $false
    }

    It 'uses a saved premium default when the tenant is premium' {
        $settings = [pscustomobject]@{
            defaultExport = 'purviewPst'
            defaultCsv = 'purviewReport'
            defaultPurge = 'premium100'
            locations = [pscustomobject]@{ mailboxes = $true; publicFolders = $true; teams = $true }
        }
        $choices = Get-PullerEffectiveChoices -Settings $settings -Tier 'premium'
        $choices.defaultExport | Should -Be 'purviewPst'
        $choices.defaultCsv | Should -Be 'purviewReport'
        $choices.defaultPurge | Should -Be 'premium100'
        $choices.locations.teams | Should -Be $true
        $choices.notes.Count | Should -Be 0
    }

    It 'falls back when a saved premium default is not included' {
        $settings = [pscustomobject]@{
            defaultExport = 'purviewPst'
            defaultCsv = 'purviewReport'
            defaultPurge = 'premium100'
            locations = [pscustomobject]@{ mailboxes = $false; publicFolders = $false; teams = $true }
        }
        $choices = Get-PullerEffectiveChoices -Settings $settings -Tier 'standard'
        $choices.tier | Should -Be 'standard'
        $choices.defaultExport | Should -Be 'standardPst'
        $choices.defaultCsv | Should -Be 'local'
        $choices.defaultPurge | Should -Be 'recoverable10'
        $choices.locations.teams | Should -Be $false
        $choices.locations.mailboxes | Should -Be $true
        $choices.notes.Count | Should -BeGreaterThan 0
    }
}

Describe 'Puller license detection' {
    It 'treats a successful probe as premium' {
        $tier = Resolve-PullerLicenseTier -Skus @() -ProbeStatus 'ok' -ProbeError ''
        $tier.tier | Should -Be 'premium'
    }

    It 'stays standard when the probe asks for pay-as-you-go' {
        $sku = [pscustomobject]@{
            skuPartNumber = 'SPE_E5'
            capabilityStatus = 'Enabled'
            servicePlans = @()
        }
        $tier = Resolve-PullerLicenseTier -Skus @($sku) -ProbeStatus 'billing' -ProbeError 'Activate pay-as-you-go billing'
        $tier.tier | Should -Be 'standard'
        $tier.label | Should -Be 'SPE_E5'
    }

    It 'stays standard when detection is uncertain' {
        $tier = Resolve-PullerLicenseTier -Skus @() -ProbeStatus 'unknown' -ProbeError 'timeout'
        $tier.tier | Should -Be 'standard'
    }
}

Describe 'Puller result helpers' {
    It 'parses compliance success results' {
        $text = "{shared@contoso.com, 2, 4096}`r`n{user@contoso.com, 1, 100}"
        $rows = @(Parse-PullerSuccessResults -Text $text)
        $rows.Count | Should -Be 2
        $rows[0].Location | Should -Be 'shared@contoso.com'
        $rows[0].ItemCount | Should -Be 2
    }

    It 'writes a header when a CSV has no rows' {
        ConvertTo-PullerCsv @() | Should -Be "mailbox,sender,subject,received,messageId`r`n"
    }

    It 'quotes a subject that contains a comma' {
        $csv = ConvertTo-PullerCsv @([pscustomobject]@{
            mailbox = 'a@contoso.com'
            sender = 'b@contoso.com'
            subject = 'Hello, there'
            received = '2026-01-01T00:00:00Z'
            messageId = '<m@contoso.com>'
        })
        $csv | Should -Match '"Hello, there"'
    }
}
