$ErrorActionPreference = "Stop"
$resourcesDir = "$ENV:SystemDrive\UnattendResources"
$configIniPath = "$resourcesDir\config.ini"
$UH_IaaS_settings = $true

function Set-PersistDrivers {
    Param(
    [parameter(Mandatory=$true)]
    [string]$Path,
    [switch]$Persist=$true
    )
    if (!(Test-Path $Path)) {
        return $false
    }
    try {
        $xml = [xml](Get-Content $Path)
    } catch {
        Write-Error "Failed to load $Path"
        return $false
    }
    if (!$xml.unattend.settings) {
        return $false
    }
    foreach ($i in $xml.unattend.settings) {
        if ($i.pass -eq "generalize") {
            $index = [array]::IndexOf($xml.unattend.settings, $i)
            if ($xml.unattend.settings[$index].component -and $xml.unattend.settings[$index].component.PersistAllDeviceInstalls -ne $Persist.ToString()) {
                $xml.unattend.settings[$index].component.PersistAllDeviceInstalls = $Persist.ToString()
            }
        }
    }
    $xml.Save($Path)
}

function Set-UnattendEnableSwap {
    Param(
    [parameter(Mandatory=$true)]
    [string]$Path
    )
    if (!(Test-Path $Path)) {
        return $false
    } try {
        $xml = [xml](Get-Content $Path)
    } catch {
        Write-Error "Failed to load $Path"
        return $false
    }
    if (!$xml.unattend.settings) {
        return $false
    }
    foreach ($i in $xml.unattend.settings) {
        if ($i.pass -eq "specialize") {
            $index = [array]::IndexOf($xml.unattend.settings, $i)
            if ($xml.unattend.settings[$index].component.RunSynchronous.RunSynchronousCommand.Order) {
                $xml.unattend.settings[$index].component.RunSynchronous.RunSynchronousCommand.Order = "2"
            }
            [xml]$RunSynchronousCommandXml = @"
        <RunSynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Path>"C:\Windows\System32\reg.exe" ADD "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v "PagingFiles" /d "?:\pagefile.sys" /f</Path>
          <Description>Set page file to be automatically managed by the system</Description>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
"@
          $xml.unattend.settings[$index].component.RunSynchronous.AppendChild($xml.ImportNode($RunSynchronousCommandXml.RunSynchronousCommand, $true))
        }
    }
    $xml.Save($Path)
}

function Clean-UpdateResources {
    $HOST.UI.RawUI.WindowTitle = "Running update resources cleanup"
    # We're done, disable AutoLogon
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name Unattend*
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount -ErrorAction SilentlyContinue

    # Cleanup
    Remove-Item -Recurse -Force $resourcesDir
    Remove-Item -Force "$ENV:SystemDrive\Unattend.xml"

}

function Clean-WindowsUpdates {
    Param(
        $PurgeUpdates
    )
    $HOST.UI.RawUI.WindowTitle = "Running Dism cleanup..."
    if (([System.Environment]::OSVersion.Version.Major -gt 6) -or ([System.Environment]::OSVersion.Version.Minor -ge 2))
    {
        if (!$PurgeUpdates) {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup
        } else {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
        }
        if ($LASTEXITCODE) {
            throw "Dism.exe clean failed"
        }
    }
}

function Run-Defragment {
    $HOST.UI.RawUI.WindowTitle = "Running Defrag..."
    #Defragmenting all drives at normal priority
    defrag.exe /C /H /V
    if ($LASTEXITCODE) {
        throw "Defrag.exe failed"
    }
}

function Release-IP {
    $HOST.UI.RawUI.WindowTitle = "Releasing IP..."
    ipconfig.exe /release
    if ($LASTEXITCODE) {
            throw "IPconfig release failed"
        }
}

function Install-WindowsUpdates {
    Import-Module "$resourcesDir\WindowsUpdates\WindowsUpdates"
    $BaseOSKernelVersion = [System.Environment]::OSVersion.Version
    $OSKernelVersion = ($BaseOSKernelVersion.Major.ToString() + "." + $BaseOSKernelVersion.Minor.ToString())

    #Note (cgalan): Some updates are black-listed as they are either failing to install or superseeded by the newer updates.
    $KBIdsBlacklist = @{
        "6.3" = @("KB2887595")
    }
    $excludedUpdates = $KBIdsBlacklist[$OSKernelVersion]
    $updates = ExecRetry {
        Get-WindowsUpdate -Verbose -ExcludeKBId $excludedUpdates
    } -maxRetryCount 30 -retryInterval 1
    $maximumUpdates = 100
    if (!$updates.Count) {
        $updates = [array]$updates
    }
    if ($updates) {
        $availableUpdatesNumber = $updates.Count
        Write-Host "Found $availableUpdatesNumber updates. Installing..."
        try {
            #Note (cgalan): In case the update fails, we need to reboot the instance in order for the updates
            # to be retrieved on a changed system state and be applied correctly.
            Install-WindowsUpdate -Updates $updates[0..$maximumUpdates]
         } finally {
            Restart-Computer -Force
            exit 0
         }
    }
}

function ExecRetry($command, $maxRetryCount=4, $retryInterval=4) {
    $currErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $retryCount = 0
    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $command
            $ErrorActionPreference = $currErrorActionPreference
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -ge $maxRetryCount) {
                $ErrorActionPreference = $currErrorActionPreference
                throw
            } else {
                if($_) {
                Write-Warning $_
                }
                Start-Sleep $retryInterval
            }
        }
    }
}

function Disable-Swap {
    $computerSystem = Get-WmiObject Win32_ComputerSystem
    if ($computerSystem.AutomaticManagedPagefile) {
        $computerSystem.AutomaticManagedPagefile = $False
        $computerSystem.Put()
    }
    $pageFileSetting = Get-WmiObject Win32_PageFileSetting
    if ($pageFileSetting) {
        $pageFileSetting.Delete()
    }
}

function UH_IaaS {
  # Enable linux clients to log on via RDP
  (Get-WmiObject -class Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -ComputerName $env:ComputerName -Filter "TerminalName='RDP-tcp'").SetUserAuthenticationRequired(0)

  # Disable IPv6 transition technologies
  Set-Net6to4Configuration -State disabled
  Set-NetTeredoConfiguration -Type disabled
  Set-NetIsatapConfiguration -State disabled

  # Disable IPv6 Router autoconfig
  Set-NetIPInterface ethernet -AddressFamily ipv6 -RouterDiscovery Disabled

  # Set correct timezone
  Set-TimeZone -Id "W. Europe Standard Time"

  # Enable Build-In Component Cleanup for weekly execution
  $trigger = New-ScheduledTaskTrigger -Weekly -AT "03:00" -DaysOfWeek 'Saturday' -RandomDelay (New-TimeSpan -Hours 4)
  Set-ScheduledTask -TaskName "\Microsoft\Windows\Servicing\StartComponentCleanup" -Trigger $trigger
  Enable-ScheduledTask -TaskName "\Microsoft\Windows\Servicing\StartComponentCleanup"

  # Create and enable a task for some housecleaning
  $trigger2 = New-ScheduledTaskTrigger -Weekly -AT "03:00" -DaysOfWeek 'Thursday' -RandomDelay (New-TimeSpan -Hours 3)
  $STPrin = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
  $Stask = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "c:\windows\cleanup.ps1"
  Register-ScheduledTask Cleanup -Action $Stask -Principal $STPrin -Trigger $trigger2

  # Disable startup of Server Manager on Logon on non-core installs
  $winedition = $(Get-WindowsEdition -Online).Edition
  if ($winedition -eq "ServerStandard") {
    Disable-ScheduledTask -TaskName "\Microsoft\Windows\Server Manager\ServerManager"
  }

  $startuptask = @'
# Disable Administrator Account
Disable-LocalUser -Name "Administrator"

# Force the local interface to use the "public" profile
Set-NetConnectionProfile -Name "Network" -NetworkCategory Public

$kmsserver="tjur.uib.no"
$nettest=(Test-NetConnection -ComputerName $kmsserver -Port 1688)
if ($nettest.TcpTestSucceeded -eq $true)
  {Write-Host "Connection to kms host succesful - trying to activate windows."
  cscript c:\windows\system32\slmgr.vbs /skms $kmsserver
  cscript c:\windows\system32\slmgr.vbs /ato }
Else {Write-Host "Connection to kms host failed - not activating."}

# Enable and start ssh if Windows Version is 2019 or newer
# Comment out two lines in default sshd_config to enable passwordless logon
$winbuild=$([System.Environment]::OSVersion.Version.Build)
if ($winbuild -gt 17760) {
  Write-Host "Build is 2019 or newer"
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  Set-Service sshd -StartupType Automatic
  Set-Service ssh-agent -StartupType Automatic
  Start-Service sshd
  Start-Service ssh-agent
  $line = Get-Content "C:\ProgramData\ssh\sshd_config" | Select-String "Match Group administrators" | Select-Object -ExpandProperty Line
  $line2 = Get-Content "C:\ProgramData\ssh\sshd_config" | Select-String "AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators" | Select-Object -ExpandProperty Line
  $sshconfig = Get-Content "C:\ProgramData\ssh\sshd_config"
  $sshconfig | ForEach-Object {$_ -replace $line,"#Match Group administrators"} | Set-Content "C:\ProgramData\ssh\sshd_config"
  $sshconfig = Get-Content "C:\ProgramData\ssh\sshd_config"
  $sshconfig | ForEach-Object {$_ -replace $line2,"#       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"} | Set-Content "C:\ProgramData\ssh\sshd_config"
  Restart-Service sshd
  }
Else {Write-Host "Build is to old for ssh server"}
'@
$startuptask | Out-File "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\extraconf.ps1"

  $mytask = @'
Function Cleanup { 
<# 
.CREATED BY: 
    Matthew A. Kerfoot 
.CREATED ON: 
    10\17\2013 
.Synopsis 
   Aautomate cleaning up a C: drive with low disk space 
.DESCRIPTION 
   Cleans the C: drive's Window Temperary files, Windows SoftwareDistribution folder, ` 
   the local users Temperary folder, IIS logs(if applicable) and empties the recycling bin. ` 
   All deleted files will go into a log transcript in C:\Windows\Temp\. By default this ` 
   script leaves files that are newer than 7 days old however this variable can be edited. 
.EXAMPLE 
   PS C:\Users\mkerfoot\Desktop\Powershell> .\cleanup_log.ps1 
   Save the file to your desktop with a .PS1 extention and run the file from an elavated PowerShell prompt. 
.NOTES 
   This script will typically clean up anywhere from 1GB up to 15GB of space from a C: drive. 
.FUNCTIONALITY 
   PowerShell v3 
#> 
function global:Write-Verbose ( [string]$Message ) 
 
# check $VerbosePreference variable, and turns -Verbose on 
{ if ( $VerbosePreference -ne 'SilentlyContinue' ) 
{ Write-Host " $Message" -ForegroundColor 'Yellow' } } 
 
$VerbosePreference = "Continue" 
$DaysToDelete = 1 
$LogDate = get-date -format "MM-d-yy-HH" 
$objShell = New-Object -ComObject Shell.Application  
$objFolder = $objShell.Namespace(0xA) 
$ErrorActionPreference = "silentlycontinue" 
                     
Start-Transcript -Path C:\Windows\Temp\$LogDate.log 
 
## Cleans all code off of the screen. 
Clear-Host 
 
$size = Get-ChildItem C:\Users\* -Include *.iso, *.vhd -Recurse -ErrorAction SilentlyContinue |  
Sort Length -Descending |  
Select-Object Name, 
@{Name="Size (GB)";Expression={ "{0:N2}" -f ($_.Length / 1GB) }}, Directory | 
Format-Table -AutoSize | Out-String 
 
$Before = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq "3" } | Select-Object SystemName, 
@{ Name = "Drive" ; Expression = { ( $_.DeviceID ) } }, 
@{ Name = "Size (GB)" ; Expression = {"{0:N1}" -f( $_.Size / 1gb)}}, 
@{ Name = "FreeSpace (GB)" ; Expression = {"{0:N1}" -f( $_.Freespace / 1gb ) } }, 
@{ Name = "PercentFree" ; Expression = {"{0:P1}" -f( $_.FreeSpace / $_.Size ) } } | 
Format-Table -AutoSize | Out-String                       
                     
## Stops the windows update service.  
Get-Service -Name wuauserv | Stop-Service -Force -Verbose -ErrorAction SilentlyContinue 
## Windows Update Service has been stopped successfully! 
 
## Deletes the contents of windows software distribution. 
Get-ChildItem "C:\Windows\SoftwareDistribution\*" -Recurse -Force -Verbose -ErrorAction SilentlyContinue | remove-item -force -Verbose -recurse -ErrorAction SilentlyContinue 
## The Contents of Windows SoftwareDistribution have been removed successfully! 
 
## Deletes the contents of the Windows Temp folder. 
Get-ChildItem "C:\Windows\Temp\*" -Recurse -Force -Verbose -ErrorAction SilentlyContinue | 
Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-$DaysToDelete)) } | 
remove-item -force -Verbose -recurse -ErrorAction SilentlyContinue 
## The Contents of Windows Temp have been removed successfully! 
              
## Delets all files and folders in user's Temp folder.  
Get-ChildItem "C:\users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | 
Where-Object { ($_.CreationTime -lt $(Get-Date).AddDays(-$DaysToDelete))} | 
remove-item -force -Verbose -recurse -ErrorAction SilentlyContinue 
## The contents of C:\users\$env:USERNAME\AppData\Local\Temp\ have been removed successfully! 
                     
## Remove all files and folders in user's Temporary Internet Files.  
Get-ChildItem "C:\users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" ` 
-Recurse -Force -Verbose -ErrorAction SilentlyContinue | 
Where-Object {($_.CreationTime -le $(Get-Date).AddDays(-$DaysToDelete))} | 
remove-item -force -recurse -ErrorAction SilentlyContinue 
## All Temporary Internet Files have been removed successfully! 
                     
## Cleans IIS Logs if applicable. 
Get-ChildItem "C:\inetpub\logs\LogFiles\*" -Recurse -Force -ErrorAction SilentlyContinue | 
Where-Object { ($_.CreationTime -le $(Get-Date).AddDays(-60)) } | 
Remove-Item -Force -Verbose -Recurse -ErrorAction SilentlyContinue 
## All IIS Logfiles over x days old have been removed Successfully! 
                   
## deletes the contents of the recycling Bin. 
## The Recycling Bin is now being emptied! 
$objFolder.items() | ForEach-Object { Remove-Item $_.path -ErrorAction Ignore -Force -Verbose -Recurse } 
## The Recycling Bin has been emptied! 
 
## Starts the Windows Update Service 
##Get-Service -Name wuauserv | Start-Service -Verbose 
 
$After =  Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq "3" } | Select-Object SystemName, 
@{ Name = "Drive" ; Expression = { ( $_.DeviceID ) } }, 
@{ Name = "Size (GB)" ; Expression = {"{0:N1}" -f( $_.Size / 1gb)}}, 
@{ Name = "FreeSpace (GB)" ; Expression = {"{0:N1}" -f( $_.Freespace / 1gb ) } }, 
@{ Name = "PercentFree" ; Expression = {"{0:P1}" -f( $_.FreeSpace / $_.Size ) } } | 
Format-Table -AutoSize | Out-String 
 
## Sends some before and after info for ticketing purposes 
 
Hostname ; Get-Date | Select-Object DateTime 
Write-Verbose "Before: $Before" 
Write-Verbose "After: $After" 
Write-Verbose $size 
## Completed Successfully! 
Stop-Transcript } Cleanup
'@
$mytask | Out-File c:\windows\cleanup.ps1

  # Create and enable a task for block discard via SCSI_UNMAP
  $defragtask = New-ScheduledTaskAction -Execute "defrag.exe" -Argument "/C /L"
  $STPrin = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $trigger3 = New-ScheduledTaskTrigger -Weekly -AT "03:00" -DaysOfWeek 'Sunday' -RandomDelay (New-TimeSpan -Hours 3)
  Register-ScheduledTask BlockDiscard -Action $defragtask -Principal $STPrin -Trigger $trigger3

  # Create and enable a task for UH-IaaS reporting
  $trigger4 = New-ScheduledTaskTrigger -Once -AT 04:00 -RandomDelay (New-TimeSpan -Hours 3) -RepetitionInterval (New-TimeSpan -Hours 12)
  $STPrin = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $Stask = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "c:\windows\uhiaasdownload.ps1"
  Register-ScheduledTask "UH-IaaS reporting" -Action $Stask -Principal $STPrin -Trigger $trigger4

  $mytask2 = @'
##############################################
#
# Download report script and execute.
#
# From the UH-IaaS team.
#
##############################################

$outputfile = "c:\windows\uhiaasreport.ps1"
$osversion  = (Get-WmiObject -class Win32_OperatingSystem).Caption -replace ' ','_'
$url        = "https://report.uh-iaas.no/downloads/windows/" + $osversion + "/v1/report"

# Remove old script and create empty file
If (Test-Path $outputfile){
    Remove-Item $outputfile
}
New-Item $outputfile -ItemType file

# Download new script from UH-IaaS
Invoke-WebRequest -Uri $url -OutFile $outputfile

# Whitelist downloaded script for execution
Unblock-File -Path $outputfile

# Execute the script file
$result = Invoke-Expression $outputfile

#Write-Output $result
'@
$mytask2 | Out-File c:\windows\uhiaasdownload.ps1

  return 0
}

try
{
    Import-Module "$resourcesDir\ini.psm1"
    $installUpdates = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "InstallUpdates" -Default $false -AsBoolean
    $persistDrivers = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "PersistDriverInstall" -Default $true -AsBoolean
    $purgeUpdates = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "PurgeUpdates" -Default $false -AsBoolean
    $disableSwap = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "DisableSwap" -Default $false -AsBoolean

    if ($installUpdates) {
        Install-WindowsUpdates
    }

    ExecRetry {
        Clean-WindowsUpdates -PurgeUpdates $purgeUpdates
    }

    if ($installUpdates) {
        Install-WindowsUpdates
    }

    $Host.UI.RawUI.WindowTitle = "Installing Cloudbase-Init..."

    $programFilesDir = $ENV:ProgramFiles

    $CloudbaseInitMsiPath = "$resourcesDir\CloudbaseInit.msi"
    $CloudbaseInitMsiLog = "$resourcesDir\CloudbaseInit.log"

    $serialPortName = @(Get-WmiObject Win32_SerialPort)[0].DeviceId

    $p = Start-Process -Wait -PassThru -FilePath msiexec -ArgumentList "/i $CloudbaseInitMsiPath /qn /l*v $CloudbaseInitMsiLog LOGGINGSERIALPORTNAME=$serialPortName"
    if ($p.ExitCode -ne 0) {
        throw "Installing $CloudbaseInitMsiPath failed. Log: $CloudbaseInitMsiLog"
    }

    if ($UH_IaaS_settings) {
        UH_IaaS
    }

    $Host.UI.RawUI.WindowTitle = "Running SetSetupComplete..."
    & "$programFilesDir\Cloudbase Solutions\Cloudbase-Init\bin\SetSetupComplete.cmd"

    Run-Defragment

    Clean-UpdateResources

    Release-IP

    $Host.UI.RawUI.WindowTitle = "Running Sysprep..."
    $unattendedXmlPath = "$programFilesDir\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
    Set-PersistDrivers -Path $unattendedXmlPath -Persist:$persistDrivers

    if ($disableSwap) {
        ExecRetry {
            Disable-Swap
        }
        Set-UnattendEnableSwap -Path $unattendedXmlPath
    }

    & "$ENV:SystemRoot\System32\Sysprep\Sysprep.exe" `/generalize `/oobe `/shutdown `/unattend:"$unattendedXmlPath"
} catch {
    $host.ui.WriteErrorLine($_.Exception.ToString())
    $x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    throw
}
