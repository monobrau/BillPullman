#Requires -Version 5.1

function Send-PullerMail {
    param(
        [string]$To,
        [string]$Subject,
        [string]$Body
    )
    if (-not $To) { return }
    $payload = @{
        message = @{
            subject = $Subject
            body = @{ contentType = 'Text'; content = $Body }
            toRecipients = @(@{ emailAddress = @{ address = $To } })
        }
        saveToSentItems = $true
    }
    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $payload | Out-Null
}

function Send-PullerToast {
    param(
        [string]$Title,
        [string]$Body
    )
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $safeTitle = [System.Security.SecurityElement]::Escape($Title)
        $safeBody = [System.Security.SecurityElement]::Escape($Body)
        $toastXml = @"
<toast><visual><binding template="ToastGeneric"><text>$safeTitle</text><text>$safeBody</text></binding></visual></toast>
"@
        $xml.LoadXml($toastXml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Puller').Show($toast)
    }
    catch {
        Write-Verbose "Toast was not shown: $($_.Exception.Message)"
    }
}

function Send-PullerNotice {
    param(
        $Settings,
        [string]$Title,
        [string]$Body
    )
    $sent = $false
    $toasted = $false
    if ($Settings -and $Settings.notifyTo) {
        try {
            Send-PullerMail -To ([string]$Settings.notifyTo) -Subject $Title -Body $Body
            $sent = $true
        }
        catch {
            Write-Verbose "Alert mail was not sent: $($_.Exception.Message)"
        }
    }
    $toastOn = $true
    if ($Settings -and $null -ne $Settings.toast) { $toastOn = [bool]$Settings.toast }
    if ($toastOn) {
        Send-PullerToast -Title $Title -Body $Body
        $toasted = $true
    }
    return [pscustomobject]@{ MailSent = $sent; ToastAttempted = $toasted }
}

Export-ModuleMember -Function Send-PullerMail, Send-PullerToast, Send-PullerNotice
