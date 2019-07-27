Function Set-VMNetworkConfiguration {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='DHCP',
                   ValueFromPipeline=$true)]
        [Parameter(Mandatory=$true,
                   Position=0,
                   ParameterSetName='Static',
                   ValueFromPipeline=$true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='Static')]
        [String[]]$IPAddress=@(),

        [Parameter(Mandatory=$false,
                   Position=2,
                   ParameterSetName='Static')]
        [String[]]$Subnet=@(),

        [Parameter(Mandatory=$false,
                   Position=3,
                   ParameterSetName='Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory=$false,
                   Position=4,
                   ParameterSetName='Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory=$false,
                   Position=0,
                   ParameterSetName='DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object { $_.ElementName -eq $NetworkAdapter.VMName } 
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }    
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData') 

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters) {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress) {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated("Msvm_GuestNetworkAdapterConfiguration")
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].DefaultGateways = $DefaultGateway
    $NetworkSettings[0].DNSServers = $DNSServer
    $NetworkSettings[0].ProtocolIFType = 4096

    if ($dhcp) {
        $NetworkSettings[0].DHCPEnabled = $true
    } else {
        $NetworkSettings[0].DHCPEnabled = $false
    }

    $Service = Get-WmiObject -Class "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($VM, $NetworkSettings[0].GetText(1))

    if ($setip.ReturnValue -eq 4096) {
        $job=[WMI]$setip.job 

        while ($job.JobState -eq 3 -or $job.JobState -eq 4) {
            start-sleep 1
            $job=[WMI]$setip.job
        }

        if ($job.JobState -eq 7) {
            write-host "Success"
        }
        else {
            $job.GetError()
        }
    } elseif($setip.ReturnValue -eq 0) {
        Write-Host "Success"
    }
}

Function Unzip-Files {
    Param (
        [Object]$Files,
        [string]$Destination
    )

    foreach ($file in $files)
    {
        $fileName = $file.FullName

        write-output "Start unzip: $fileName to $Destination"
        
        (new-object -com shell.application).namespace($Destination).CopyHere((new-object -com shell.application).namespace($fileName).Items(),16)
        
        write-output "Finish unzip: $fileName to $Destination"
    }
}

Function Follow-Redirect {
    Param (
        [string]$Url
    )

    $webClientObject = New-Object System.Net.WebClient
    $webRequest = [System.Net.WebRequest]::create($Url)
    $webResponse = $webRequest.GetResponse()
    $actualUrl = $webResponse.ResponseUri.AbsoluteUri
    $webResponse.Close()

    return $actualUrl
}

Function Wait-For-Website {
    Param (
        [string]$Url
    )

    $i = 1
    while ($true) {

        try {
            Write-Output "Checking ($i)...please wait"
            $i++

            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 10 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                return;
            }
        } catch {}

        Start-Sleep 2
    }
}

$ErrorActionPreference = 'SilentlyContinue'
Import-Module BitsTransfer

# Create paths
$opsDir = "C:\OpsgilityTraining"
$vmDir = "F:\VirtualMachines"
$tempDir = "D:\"
New-Item -Path $vmDir -ItemType directory -Force

# Unregister scheduled task so this script doesn't run again on next reboot
Unregister-ScheduledTask -TaskName "SetUpVMs" -Confirm:$false

# Set final script to run on login (doesn't work if run now)
Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "NextRun" `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe -executionPolicy Unrestricted -File $opsDir\OnLoginConfigure.ps1"

# Download AzCopy. We won't use the aka.ms/downloadazcopy link in case of breaking changes in later versions
$azcopyUrl = "https://cloudworkshop.blob.core.windows.net/line-of-business-application-migration/azcopy_windows_amd64_10.1.1.zip"
$azcopyZip = "$opsDir\azcopy.zip"
Start-BitsTransfer -Source $azcopyUrl -Destination $azcopyZip
$azcopyZipfile = Get-ChildItem -Path $azcopyZip
Unzip-Files -Files $azcopyZipfile -Destination $opsDir

$azcopy = "$opsDir\azcopy_windows_amd64_10.1.1\azcopy.exe"

# Download SmartHotel VMs from blob storage
# Also download Azure Migrate appliance (saves time in lab lter)
$container = 'https://cloudworkshop.blob.core.windows.net/line-of-business-application-migration'

cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $container/SmartHotelWeb1.zip $tempDir\SmartHotelWeb1.zip"
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $container/SmartHotelWeb2.zip $tempDir\SmartHotelWeb2.zip"
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $container/SmartHotelSQL1.zip $tempDir\SmartHotelSQL1.zip"
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $container/UbuntuWAF.zip $tempDir\UbuntuWAF.zip"
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $container/AzureMigrateAppliance_v1.19.05.10.zip $tempDir\AzureMigrate.zip"

# Unzip the VMs
$zipfiles = Get-ChildItem -Path "$tempDir\*.zip"
Unzip-Files -Files $zipfiles -Destination $vmDir

# Create the NAT network
$natName = "InternalNat"
New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 192.168.0.0/16

# Create an internal switch with NAT
$switchName = 'InternalNATSwitch'
New-VMSwitch -Name $switchName -SwitchType Internal
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*"+$switchName+"*" }

# Create an internal network (gateway first)
New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

# Add NAT forwarders
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 22   -Protocol TCP -InternalIPAddress "192.168.0.8" -InternalPort 22   -NatName $natName
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 80   -Protocol TCP -InternalIPAddress "192.168.0.8" -InternalPort 80   -NatName $natName
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 1433 -Protocol TCP -InternalIPAddress "192.168.0.6" -InternalPort 1433 -NatName $natName

# Add a firewall rule for HTTP and SQL
New-NetFirewallRule -DisplayName "SSH Inbound" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "HTTP Inbound" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Microsoft SQL Server Inbound" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow

# Enable Enhanced Session Mode on Host
Set-VMHost -EnableEnhancedSessionMode $true

# Create the nested Windows VMs - from VHDs
New-VM -Name smarthotelweb1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelWeb1\SmartHotelWeb1.vhdx" -Path "$vmdir\SmartHotelWeb1" -Generation 2 -Switch $switchName 
New-VM -Name smarthotelweb2 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelWeb2\SmartHotelWeb2.vhdx" -Path "$vmdir\SmartHotelWeb2" -Generation 2 -Switch $switchName
New-VM -Name smarthotelSQL1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelSQL1\SmartHotelSQL1.vhdx" -Path "$vmdir\SmartHotelSQL1" -Generation 2 -Switch $switchName
New-VM -Name UbuntuWAF      -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\UbuntuWAF\UbuntuWAF.vhdx"           -Path "$vmdir\UbuntuWAF"      -Generation 1 -Switch $switchName

# Configure IP addresses (don't change the IPs! VM config depends on them)
Get-VMNetworkAdapter -VMName "smarthotelweb1" | Set-VMNetworkConfiguration -IPAddress "192.168.0.4" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "smarthotelweb2" | Set-VMNetworkConfiguration -IPAddress "192.168.0.5" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "smarthotelsql1" | Set-VMNetworkConfiguration -IPAddress "192.168.0.6" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "UbuntuWAF"      | Set-VMNetworkConfiguration -IPAddress "192.168.0.8" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"

# We always want the VMs to start with the host and shut down cleanly with the host
# (If they just save state, which is the default, they can break if the host re-starts on a different CPU architecture)
Get-VM | Set-VM -AutomaticStartAction Start -AutomaticStopAction ShutDown

# Start all the VMs
Get-VM | Start-VM

# Ping website to warm it up
Wait-For-Website('http://192.168.0.8')
