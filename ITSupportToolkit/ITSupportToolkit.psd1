@{
    RootModule        = 'ITSupportToolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6f3c2a1e-8b4d-4c7a-9e2f-1d5b7a9c3e40'
    Author            = 'Nokubonga Nkuna'
    Description       = 'Everyday helpdesk tasks: PC health report, network troubleshooter and bulk Active Directory onboarding.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-SystemReport', 'Test-NetworkHealth', 'New-BulkADUser',
        'ConvertTo-SamAccountName', 'New-TempPassword', 'Get-IPAddressDiagnosis', 'Get-DiskStatus',
        'ConvertTo-SystemReportHtml'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
