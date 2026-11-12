# IT Support Toolkit (PowerShell)

PowerShell tools for everyday helpdesk work, based on the tasks I handle in IT support:
checking a PC's health, working through "no internet" tickets, and onboarding new staff
into Active Directory.

Works on **Windows PowerShell 5.1** (built into Windows 10/11) and **PowerShell 7**.

## The tools

### `Get-SystemReport`: PC health and inventory
Collects what a technician usually asks for first, and flags problems:

- OS and build, hardware model, CPU, memory, uptime and last boot
- Disk space per drive, rated **OK / Warning / Critical**
- Network adapters: IP, gateway, DNS, DHCP, MAC (flags **APIPA** addresses)
- Microsoft Defender status and signature age
- Recently installed Windows updates (flags none in 45 days)
- Long uptime (suggests a restart)

```powershell
Get-SystemReport
Get-SystemReport -HtmlPath "$env:USERPROFILE\Desktop\pc-report.html"   # attach to a ticket
```

### `Test-NetworkHealth`: "no internet" troubleshooter
Works up the network stack and stops at the first failure, with a plain-language next step:

```
Step                       Result Detail
----                       ------ ------
Network adapter connected  PASS   Wi-Fi
Valid IP address           PASS   IP: 172.20.10.2 (Private)
Default gateway reachable  PASS   Gateway: 172.20.10.1
DNS resolves names         PASS   www.microsoft.com -> 2.22.193.236
Internet reachable (HTTPS) PASS   www.microsoft.com:443
```

If a step fails, the `Advice` column says what to do. For example, an APIPA address leads to
`ipconfig /release` and `/renew`, then checking the switch port, VLAN or DHCP server.

### `New-BulkADUser`: onboard new staff from a CSV
Creates Active Directory accounts from a spreadsheet of new starters
([example CSV](examples/new-starters.csv)):

- Builds usernames as first initial + last name, removing accents, spaces and hyphens
  (`Zoë van der Merwe` becomes `zvandermerwe`), keeping them under AD's 20-character limit
- Handles duplicates: `tmokoena`, `tmokoena2`, `tmokoena3`, ...
- Generates a strong temporary password per user with a **cryptographically secure** generator,
  and forces a password change at first logon
- **`-WhatIf` preview:** shows exactly what would be created, without touching AD. It even works on a PC without the AD module

```powershell
# Always preview first
New-BulkADUser -Path .\examples\new-starters.csv -Domain contoso.co.za `
    -OU "OU=Staff,DC=contoso,DC=co,DC=za" -WhatIf

# Then create the accounts (needs the ActiveDirectory module / RSAT and rights to create users)
New-BulkADUser -Path .\new-starters.csv -Domain contoso.co.za -OU "OU=Staff,DC=contoso,DC=co,DC=za"
```

> Hand temporary passwords to users through a secure channel (in person or by phone), never by email.

## Install

```powershell
Import-Module .\ITSupportToolkit\ITSupportToolkit.psd1
Get-Command -Module ITSupportToolkit
Get-Help New-BulkADUser -Full
```

## Tests

```powershell
.\tests\Run-Tests.ps1
```

13 tests cover username rules (accents, duplicates, length limit), password strength and
randomness, IP diagnosis, disk thresholds, the bulk-user preview, CSV validation, a live
system report, and HTML escaping in reports. The tests need no extra modules, and GitHub
Actions runs them on both Windows PowerShell 5.1 and PowerShell 7, plus PSScriptAnalyzer
(PowerShell's code-quality checker), on every push.

## What I practised

- PowerShell functions with comment-based help, `-WhatIf` / `ShouldProcess` and pipeline-friendly output
- Querying Windows with CIM/WMI (`Win32_OperatingSystem`, `Win32_LogicalDisk`, `Win32_NetworkAdapterConfiguration`)
- Active Directory account provisioning and naming conventions
- Secure coding: secure random passwords, HTML-encoding report output, validating input
- Structured troubleshooting (bottom-up through the OSI model)
