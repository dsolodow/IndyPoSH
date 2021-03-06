<#
	NAME: Profile.ps1
	AUTHOR: Damien Solodow
	CONTACT: dsolodow@outlook.com or @dsolodow
	COMMENT:  intended for use as $profile.CurrentUserAllHosts
#>

#region Global variables for environment specific settings
$beserver = 'ServerName' # Symantec Backup Exec server; BEMCLI is in BE 2012+
$xa7ddc = 'ServerName' # Citrix Delivery Controller (7.x)
$sharepoint2013 = 'ServerName'  # Microsoft SharePoint 2013 (On-Premise); the server selected needs to be a member of the farm you want to work with
$vcenter = 'ServerName' # VMware vCenter Server.
$excas = 'ServerName' # On Premise Exchange; this should be the name of one of your CAS servers. Tested with Exchange 2010+
$orionserver = 'ServerName' # SolarWinds Orion. Needs to be the actual server name if you have this URL behind a load balancer
$smtpserver = 'YourSMTPServer' # SMTP server you want to use to send email
$adminusername = 'YourAdminAccountUserName' # If you have a separate user account for admin type tasks, provide the DOMAIN\USERNAME here
$o365adminusername = 'YourOffice365UserName' # A global admin account for your tenant
$sccmserver = 'YourManagementPoint'
#endregion

#region version specific settings/functions
If ($PSVersionTable.PSVersion -ge '3.0') {
    #set default parameters on various commands
    $PSDefaultParameterValues = @{
        'Format-Table:AutoSize'       = $True;
        'Send-MailMessage:SmtpServer' = $SMTPserver;
        'Help:ShowWindow'             = $True;
    }
    $Env:ADPS_LoadDefaultDrive = 0 #prevents the ActiveDirectory module from auto creating the AD: PSDrive
}
#endregion

#region host specific settings/functions
If ($host.Name -eq 'ConsoleHost') {
    If ($PSVersionTable.PSVersion -ge '3.0') {
        Import-Module -Name 'PSReadLine' -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key Enter -Function AcceptLine
        Set-PSReadLineOption -BellStyle None
    }
} ElseIf ($host.Name -eq 'Windows PowerShell ISE Host') {
    $host.PrivateData.IntellisenseTimeoutInSeconds = 5
    $ISEModules = 'ISEScriptingGeek', 'PsISEProjectExplorer'
    Import-Module -Name $ISEModules -ErrorAction SilentlyContinue
} ElseIf ($host.Name -eq 'Visual Studio Code Host') {
    Import-Module -Name 'EditorServicesCommandSuite' -ErrorAction SilentlyContinue
    Import-EditorCommand -Module 'EditorServicesCommandSuite' -ErrorAction SilentlyContinue
}
#endregion

#region PSDrives
New-PSDrive -Name 'MyDocs' -PSProvider FileSystem -Root (Get-ItemProperty -Path 'HKCU:\software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').Personal -ErrorAction SilentlyContinue | Out-Null
#endregion

#region Functions
# These could be split out into a script module if desired.

Function Set-DigitalSignature {
    # you can get a code signing cert from your internal CA or one of the public ones
    Param ([parameter(Mandatory = $true, Position = 0)][String]$filename)
    $codecert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert
    If (-not($codecert)) {
        Write-Warning -Message "You don't have a code signing certificate installed"
    } Else {
        Set-AuthenticodeSignature -Certificate $codecert -TimestampServer 'http://timestamp.digicert.com' -FilePath $filename
    }
}

Function Get-AdminCred {
    # stuff your admin account credentials into a variable for use later
    If (-not($admin)) {
        $global:admin = Get-Credential -Credential $adminusername
    }
}
New-Alias -Name 'sudo' -Value 'Get-AdminCred'

Function Get-O365AdminCred {
    # stuff your Office 365 admin account credentials into a variable for use later
    If (-not($o365admin)) {
        $global:o365admin = Get-Credential -Credential $o365adminusername
    }
}

Function Start-Elevated {
    # let's you start a process/app as if you chose Run As Administrator
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)] [String]$FilePath,
        [parameter(Mandatory = $false, ValueFromRemainingArguments = $true, Position = 1)] [String[]]$ArgumentList
    )
    Start-Process -verb RunAs @PSBoundParameters
}

Function Sync-AD {
    # let's you trigger a replication between DCs. This function needs further tweaks for re-usability
    [CmdletBinding()]
    Param (
        [parameter(Mandatory = $false, Position = 0)] [String]$DestinationDC = 'centralDC',
        [parameter(Mandatory = $false, Position = 1)] [String]$SourceDC = 'localDC',
        [parameter(Mandatory = $false, Position = 2)] [String]$DirectoryPartition = 'YourDomainName'
    )
    Get-AdminCred
    Start-Process -Credential $admin -FilePath repadmin -ArgumentList "/replicate $DestinationDC $SourceDC $DirectoryPartition" -WindowStyle Hidden
}

Function Add-Equallogic {
    # This needs the Host Integration Tools installed.
    If (-not(Get-ChildItem -Path 'HKLM:\Software\EqualLogic\PSG' -ErrorAction SilentlyContinue)) {
        Write-Warning 'No group configured; you need to run New-EqlGroupAccess in an elevated PowerShell session before you can use the EQL cmdlets'
    }
    if (-not (Get-Module -Name 'eqlpstools')) {
        Import-Module -Name 'C:\Program Files\EqualLogic\bin\EqlPSTools.dll'
        $EQLArrayName = (Get-ChildItem -Path 'HKLM:\Software\EqualLogic\PSG').pschildname
        Write-Host -Object "Connect to the array with Connect-EqlGroup -Groupname $EQLArrayName" -Foregroundcolor yellow
    }
}
Function Add-VMware {
    Function global:Connect-VMware {
        If (-not($viadmin)) {
            $viadmin = Get-Credential -UserName 'custcbb\gayloradmin01' -Message 'Password in Secret Server'
        }
        Connect-VIServer -Server $vcenter -Credential $viadmin
    }
    Function global:Enable-VMMemHotAdd($VM) {
        $vmview = Get-VM $vm | Get-View
        $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $extra = New-Object VMware.Vim.optionvalue
        $extra.Key = "mem.hotadd"
        $extra.Value = "true"
        $vmConfigSpec.extraconfig += $extra
        $vmview.ReconfigVM($vmConfigSpec)
    }
    Function global:Update-VMHardwareVersion($VM) {
        $vm1 = Get-VM -Name $vm
        $spec = New-Object -TypeName VMware.Vim.VirtualMachineConfigSpec
        $spec.ScheduledHardwareUpgradeInfo = New-Object -TypeName VMware.Vim.ScheduledHardwareUpgradeInfo
        $spec.ScheduledHardwareUpgradeInfo.UpgradePolicy = 'onSoftPowerOff'
        $spec.ScheduledHardwareUpgradeInfo.VersionKey = 'vmx-11'
        $vm1.ExtensionData.ReconfigVM_Task($spec)
    }
    Function global:Enable-VMChangeBlockTracking($VM) {
        New-AdvancedSetting -Entity (Get-VM -Name $VM) -Name changeTrackingEnabled -Value true -Force -Confirm:0
    }
    Function global:Disable-VMChangeBlockTracking($VM) {
        New-AdvancedSetting -Entity (Get-VM -Name $VM) -Name changeTrackingEnabled -Value false -Force -Confirm:0
    }
    Function global:Find-OutdatedVMTools {
        Get-VM | Where-Object {$_.ExtensionData.Guest.ToolsStatus -eq "toolsOld"}
    }
}
Function Connect-Exchange {
    <#
    .Synopsis
       Import commands for Exchange on-premise
    .DESCRIPTION
       Implicit remoting to Exchange 2016 on-premise for working with local Exchange
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [System.Management.Automation.PSCredential]$Credential
    )
    Begin {
        If (-Not(Get-PSSession -Name 'Exchange2016' -ErrorAction SilentlyContinue)) {
            $Ex2016 = @{
                'Name'              = 'Exchange2016'
                'ConfigurationName' = 'Microsoft.Exchange'
                'ConnectionURI'     = "http://$excas/powershell/"
                'Authentication'    = 'Kerberos'
            }
            If ($Credential) {
                $Ex2016['Credential'] = $Credential
            }
            $EX2016Session = New-PSSession @Ex2016
            If (Get-PSSession -Name 'Exchange2016' -ErrorAction SilentlyContinue) {
                Import-Module(Import-PSSession -Session $EX2016Session -DisableNameChecking) -Global -DisableNameChecking
            }
        }
    }
}

Function Connect-ExchangeOnline {
    <#
    .Synopsis
       Import commands for Exchange Online (Office 365). Prefixes nouns with EO to avoid clobbering local Exchange
    .DESCRIPTION
       Implicit remoting to Exchange Online for working with Office 365 mailboxes. Prefixes nouns with EO to avoid clobbering local Exchange
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.Management.Automation.PSCredential]$Credential
    )
    Begin {
        If (-Not(Get-PSSession -Name 'ExchangeOnline' -ErrorAction SilentlyContinue)) {
            $EO = @{
                'Name'              = 'ExchangeOnline'
                'ConfigurationName' = 'Microsoft.Exchange'
                'ConnectionURI'     = 'https://outlook.office365.com/powershell-liveid/'
                'Authentication'    = 'Basic'
                'AllowRedirection'  = $true
            }
            $EOSession = New-PSSession  @EO -Credential $Credential
            If (Get-PSSession -Name 'ExchangeOnline' -ErrorAction SilentlyContinue) {
                Import-Module(Import-PSSession -Session $EOSession -DisableNameChecking -Prefix EO) -Prefix EO -DisableNameChecking -Global
            }

        }
    }
}
Function Add-Orion {
    If (-not(Get-Module -Name 'SwisPowerShell')) {
        Function global:Connect-Orion {
            $global:orion = Connect-Swis -Hostname $orionserver -Trusted
        }
        Function global:Disable-OrionNode($swnode) {
            $now = [DateTime]::Now
            $swnodeid = Get-SwisData -SwisConnection $orion -Query 'Select NodeID From Orion.Nodes Where NodeName = @h'@{h = $swnode}
            Invoke-SwisVerb -SwisConnection $orion -EntityName Orion.Nodes -Verb Unmanage @("N:$swnodeid", $now, $now.AddHours(4), $True)
        }
        Function global:Enable-OrionNode($swnode) {
            $now = [DateTime]::Now
            $swnodeid = Get-SwisData -SwisConnection $orion -Query 'Select NodeID From Orion.Nodes Where NodeName = @h'@{h = $swnode}
            Invoke-SwisVerb -SwisConnection $orion -EntityName Orion.Nodes -Verb Remanage @("N:$swnodeid", $now, $True)
        }
    }
}

Function Add-XenApp {
    If (-Not(Get-PSSession -Name 'XenApp' -ErrorAction SilentlyContinue)) {
        Get-AdminCred
        $xa = New-PSSession -ComputerName $xa7ddc -Credential $admin -Name 'XenApp'
        Invoke-Command -Session $xa -ScriptBlock {Add-PSSnapin -Name 'Citrix.*'}
        Import-PSSession -Session $xa -Module 'Citrix.*' -FormatTypeName * | Out-Null
    }
}

Function Add-BackupExec {
    If (-Not(Get-PSSession -Name 'BackupExec' -ErrorAction SilentlyContinue)) {
        Get-AdminCred
        $be = New-PSSession -ComputerName $beserver -Credential $admin -Name BackupExec
        Invoke-Command -Session $be -ScriptBlock {Import-Module -Name 'bemcli'}
        Import-PSSession -Session $be -Module 'bemcli' -FormatTypeName * | Out-Null
    }
}

Function Add-SharePoint {
    # this needs to connect to a server in the farm, AND it needs to use CredSSP due to the number of cmdlets that have to hop to SQL. CredSSP needs to be setup on both client and server
    If (-Not(Get-PSSession -Name 'SharePoint2013' -ErrorAction SilentlyContinue)) {
        Get-AdminCred
        $spps = New-PSSession -ComputerName $sharepoint2013 -Authentication CredSSP -Credential $admin -Name SharePoint2013
        Invoke-Command -Session $spps -ScriptBlock {Add-PSSnapin -Name 'Microsoft.SharePoint.PowerShell'}
        Import-PSSession -Session $spps -Module 'Microsoft.SharePoint.PowerShell' -FormatTypeName * -DisableNameChecking
    }
}

Function Add-SCCM {
    Get-AdminCred
    <#
	The registry key here is to disable autocreate of the PSDrive when loading the ConfigrationManager module.
    This allows mapping the drive with alternate credentials, but is only honored by ConfigMgr 1710 and higher
    #>
    $cmkey = 'HKCU:\Software\Microsoft\ConfigMgr10\PowerShell'
    $cmval = 'DisableCMDriveAutoCreate'
    If (-not(Test-Path $cmkey)) {
        New-Item -Path $cmkey -Force | Out-Null
    }
    If (-not(Get-ItemProperty -Path $cmkey -Name $cmval)) {
        New-ItemProperty -Path $cmkey -Name $cmval -PropertyType DWORD -Value 1
    }
    If (-not(Get-Module -Name 'ConfigurationManager')) {
        Import-Module -Name 'ConfigurationManager'
        If ((Test-Path -Path 'PRI:') -eq $false) {
            New-PSDrive -Name PRI -PSProvider CMSite -Root $sccmserver -Credential $admin -Scope Global
        }
    }
}