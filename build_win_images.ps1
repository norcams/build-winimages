# A wrapper script for creating windows images and patch install sources.
#
# windows-openstack-imaging-tools is required. Download from
# https://github.com/cloudbase/windows-openstack-imaging-tools
#
# We need to know versionname, path to wim file, indexes to patch, windows version for updates, and build number to
# distinguish server versions. Variants must correspond with indexes (from VIM file).
$createImages = @(
  ('Windows Server 2019', 'h:\installsource\server2019\sources\install.wim', '1,2', 'windows10', '17763', 'Core,Standard', 'win2019-server', 'qcow2', 'KVM'),
  ('Windows Server 2016', 'h:\installsource\server2016\sources\install.wim', '1,2', 'windows10', '14393', 'Standard', 'win2016-server', 'qcow2', 'KVM')
)
$patchdir = "h:\patchdownload"
$mountdir = "h:\mountdir\"
$imagepath = "h:\os-builder\images"
$winimagebuilderpath = "c:\os-builder\windows-openstack-imaging-tools\"
$virtIOISOPath = "$patchdir"
$virtIODownloadLink = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.164-1/virtio-win.iso"
$extraDriversPath = "C:\os-builder\drivers"
$switchName = "NATswitch"
$ErrorActionPreference = "Stop"

$windowsVersions = @()

foreach ($version in $createImages) {
  $instance = New-Object -TypeName PSObject
  $instance | Add-Member -MemberType NoteProperty -Name version -Value $version[0]
  $instance | Add-Member -MemberType NoteProperty -Name vimpath -Value $version[1]
  $instance | Add-Member -MemberType NoteProperty -Name indexes -Value $version[2]
  $instance | Add-Member -MemberType NoteProperty -Name likeness -Value $version[3]
  $instance | Add-Member -MemberType NoteProperty -Name build -Value $version[4]
  $instance | Add-Member -MemberType NoteProperty -Name variants -Value $version[5]
  $instance | Add-Member -MemberType NoteProperty -Name filename -Value $version[6]
  $instance | Add-Member -MemberType NoteProperty -Name disktype -Value $version[7]
  $instance | Add-Member -MemberType NoteProperty -Name virttype -Value $version[8]
  $windowsVersions += $instance
}

$windowsVersions

# Check if prerequisites are installed
if (Get-Module -ListAvailable -Name LatestUpdate) {
   # Write-Host "Module LatestUpdate installed"
} 
else {
  Write-Host "Installing MsrcSecurityUpdate"
  Install-PackageProvider -Name Nuget -Force
  Install-Module -Name LatestUpdate -Force
}

Import-Module "$winimagebuilderpath\WinImageBuilder.psm1"

$windowsVersions | ForEach-Object -Process {
  $updates = $(Get-LatestUpdate -WindowsVersion $_.likeness -Build $_.build)
  $dlversion = $_.version
  $dlupdate = $updates | Where-Object -Property Note -Like "*$dlversion*"
  $filename = $dlupdate.URL.Split('/')[-1]
  if (Test-Path -Path "$patchdir\$filename") {
    Write-Host "File exists"
  }
  Else {
    Write-Host "Downloading update..."
    (New-Object System.Net.WebClient).DownloadFile($dlupdate.URL, "$patchdir\$filename")
  }
  # Build images
  $imagenameBase = $_.filename
  $disktype = $_.disktype
  $winname = $_.version
  $variants = $_.variants.Split(",")
  $index = $_.indexes.Split(",")
  $imagepath = $_.vimpath
  $virttype = $_.virttype
  $_.variants.Split(',') | ForEach {
    $variant = $_
    Write-Host "Building $winname $variant"
    $indexnumber = $([array]::IndexOf($variants, $variant))
    $thisindex = $index[$indexnumber]
    Write-Host "Mounting wim image, index $thisindex"
    Write-host "-Path $mountdir -ImagePath $imagepath -Index $thisindex"
    Mount-WindowsImage -Path "$mountdir" -ImagePath "$imagepath" -Index $thisindex
    # Adding update package...
    Add-WindowsPackage -Path "$mountdir" -PackagePath "$patchdir\$filename" -LogPath "$patchdir\$winname $variant.log"
    Save-WindowsImage -Path "$mountdir"
    Dismount-WindowsImage -Path "$mountdir" -Discard
    # Start the image building process...
    $imagename = "$imagenameBase-$variant.$disktype"
    $windowsImagePath = "$imagepath\$imagename"
    $imagename
    # Move old files
    Remove-Item "$imagepath\$imagename_old" -ErrorAction Ignore
    Remove-Item "$imagepath\$imagename_old.sha256" -ErrorAction Ignore
    # Downloading virtio...
    (New-Object System.Net.WebClient).DownloadFile($virtIODownloadLink, $virtIOISOPath)
    # Real index for this install
    $realindex = $thisindex-1
    $installImageName = (Get-WimFileImagesInfo -WimFilePath "$imagepath")[$realindex]
    New-WindowsOnlineImage -WimFilePath $imagepath -ImageName $installImageName.ImageName `
    -WindowsImagePath "$windowsImagePath"  -Type $virttype -ExtraFeatures @() `
    -SizeBytes 30GB -CpuCore 2 -Memory 4GB -SwitchName $switchName `
    -ProductKey $productKey -DiskLayout 'BIOS' -VirtioISOPath $virtIOISOPath `
    -ExtraDriversPath $extraDriversPath `
    -InstallUpdates:$true -AdministratorPassword 'Pa$$w0rd' `
    -PurgeUpdates:$true -DisableSwap:$true -Force:$true
  }
}
