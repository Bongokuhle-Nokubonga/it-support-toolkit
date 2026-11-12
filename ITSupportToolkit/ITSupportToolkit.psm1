#Requires -Version 5.1
<#
    IT Support Toolkit
    Everyday helpdesk tasks as PowerShell functions:
      Get-SystemReport     - PC health and inventory report (text or HTML)
      Test-NetworkHealth   - step-by-step "no internet" troubleshooter
      New-BulkADUser       - onboard many users into Active Directory from a CSV
    Works on Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

#region Helpers (pure functions, easy to test)

function ConvertTo-SamAccountName {
    <#
    .SYNOPSIS
        Builds a username like "nnkuna" from a first and last name.
    .DESCRIPTION
        Uses the first letter of the first name plus the last name, lowercase,
        with accents and anything that is not a letter or digit removed, and
        cut to 20 characters (the Active Directory limit for sAMAccountName).
        If the name is already taken, adds 2, 3, ... until it is unique.
    .EXAMPLE
        ConvertTo-SamAccountName -FirstName 'Nokubonga' -LastName 'Nkuna'
        nnkuna
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FirstName,
        [Parameter(Mandatory)] [string] $LastName,
        [string[]] $Existing = @()
    )
    $clean = {
        param($s)
        $normalized = $s.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object Text.StringBuilder
        foreach ($ch in $normalized.ToCharArray()) {
            $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
            if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
        }
        ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9]', '')
    }
    $first = & $clean $FirstName
    $last = & $clean $LastName
    if (-not $first -or -not $last) {
        throw "Cannot build a username from '$FirstName' '$LastName'"
    }
    $base = ($first.Substring(0, 1) + $last)
    if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }

    $taken = @{}
    foreach ($e in $Existing) { $taken[$e.ToLowerInvariant()] = $true }
    $candidate = $base
    $n = 2
    while ($taken.ContainsKey($candidate)) {
        $suffix = [string]$n
        $candidate = $base.Substring(0, [Math]::Min($base.Length, 20 - $suffix.Length)) + $suffix
        $n++
    }
    $candidate
}

function New-TempPassword {
    <#
    .SYNOPSIS
        Generates a random temporary password using a cryptographically secure generator.
    .DESCRIPTION
        Always contains at least one upper-case letter, lower-case letter, digit and symbol,
        so it passes the default Active Directory complexity policy. Look-alike characters
        (0/O, 1/l/I) are left out so it can be read out over the phone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 128)] [int] $Length = 16)

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+?'
    )
    $all = -join $sets
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Secure random integer in [0, max). Rejection sampling avoids modulo bias.
        $randInt = {
            param([int] $max)
            $buf = New-Object byte[] 4
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$max)
            do {
                $rng.GetBytes($buf)
                $value = [BitConverter]::ToUInt32($buf, 0)
            } while ($value -ge $limit)
            [int]($value % [uint32]$max)
        }
        $chars = New-Object Collections.Generic.List[char]
        foreach ($set in $sets) { $chars.Add($set[(& $randInt $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $randInt $all.Length)]) }
        # Shuffle (Fisher-Yates) so the guaranteed characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $randInt ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

function Get-IPAddressDiagnosis {
    <#
    .SYNOPSIS
        Explains what an IPv4 address tells you when troubleshooting.
    .EXAMPLE
        Get-IPAddressDiagnosis 169.254.10.5
        APIPA
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $IPAddress)

    $ip = $null
    if (-not [Net.IPAddress]::TryParse($IPAddress, [ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return 'Invalid'
    }
    $b = $ip.GetAddressBytes()
    if ($b[0] -eq 127) { return 'Loopback' }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return 'APIPA' }
    if ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168)) { return 'Private' }
    if ($b[0] -eq 0) { return 'Unassigned' }
    return 'Public'
}

function Get-DiskStatus {
    <#
    .SYNOPSIS
        Rates free disk space: OK, Warning (under 15%) or Critical (under 5% or under 2 GB).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $FreeBytes,
        [Parameter(Mandatory)] [double] $TotalBytes
    )
    if ($TotalBytes -le 0) { return 'Unknown' }
    $pct = $FreeBytes / $TotalBytes * 100
    if ($pct -lt 5 -or $FreeBytes -lt 2GB) { return 'Critical' }
    if ($pct -lt 15) { return 'Warning' }
    return 'OK'
}

function ConvertTo-HtmlSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyString()] [object] $Value)
    if ($null -eq $Value) { return '' }
    [Net.WebUtility]::HtmlEncode([string]$Value)
}

#endregion

#region Get-SystemReport

function Get-SystemReport {
    <#
    .SYNOPSIS
        Collects a PC health and inventory report.
    .DESCRIPTION
        Gathers the details a technician usually asks for first: computer name, OS and
        build, uptime, last boot, CPU, memory, disk space, IP configuration, antivirus
        status and recently installed updates. Each check flags problems
        (low disk, long uptime, antivirus off, APIPA address).
    .PARAMETER HtmlPath
        Also save the report as an HTML file, e.g. to attach to a ticket.
    .EXAMPLE
        Get-SystemReport
    .EXAMPLE
        Get-SystemReport -HtmlPath "$env:USERPROFILE\Desktop\pc-report.html"
    #>
    [CmdletBinding()]
    param([string] $HtmlPath)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $uptime = (Get-Date) - $os.LastBootUpTime
    $issues = New-Object Collections.Generic.List[string]

    $disks = foreach ($d in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3') {
        $status = Get-DiskStatus -FreeBytes $d.FreeSpace -TotalBytes $d.Size
        if ($status -ne 'OK') { $issues.Add("Drive $($d.DeviceID) is low on space ($status)") }
        [pscustomobject]@{
            Drive   = $d.DeviceID
            SizeGB  = [Math]::Round($d.Size / 1GB, 1)
            FreeGB  = [Math]::Round($d.FreeSpace / 1GB, 1)
            FreePct = if ($d.Size) { [Math]::Round($d.FreeSpace / $d.Size * 100) } else { 0 }
            Status  = $status
        }
    }

    $adapters = foreach ($cfg in Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True') {
        $ipv4 = @($cfg.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        foreach ($a in $ipv4) {
            if ((Get-IPAddressDiagnosis $a) -eq 'APIPA') {
                $issues.Add("$($cfg.Description) has an APIPA address ($a): DHCP is not answering")
            }
        }
        [pscustomobject]@{
            Adapter = $cfg.Description
            IPv4    = $ipv4 -join ', '
            Gateway = @($cfg.DefaultIPGateway) -join ', '
            DNS     = @($cfg.DNSServerSearchOrder) -join ', '
            DHCP    = [bool]$cfg.DHCPEnabled
            MAC     = $cfg.MACAddress
        }
    }

    $antivirus = 'Unknown'
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $antivirus = if ($mp.RealTimeProtectionEnabled) {
            "Microsoft Defender on (signatures $($mp.AntivirusSignatureAge) day(s) old)"
        } else { 'Microsoft Defender real-time protection is OFF' }
        if (-not $mp.RealTimeProtectionEnabled) { $issues.Add('Antivirus real-time protection is off') }
        elseif ($mp.AntivirusSignatureAge -gt 7) { $issues.Add('Antivirus signatures are more than a week old') }
    } catch {
        Write-Verbose "Defender status not available: $($_.Exception.Message)"
    }

    $updates = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
        Where-Object { $_.InstalledOn } |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 5 HotFixID, Description, InstalledOn)
    if ($updates.Count -gt 0 -and $updates[0].InstalledOn -lt (Get-Date).AddDays(-45)) {
        $issues.Add('No Windows updates installed in the last 45 days')
    }
    if ($uptime.TotalDays -gt 14) {
        $issues.Add("Not restarted for $([int]$uptime.TotalDays) days: a restart may fix problems and finish updates")
    }

    $report = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        User         = "$env:USERDOMAIN\$env:USERNAME"
        OS           = "$($os.Caption) (build $($os.BuildNumber))"
        Manufacturer = "$($cs.Manufacturer) $($cs.Model)"
        CPU          = ($cpu.Name -replace '\s+', ' ').Trim()
        MemoryGB     = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        FreeMemoryGB = [Math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        LastBoot     = $os.LastBootUpTime
        UptimeDays   = [Math]::Round($uptime.TotalDays, 1)
        Disks        = @($disks)
        Network      = @($adapters)
        Antivirus    = $antivirus
        RecentUpdates = $updates
        Issues       = @($issues)
        GeneratedAt  = Get-Date
    }

    if ($HtmlPath) {
        ConvertTo-SystemReportHtml -Report $report | Set-Content -Path $HtmlPath -Encoding UTF8
        Write-Verbose "HTML report saved to $HtmlPath"
    }
    $report
}

function ConvertTo-SystemReportHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Report)

    $h = { param($v) ConvertTo-HtmlSafe $v }
    $rows = {
        param($items, [string[]] $props)
        $head = ($props | ForEach-Object { "<th>$(& $h $_)</th>" }) -join ''
        $body = foreach ($i in $items) {
            '<tr>' + (($props | ForEach-Object { "<td>$(& $h $i.$_)</td>" }) -join '') + '</tr>'
        }
        "<table><tr>$head</tr>$($body -join '')</table>"
    }
    $issueHtml = if (@($Report.Issues).Count) {
        '<ul class="issues">' + ((@($Report.Issues) | ForEach-Object { "<li>$(& $h $_)</li>" }) -join '') + '</ul>'
    } else { '<p class="ok">No problems found.</p>' }

    @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>System report: $(& $h $Report.ComputerName)</title>
<style>
body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f6f7fb;color:#1a1d29}
main{max-width:900px;margin:0 auto;padding:24px 16px}
table{border-collapse:collapse;width:100%;background:#fff;margin:8px 0 20px}
td,th{border:1px solid #e3e6ee;padding:6px 10px;text-align:left;vertical-align:top}
th{background:#f0f2f7}.issues li{color:#b42318}.ok{color:#0f7b6c;font-weight:600}
</style></head><body><main>
<h1>System report: $(& $h $Report.ComputerName)</h1>
<p>Generated $(& $h $Report.GeneratedAt) by $(& $h $Report.User)</p>
<h2>Problems found</h2>$issueHtml
<h2>Overview</h2>
<table>
<tr><th>Operating system</th><td>$(& $h $Report.OS)</td></tr>
<tr><th>Hardware</th><td>$(& $h $Report.Manufacturer)</td></tr>
<tr><th>CPU</th><td>$(& $h $Report.CPU)</td></tr>
<tr><th>Memory</th><td>$(& $h $Report.FreeMemoryGB) GB free of $(& $h $Report.MemoryGB) GB</td></tr>
<tr><th>Last boot</th><td>$(& $h $Report.LastBoot) ($(& $h $Report.UptimeDays) days ago)</td></tr>
<tr><th>Antivirus</th><td>$(& $h $Report.Antivirus)</td></tr>
</table>
<h2>Disks</h2>$(& $rows $Report.Disks @('Drive','SizeGB','FreeGB','FreePct','Status'))
<h2>Network</h2>$(& $rows $Report.Network @('Adapter','IPv4','Gateway','DNS','DHCP','MAC'))
<h2>Recent updates</h2>$(& $rows $Report.RecentUpdates @('HotFixID','Description','InstalledOn'))
</main></body></html>
"@
}

#endregion

#region Test-NetworkHealth

function Test-NetworkHealth {
    <#
    .SYNOPSIS
        Works through a "no internet" ticket step by step, from the network adapter up.
    .DESCRIPTION
        Checks, in order: a network adapter is connected, it has a valid IP address
        (not APIPA), the default gateway answers, DNS resolves names, and an internet
        host is reachable on HTTPS. Each step says PASS or FAIL with a plain-language
        next step, and stops at the first failure because later steps depend on it.
    .PARAMETER TestHost
        Name to resolve and connect to for the DNS and internet checks.
    .EXAMPLE
        Test-NetworkHealth
    #>
    [CmdletBinding()]
    param([string] $TestHost = 'www.microsoft.com')

    $results = New-Object Collections.Generic.List[object]
    $add = {
        param($step, $ok, $detail, $advice)
        $results.Add([pscustomobject]@{
            Step   = $step
            Result = if ($ok) { 'PASS' } else { 'FAIL' }
            Detail = $detail
            Advice = if ($ok) { '' } else { $advice }
        })
        $ok
    }

    # 1. Physical / link layer
    $up = @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'NetConnectionStatus=2' -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalAdapter })
    if (-not (& $add 'Network adapter connected' ($up.Count -gt 0) `
                ($(if ($up.Count) { ($up.NetConnectionID -join ', ') } else { 'No connected adapter' })) `
                'Check the cable at both ends or connect to Wi-Fi, and make sure the adapter is enabled.')) {
        return $results
    }

    # 2. IP configuration
    $cfg = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
        Where-Object { $_.DefaultIPGateway })
    $ip = @($cfg | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) | Select-Object -First 1
    $diag = if ($ip) { Get-IPAddressDiagnosis $ip } else { 'None' }
    if (-not (& $add 'Valid IP address' ($ip -and $diag -notin 'APIPA', 'Invalid', 'Unassigned') `
                "IP: $ip ($diag)" `
                'No address from DHCP. Run "ipconfig /release" then "ipconfig /renew"; if it still fails, check the switch port, VLAN or DHCP server.')) {
        return $results
    }

    # 3. Default gateway
    $gateway = @($cfg[0].DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) | Select-Object -First 1
    $gwOk = [bool]$gateway -and (Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue)
    if (-not (& $add 'Default gateway reachable' $gwOk "Gateway: $gateway" `
                'The router is not answering. Check the local network (switch, cable, Wi-Fi) or whether the router is down.')) {
        return $results
    }

    # 4. DNS
    $resolved = $null
    try { $resolved = [Net.Dns]::GetHostAddresses($TestHost) | Select-Object -First 1 } catch { $resolved = $null }
    if (-not (& $add 'DNS resolves names' ([bool]$resolved) "$TestHost -> $resolved" `
                'The network works but names do not resolve. Check the DNS servers in "ipconfig /all" and try "ipconfig /flushdns".')) {
        return $results
    }

    # 5. Internet (HTTPS)
    $tcpOk = $false
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($TestHost, 443)
        $tcpOk = $task.Wait(4000) -and $client.Connected
    } catch { $tcpOk = $false } finally { $client.Dispose() }
    [void](& $add 'Internet reachable (HTTPS)' $tcpOk "$($TestHost):443" `
            'Local network and DNS work but the internet is blocked. Check the firewall, proxy settings or the ISP connection.')
    $results
}

#endregion

#region New-BulkADUser

function New-BulkADUser {
    <#
    .SYNOPSIS
        Creates Active Directory user accounts from a CSV file.
    .DESCRIPTION
        CSV columns: FirstName, LastName, Department, Title (optional: Manager).
        For each row it builds a unique username (first initial + last name), a UPN,
        and a random temporary password, and creates the account forced to change the
        password at first logon.

        Supports -WhatIf: run with -WhatIf first to preview exactly what would be created.
        -WhatIf works on any PC, even without the ActiveDirectory module, so the planned
        usernames can be checked before you go near a domain controller.
    .PARAMETER Path
        The CSV file.
    .PARAMETER Domain
        UPN suffix, e.g. contoso.co.za
    .PARAMETER OU
        Distinguished name of the OU to create users in, e.g. "OU=Staff,DC=contoso,DC=co,DC=za"
    .EXAMPLE
        New-BulkADUser -Path .\new-starters.csv -Domain contoso.co.za -OU "OU=Staff,DC=contoso,DC=co,DC=za" -WhatIf
    .NOTES
        Give temporary passwords to users through a secure channel (in person or by phone),
        never by email, and delete any exported copy once they have been handed over.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateScript({ Test-Path $_ -PathType Leaf })] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')] [string] $Domain,
        [Parameter(Mandatory)] [string] $OU,
        [string[]] $ExistingUsernames
    )

    $rows = @(Import-Csv -Path $Path)
    $required = 'FirstName', 'LastName', 'Department', 'Title'
    if ($rows.Count -gt 0) {
        $missing = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
        if ($missing) { throw "CSV is missing column(s): $($missing -join ', ')" }
    }

    $live = -not $WhatIfPreference
    if ($live -and -not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'The ActiveDirectory module is not installed. Install RSAT, or run with -WhatIf to preview.'
    }
    if ($live) { Import-Module ActiveDirectory -ErrorAction Stop }

    # Usernames already in AD (live) or supplied (for previews/tests), plus ones made in this run.
    $taken = New-Object Collections.Generic.List[string]
    if ($ExistingUsernames) { $taken.AddRange([string[]]$ExistingUsernames) }

    $line = 1
    foreach ($row in $rows) {
        $line++
        $first = "$($row.FirstName)".Trim()
        $last = "$($row.LastName)".Trim()
        if (-not $first -or -not $last) {
            Write-Warning "Line ${line}: missing first or last name, skipped"
            continue
        }

        $sam = ConvertTo-SamAccountName -FirstName $first -LastName $last -Existing $taken
        if ($live) {
            while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                $taken.Add($sam)
                $sam = ConvertTo-SamAccountName -FirstName $first -LastName $last -Existing $taken
            }
        }
        $taken.Add($sam)
        $upn = "$sam@$Domain"
        $display = "$first $last"

        $result = [pscustomobject]@{
            Line              = $line
            DisplayName       = $display
            SamAccountName    = $sam
            UserPrincipalName = $upn
            Department        = $row.Department
            Title             = $row.Title
            Status            = 'Preview'
            TempPassword      = $null
        }

        if ($PSCmdlet.ShouldProcess("$display ($upn) in $OU", 'Create AD user')) {
            $password = New-TempPassword
            try {
                $params = @{
                    Name                  = $display
                    GivenName             = $first
                    Surname               = $last
                    DisplayName           = $display
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    Department            = $row.Department
                    Title                 = $row.Title
                    Path                  = $OU
                    AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
                    ChangePasswordAtLogon = $true
                    Enabled               = $true
                    ErrorAction           = 'Stop'
                }
                if ($row.PSObject.Properties.Name -contains 'Manager' -and $row.Manager) {
                    $params.Manager = $row.Manager
                }
                New-ADUser @params
                $result.Status = 'Created'
                $result.TempPassword = $password
            } catch {
                $result.Status = "Failed: $($_.Exception.Message)"
            }
        }
        $result
    }
}

#endregion

Export-ModuleMember -Function Get-SystemReport, Test-NetworkHealth, New-BulkADUser,
    ConvertTo-SamAccountName, New-TempPassword, Get-IPAddressDiagnosis, Get-DiskStatus,
    ConvertTo-SystemReportHtml
