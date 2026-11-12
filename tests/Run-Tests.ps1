<#
    Self-contained tests: no Pester needed, so they run the same on
    Windows PowerShell 5.1 and PowerShell 7.
    Usage:  .\tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'ITSupportToolkit\ITSupportToolkit.psd1') -Force

$script:passed = 0
$script:failed = 0

function Test-Case([string] $Name, [scriptblock] $Body) {
    try {
        & $Body
        $script:passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Assert-Equal($Actual, $Expected, [string] $What) {
    if ($Actual -cne $Expected) { throw "${What}: expected '$Expected', got '$Actual'" }
}
function Assert-True([bool] $Condition, [string] $What) {
    if (-not $Condition) { throw $What }
}

# ---------- Usernames ----------
Test-Case 'username is first initial + last name, lowercase' {
    Assert-Equal (ConvertTo-SamAccountName 'Nokubonga' 'Nkuna') 'nnkuna' 'basic'
}
Test-Case 'accents, spaces and hyphens are removed' {
    # Accented letters written as character codes so this file stays plain ASCII
    # (Windows PowerShell 5.1 misreads UTF-8 scripts that have no byte-order mark).
    $zoe = "Zo$([char]0x00EB)"        # Zoe with diaeresis
    $emile = "$([char]0x00C9)mile"    # Emile with acute accent
    Assert-Equal (ConvertTo-SamAccountName $zoe 'van der Merwe') 'zvandermerwe' 'accent/spaces'
    Assert-Equal (ConvertTo-SamAccountName 'Lerato' 'Ndlovu-Khumalo') 'lndlovukhumalo' 'hyphen'
    Assert-Equal (ConvertTo-SamAccountName $emile "O'Brien") 'eobrien' 'accent + apostrophe'
}
Test-Case 'duplicates get a number' {
    Assert-Equal (ConvertTo-SamAccountName 'Thandi' 'Mokoena' -Existing @('tmokoena')) 'tmokoena2' 'second'
    Assert-Equal (ConvertTo-SamAccountName 'Tumi' 'Mokoena' -Existing @('tmokoena', 'TMOKOENA2')) 'tmokoena3' 'case-insensitive'
}
Test-Case 'usernames are at most 20 characters, even with a number' {
    $long = ConvertTo-SamAccountName 'Alexandria' 'Wolfeschlegelsteinhausen'
    Assert-Equal $long.Length 20 'length'
    $dup = ConvertTo-SamAccountName 'Alexandria' 'Wolfeschlegelsteinhausen' -Existing @($long)
    Assert-True ($dup.Length -le 20 -and $dup.EndsWith('2')) "duplicate '$dup' should be <= 20 chars and end in 2"
}
Test-Case 'names with no usable letters are rejected' {
    $threw = $false
    try { ConvertTo-SamAccountName '!!' '??' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'should throw'
}

# ---------- Passwords ----------
Test-Case 'temporary passwords meet complexity rules' {
    1..50 | ForEach-Object {
        $p = New-TempPassword
        Assert-Equal $p.Length 16 'length'
        Assert-True ($p -cmatch '[A-Z]') "no upper case in $p"
        Assert-True ($p -cmatch '[a-z]') "no lower case in $p"
        Assert-True ($p -match '\d') "no digit in $p"
        Assert-True ($p -match '[^A-Za-z0-9]') "no symbol in $p"
        Assert-True ($p -cnotmatch '[0O1lI]') "look-alike character in $p"
    }
}
Test-Case 'passwords are random and length is configurable' {
    $set = @{}
    1..200 | ForEach-Object { $set[(New-TempPassword)] = $true }
    Assert-Equal $set.Count 200 'all 200 should differ'
    Assert-Equal (New-TempPassword -Length 24).Length 24 'custom length'
}

# ---------- IP diagnosis ----------
Test-Case 'IP addresses are diagnosed correctly' {
    Assert-Equal (Get-IPAddressDiagnosis '169.254.10.5') 'APIPA' 'APIPA'
    Assert-Equal (Get-IPAddressDiagnosis '192.168.1.20') 'Private' '192.168'
    Assert-Equal (Get-IPAddressDiagnosis '172.16.0.1') 'Private' '172.16'
    Assert-Equal (Get-IPAddressDiagnosis '172.32.0.1') 'Public' '172.32 is public'
    Assert-Equal (Get-IPAddressDiagnosis '10.0.0.5') 'Private' '10/8'
    Assert-Equal (Get-IPAddressDiagnosis '127.0.0.1') 'Loopback' 'loopback'
    Assert-Equal (Get-IPAddressDiagnosis '8.8.8.8') 'Public' 'public'
    Assert-Equal (Get-IPAddressDiagnosis '300.1.1.1') 'Invalid' 'invalid'
    Assert-Equal (Get-IPAddressDiagnosis '::1') 'Invalid' 'IPv6 not handled'
}

# ---------- Disk status ----------
Test-Case 'disk space thresholds' {
    Assert-Equal (Get-DiskStatus -FreeBytes 100GB -TotalBytes 500GB) 'OK' '20%'
    Assert-Equal (Get-DiskStatus -FreeBytes 50GB -TotalBytes 500GB) 'Warning' '10%'
    Assert-Equal (Get-DiskStatus -FreeBytes 20GB -TotalBytes 500GB) 'Critical' '4%'
    Assert-Equal (Get-DiskStatus -FreeBytes 1.5GB -TotalBytes 20GB) 'Critical' 'under 2 GB'
    Assert-Equal (Get-DiskStatus -FreeBytes 0 -TotalBytes 0) 'Unknown' 'no size'
}

# ---------- Bulk users ----------
Test-Case 'bulk user preview (-WhatIf) plans unique accounts without AD' {
    $csv = Join-Path $root 'examples\new-starters.csv'
    $plan = @(New-BulkADUser -Path $csv -Domain 'contoso.co.za' -OU 'OU=Staff,DC=contoso,DC=co,DC=za' `
            -ExistingUsernames 'tmokoena' -WhatIf 3>$null)
    Assert-Equal $plan.Count 6 'six rows'
    $names = $plan | ForEach-Object { $_.SamAccountName }
    Assert-Equal ($names -join ',') 'tmokoena2,sdlamini,tmokoena3,tmokoena4,zvandermerwe,lndlovukhumalo' 'usernames'
    Assert-Equal $plan[1].UserPrincipalName 'sdlamini@contoso.co.za' 'UPN'
    Assert-True (@($plan | Where-Object { $_.Status -ne 'Preview' -or $_.TempPassword }).Count -eq 0) 'preview creates nothing'
}
Test-Case 'bulk user import rejects a CSV with missing columns' {
    $bad = Join-Path ([IO.Path]::GetTempPath()) "bad-$([guid]::NewGuid()).csv"
    'FirstName,LastName' , 'A,B' | Set-Content $bad
    try {
        $threw = $false
        try { New-BulkADUser -Path $bad -Domain 'contoso.co.za' -OU 'OU=x' -WhatIf | Out-Null }
        catch { $threw = $_.Exception.Message -like '*Department*' }
        Assert-True $threw 'should name the missing columns'
    } finally { Remove-Item $bad -ErrorAction SilentlyContinue }
}

# ---------- Report ----------
Test-Case 'system report runs on this computer' {
    $r = Get-SystemReport
    Assert-True ([bool]$r.ComputerName) 'computer name'
    Assert-True ($r.MemoryGB -gt 0) 'memory'
    Assert-True (@($r.Disks).Count -ge 1) 'at least one disk'
}
Test-Case 'HTML report escapes values (no HTML injection)' {
    $fake = [pscustomobject]@{
        ComputerName = '<script>alert(1)</script>'; User = 'u'; OS = 'os'; Manufacturer = 'm'; CPU = 'c'
        MemoryGB = 8; FreeMemoryGB = 4; LastBoot = Get-Date; UptimeDays = 1; Antivirus = 'on'
        Disks = @(); Network = @(); RecentUpdates = @(); Issues = @('Drive <C:> low'); GeneratedAt = Get-Date
    }
    $html = ConvertTo-SystemReportHtml -Report $fake
    Assert-True ($html -notmatch '<script>') 'raw script tag present'
    Assert-True ($html -match '&lt;script&gt;') 'escaped tag missing'
    Assert-True ($html -match 'Drive &lt;C:&gt; low') 'issue not escaped'
}

Write-Host ""
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
