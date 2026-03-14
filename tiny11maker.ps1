<#
.SYNOPSIS
    Scripts to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
    My main goal is to use only Microsoft utilities like DISM, and no utilities from external sources.
    The only executable included is oscdimg.exe, which is provided in the Windows ADK and it is used to create bootable ISO images.

.PARAMETER ISO
    Drive letter given to the mounted iso (eg: E)

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)

.PARAMETER Index
    Windows image index to use for the build.

.PARAMETER SourceIsoPath
    Path to a Windows ISO file to mount automatically.

.PARAMETER OutputPath
    Output ISO file path, or an existing directory that should receive tiny11.iso.

.PARAMETER UnattendPath
    Custom autounattend.xml file to embed in the image.

.PARAMETER NoCleanup
    Preserve the build workspace and scratch directory after the run completes.

.PARAMETER KeepDownloadedTools
    Preserve a downloaded local copy of oscdimg.exe after the run completes.

.PARAMETER NoPause
    Skip the final "Press Enter to continue" prompt.

.PARAMETER Profile
    Name of the build profile to use from the profile file.

.PARAMETER ProfilePath
    Path to a PowerShell data file that defines available build profiles.

.PARAMETER ValidateOnly
    Validate source media, selected profile, output path, and image selection without building an ISO.

.EXAMPLE
    .\tiny11maker.ps1 E D
    .\tiny11maker.ps1 -ISO E -SCRATCH D
    .\tiny11maker.ps1 -SCRATCH D -ISO E
    .\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -SCRATCH D -Index 1 -OutputPath C:\ISO\tiny11.iso -Profile compatibility -NoPause
    .\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -Index 1 -Profile default -ValidateOnly
    .\tiny11maker.ps1

    *If you ordinal parameters the first one must be the mounted iso. The second is the scratch drive.
    prefer the use of full named parameter (eg: "-ISO") as you can put in the order you want.

.NOTES
    Auteur: ntdevlabs
    Date: 09-07-25
#>

#---------[ Parameters ]---------#
param (
    [Alias('SourceDrive')][ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [Alias('ScratchDrive')][ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [Alias('ImageIndex')][ValidateRange(1, 999)][int]$Index,
    [Alias('OutputIsoPath')][string]$OutputPath,
    [string]$SourceIsoPath,
    [string]$UnattendPath,
    [string]$Profile,
    [string]$ProfilePath,
    [switch]$ValidateOnly,
    [switch]$NoCleanup,
    [switch]$KeepDownloadedTools,
    [switch]$NoPause
)

if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

#---------[ Functions ]---------#
function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )

    Invoke-RegCommand -Arguments @('add', $path, '/v', $name, '/t', $type, '/d', $value, '/f') -OperationDescription "setting registry value $path\$name"
    Write-Output "Set registry value: $path\$name"
}

function Remove-RegistryValue {
    param (
        [string]$path
    )

    $providerPath = Convert-ToRegistryProviderPath -Path $path
    if (-not (Test-Path -LiteralPath $providerPath)) {
        Write-Output "Registry path not present, skipping removal: $path"
        return
    }

    Invoke-RegCommand -Arguments @('delete', $path, '/f') -OperationDescription "removing registry value $path"
    Write-Output "Removed registry value: $path"
}

function Format-ByteSize {
    param (
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return '{0:N2} TB' -f ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return '{0:N2} GB' -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return '{0:N2} MB' -f ($Bytes / 1MB)
    }

    return '{0:N2} KB' -f ($Bytes / 1KB)
}

function Format-Duration {
    param (
        [TimeSpan]$Duration
    )

    return '{0:hh\:mm\:ss}' -f $Duration
}

function Format-CommandLine {
    param (
        [string]$FilePath,
        [string[]]$Arguments
    )

    $renderedArguments = foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            '""'
        } elseif ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }

    return ($FilePath, ($renderedArguments -join ' ')).Where({ $_ }) -join ' '
}

function Invoke-NativeCommand {
    param (
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$OperationDescription,
        [switch]$CaptureOutput,
        [switch]$Quiet,
        [int[]]$SuccessExitCodes = @(0)
    )

    $commandLine = Format-CommandLine -FilePath $FilePath -Arguments $Arguments
    Write-Host "Running native command: $commandLine"

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $Quiet -and $output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($SuccessExitCodes -notcontains $exitCode) {
        $outputText = if ($output) { ($output | Out-String).Trim() } else { 'No additional output.' }
        throw "$FilePath failed while $OperationDescription (exit code $exitCode). $outputText"
    }

    if ($CaptureOutput) {
        return ,$output
    }
}

function Convert-ToRegistryProviderPath {
    param (
        [string]$Path
    )

    if ($Path -like 'Registry::*') {
        return $Path
    }

    return "Registry::$Path"
}

function Invoke-BuildStage {
    param (
        [pscustomobject]$Context,
        [string]$Name,
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Output "[$Name] Starting..."
    $succeeded = $false

    try {
        & $ScriptBlock
        $succeeded = $true
    } finally {
        $stopwatch.Stop()
        $status = if ($succeeded) { 'Succeeded' } else { 'Failed' }
        $Context.StageTimings.Add([pscustomobject]@{
            Name     = $Name
            Status   = $status
            Duration = $stopwatch.Elapsed
        }) | Out-Null
        Write-Output "[$Name] $status in $(Format-Duration -Duration $stopwatch.Elapsed)."
    }
}

function Write-BuildSummary {
    param (
        [pscustomobject]$Context
    )

    if (-not $Context.StageTimings.Count) {
        return
    }

    Write-Output 'Build summary:'
    foreach ($stage in $Context.StageTimings) {
        Write-Output (" - {0}: {1} ({2})" -f $stage.Name, $stage.Status, (Format-Duration -Duration $stage.Duration))
    }

    if ($Context.ProfileName) {
        Write-Output "Profile: $($Context.ProfileName)"
    }

    if ($Context.SelectedImageMetadata) {
        $selectedImageLabel = if ($Context.SelectedImageMetadata.ImageName) { $Context.SelectedImageMetadata.ImageName } else { "Index $($Context.ImageIndex)" }
        Write-Output "Image: $selectedImageLabel"
        Write-Output "Image index: $($Context.ImageIndex)"
    }

    if ($Context.Architecture) {
        Write-Output "Architecture: $($Context.Architecture)"
    }

    if ($Context.LanguageCode) {
        Write-Output "Language: $($Context.LanguageCode)"
    }

    if ($Context.BuildSucceeded) {
        Write-Output "Output ISO: $($Context.OutputIsoPath)"
    }

    Write-Output "Transcript: $($Context.TranscriptPath)"
}

function Resolve-UnresolvedPath {
    param (
        [string]$Path
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Resolve-ExistingFilePath {
    param (
        [string]$Path,
        [string]$Description
    )

    try {
        $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "$Description '$Path' was not found."
    }

    $resolvedItem = Get-Item -LiteralPath $resolvedPath.Path -ErrorAction Stop
    if ($resolvedItem.PSIsContainer) {
        throw "$Description '$Path' must be a file."
    }

    return $resolvedItem.FullName
}

function Resolve-OutputIsoPath {
    param (
        [string]$Path,
        [string]$ScriptRoot
    )

    if (-not $Path) {
        return (Join-Path -Path $ScriptRoot -ChildPath 'tiny11.iso')
    }

    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path -ErrorAction Stop).PSIsContainer) {
        return (Join-Path -Path (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path -ChildPath 'tiny11.iso')
    }

    return (Resolve-UnresolvedPath -Path $Path)
}

function Resolve-ImageArchitecture {
    param (
        [object]$Architecture
    )

    if ($null -eq $Architecture) {
        return $null
    }

    switch ([string]$Architecture) {
        '0' { return 'x86' }
        '9' { return 'amd64' }
        '12' { return 'arm64' }
        'x86' { return 'x86' }
        'X86' { return 'x86' }
        'x64' { return 'amd64' }
        'X64' { return 'amd64' }
        'amd64' { return 'amd64' }
        'AMD64' { return 'amd64' }
        'arm64' { return 'arm64' }
        'ARM64' { return 'arm64' }
        default { return ([string]$Architecture) }
    }
}

function Ensure-ParentDirectory {
    param (
        [string]$Path,
        [string]$Description
    )

    $parentPath = Split-Path -Path $Path -Parent
    if (-not $parentPath) {
        return
    }

    if (-not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath -Force -ErrorAction Stop | Out-Null
        Write-Output "Created $Description directory '$parentPath'."
    }
}

function Get-CachedWindowsImageMetadata {
    param (
        [pscustomobject]$Context,
        [string]$ImagePath
    )

    if (-not $Context.ImageMetadataCache.ContainsKey($ImagePath)) {
        $Context.ImageMetadataCache[$ImagePath] = @(Get-WindowsImage -ImagePath $ImagePath)
    }

    return @($Context.ImageMetadataCache[$ImagePath])
}

function Copy-DirectoryWithRobocopy {
    param (
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Description
    )

    Ensure-ParentDirectory -Path $DestinationPath -Description $Description
    $sourceRoot = [System.IO.Path]::GetFullPath($SourcePath)
    if (-not $sourceRoot.EndsWith('\')) {
        $sourceRoot += '\'
    }

    Invoke-NativeCommand -FilePath 'robocopy' -Arguments @(
        $sourceRoot,
        $DestinationPath,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:2',
        '/W:2',
        '/XJ',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP'
    ) -OperationDescription "copying $Description" -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -Quiet
}

function Test-PathParentWritable {
    param (
        [string]$Path,
        [string]$Description
    )

    $parentPath = Split-Path -Path $Path -Parent
    if (-not $parentPath) {
        return
    }

    $probeRoot = $parentPath
    while ($probeRoot -and -not (Test-Path -LiteralPath $probeRoot)) {
        $probeRoot = Split-Path -Path $probeRoot -Parent
    }

    if (-not $probeRoot) {
        throw "Unable to validate $Description path '$Path' because no existing parent directory could be found."
    }

    $probeFile = Join-Path -Path $probeRoot -ChildPath ([Guid]::NewGuid().ToString('N') + '.tmp')
    New-Item -ItemType File -Path $probeFile -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $parentPath)) {
        Write-Output "$Description parent directory '$parentPath' does not exist yet and will be created during the build."
    }
}

function Resolve-BuildProfilePath {
    param (
        [string]$Path,
        [string]$ScriptRoot
    )

    if ($Path) {
        return (Resolve-ExistingFilePath -Path $Path -Description 'Profile file')
    }

    return (Join-Path -Path $ScriptRoot -ChildPath 'tiny11maker.profiles.psd1')
}

function Resolve-SetFromCatalog {
    param (
        [hashtable]$Catalog,
        [string]$SelectedSetName,
        [string]$SetDescription
    )

    if (-not $Catalog.ContainsKey($SelectedSetName)) {
        $availableSets = ($Catalog.Keys | Sort-Object) -join ', '
        throw "$SetDescription set '$SelectedSetName' is not defined. Available sets: $availableSets"
    }

    return @($Catalog[$SelectedSetName])
}

function Resolve-RegistryActionGroupsFromCatalog {
    param (
        [object[]]$Catalog,
        [string[]]$SelectedGroupNames,
        [string]$ProfileName,
        [string]$CatalogDescription
    )

    $catalogByName = @{}
    foreach ($group in $Catalog) {
        $catalogByName[$group.Name] = $group
    }

    $resolvedGroups = foreach ($groupName in $SelectedGroupNames) {
        if (-not $catalogByName.ContainsKey($groupName)) {
            $availableGroups = ($catalogByName.Keys | Sort-Object) -join ', '
            throw "$CatalogDescription group '$groupName' is not defined for profile '$ProfileName'. Available groups: $availableGroups"
        }

        $catalogByName[$groupName]
    }

    return @($resolvedGroups)
}

function Import-BuildProfile {
    param (
        [pscustomobject]$Context
    )

    $resolvedProfilePath = Resolve-BuildProfilePath -Path $Context.ProfilePath -ScriptRoot $Context.ScriptRoot
    if (-not (Test-Path -LiteralPath $resolvedProfilePath)) {
        throw "Profile file '$resolvedProfilePath' was not found."
    }

    $profileData = Import-PowerShellDataFile -Path $resolvedProfilePath
    if (-not $profileData.ContainsKey('Profiles')) {
        throw "Profile file '$resolvedProfilePath' must define a top-level 'Profiles' table."
    }

    $selectedProfileName = if ($Context.ProfileName) { $Context.ProfileName } else { $profileData.DefaultProfile }
    if (-not $selectedProfileName) {
        throw "Profile file '$resolvedProfilePath' does not define DefaultProfile and no -Profile was provided."
    }

    if (-not $profileData.Profiles.ContainsKey($selectedProfileName)) {
        $availableProfiles = ($profileData.Profiles.Keys | Sort-Object) -join ', '
        throw "Profile '$selectedProfileName' was not found in '$resolvedProfilePath'. Available profiles: $availableProfiles"
    }

    $profile = $profileData.Profiles[$selectedProfileName]
    $requiredKeys = 'AppPackageSet', 'InstallRegistryGroups', 'SetupRegistryGroups', 'ScheduledTaskSet'
    foreach ($requiredKey in $requiredKeys) {
        if (-not $profile.ContainsKey($requiredKey)) {
            throw "Profile '$selectedProfileName' in '$resolvedProfilePath' is missing required key '$requiredKey'."
        }
    }

    $Context.ProfilePath = $resolvedProfilePath
    $Context.ProfileName = $selectedProfileName
    $Context.BuildProfile = [pscustomobject]@{
        Description           = [string]$profile.Description
        AppPackageSet         = [string]$profile.AppPackageSet
        InstallRegistryGroups = @($profile.InstallRegistryGroups)
        SetupRegistryGroups   = @($profile.SetupRegistryGroups)
        ScheduledTaskSet      = [string]$profile.ScheduledTaskSet
        RemoveEdge            = if ($profile.ContainsKey('RemoveEdge')) { [bool]$profile.RemoveEdge } else { $true }
        RemoveOneDrive        = if ($profile.ContainsKey('RemoveOneDrive')) { [bool]$profile.RemoveOneDrive } else { $true }
    }

    Write-Output "Using build profile '$($Context.ProfileName)' from '$($Context.ProfilePath)'."
    if ($Context.BuildProfile.Description) {
        Write-Output $Context.BuildProfile.Description
    }
}

function Get-ElevationArguments {
    param (
        [string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)

    foreach ($parameterName in $BoundParameters.Keys) {
        $parameterValue = $BoundParameters[$parameterName]
        if ($parameterValue -is [System.Management.Automation.SwitchParameter]) {
            if ($parameterValue.IsPresent) {
                $arguments += "-$parameterName"
            }

            continue
        }

        switch ($parameterName) {
            'OutputPath' {
                $parameterValue = Resolve-UnresolvedPath -Path $parameterValue
            }
            'SourceIsoPath' {
                $parameterValue = Resolve-ExistingFilePath -Path $parameterValue -Description 'Source ISO'
            }
            'UnattendPath' {
                $parameterValue = Resolve-ExistingFilePath -Path $parameterValue -Description 'Unattend file'
            }
            'ProfilePath' {
                $parameterValue = Resolve-ExistingFilePath -Path $parameterValue -Description 'Profile file'
            }
        }

        $arguments += "-$parameterName"
        $arguments += [string]$parameterValue
    }

    return (Format-CommandLine -FilePath '' -Arguments $arguments)
}

function New-BuildContext {
    param (
        [string]$BuildRoot,
        [string]$ScriptRoot,
        [string]$AdminGroupName,
        [string]$OutputIsoPath,
        [string]$UnattendPath,
        [string]$ProfileName,
        [string]$ProfilePath,
        [switch]$NoCleanup,
        [switch]$KeepDownloadedTools,
        [switch]$PauseAtEnd
    )

    $buildWorkspacePath = Join-Path -Path $BuildRoot -ChildPath 'tiny11'
    $sourcesPath = Join-Path -Path $buildWorkspacePath -ChildPath 'sources'

    return [pscustomobject]@{
        ScriptRoot            = $ScriptRoot
        BuildRoot             = $BuildRoot
        BuildWorkspacePath    = $buildWorkspacePath
        SourcesPath           = $sourcesPath
        ScratchDirectoryPath  = Join-Path -Path $BuildRoot -ChildPath 'scratchdir'
        InstallWimPath        = Join-Path -Path $sourcesPath -ChildPath 'install.wim'
        InstallEsdPath        = Join-Path -Path $sourcesPath -ChildPath 'install.esd'
        BootWimPath           = Join-Path -Path $sourcesPath -ChildPath 'boot.wim'
        UnattendPath          = if ($UnattendPath) { Resolve-ExistingFilePath -Path $UnattendPath -Description 'Unattend file' } else { Join-Path -Path $ScriptRoot -ChildPath 'autounattend.xml' }
        OutputIsoPath         = Resolve-OutputIsoPath -Path $OutputIsoPath -ScriptRoot $ScriptRoot
        LocalOscdimgPath      = Join-Path -Path $ScriptRoot -ChildPath 'oscdimg.exe'
        TranscriptPath        = Join-Path -Path $ScriptRoot -ChildPath ("tiny11_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        HostArchitecture      = $Env:PROCESSOR_ARCHITECTURE
        AdminGroupName        = $AdminGroupName
        ProfileName           = $ProfileName
        ProfilePath           = $ProfilePath
        BuildProfile          = $null
        SourceDrive           = $null
        SourceIsoPath         = $null
        AutoMountedSourceIso  = $false
        SourceBootWimPath     = $null
        SourceInstallWimPath  = $null
        SourceInstallEsdPath  = $null
        ImageIndex            = $null
        SelectedImageMetadata = $null
        ImageMetadataCache    = @{}
        LanguageCode          = $null
        Architecture          = $null
        TranscriptStarted     = $false
        BuildSucceeded        = $false
        ExitCode              = 0
        OfflineRegistryLoaded = $false
        MountedImagePath      = $null
        DownloadedOscdimg     = $false
        NoCleanup             = [bool]$NoCleanup
        KeepDownloadedTools   = [bool]$KeepDownloadedTools
        PauseAtEnd            = [bool]$PauseAtEnd
        StageTimings          = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-SourceDriveLetter {
    param (
        [string]$DefaultISO
    )

    do {
        if (-not $DefaultISO) {
            $driveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
        } else {
            $driveLetter = $DefaultISO
        }

        if ($driveLetter -match '^[c-zC-Z]$') {
            $driveLetter = $driveLetter + ":"
            Write-Output "Drive letter set to $driveLetter"
        } else {
            Write-Output "Invalid drive letter. Please enter a letter between C and Z."
        }
    } while ($driveLetter -notmatch '^[c-zC-Z]:$')

    return $driveLetter
}

function Mount-SourceIsoAndGetDriveLetter {
    param (
        [pscustomobject]$Context,
        [string]$IsoPath
    )

    $resolvedIsoPath = Resolve-ExistingFilePath -Path $IsoPath -Description 'Source ISO'
    if ([System.IO.Path]::GetExtension($resolvedIsoPath) -ne '.iso') {
        throw "Source ISO '$resolvedIsoPath' must have a .iso extension."
    }

    Write-Output "Mounting source ISO..."
    Mount-DiskImage -ImagePath $resolvedIsoPath -StorageType ISO -ErrorAction Stop | Out-Null

    try {
        $volume = Get-DiskImage -ImagePath $resolvedIsoPath -ErrorAction Stop | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | Select-Object -First 1
    } catch {
        Dismount-DiskImage -ImagePath $resolvedIsoPath -ErrorAction SilentlyContinue
        throw "Mounted source ISO '$resolvedIsoPath' but could not determine its drive letter."
    }

    if (-not $volume) {
        Dismount-DiskImage -ImagePath $resolvedIsoPath -ErrorAction SilentlyContinue
        throw "Mounted source ISO '$resolvedIsoPath' but no drive letter was assigned."
    }

    $Context.SourceIsoPath = $resolvedIsoPath
    $Context.AutoMountedSourceIso = $true
    Write-Output "Source ISO mounted on drive $($volume.DriveLetter):"
    return "$($volume.DriveLetter):"
}

function Resolve-SourceDrive {
    param (
        [pscustomobject]$Context,
        [string]$DefaultISO,
        [string]$SourceIsoPath
    )

    if ($DefaultISO -and $SourceIsoPath) {
        throw "Specify either -ISO/-SourceDrive or -SourceIsoPath, but not both."
    }

    if ($SourceIsoPath) {
        return (Mount-SourceIsoAndGetDriveLetter -Context $Context -IsoPath $SourceIsoPath)
    }

    return (Get-SourceDriveLetter -DefaultISO $DefaultISO)
}

function Select-WindowsImageMetadata {
    param (
        [pscustomobject]$Context,
        [string]$ImagePath,
        [int]$RequestedIndex
    )

    $images = Get-CachedWindowsImageMetadata -Context $Context -ImagePath $ImagePath

    if ($RequestedIndex -gt 0) {
        $selectedImage = $images | Where-Object { $_.ImageIndex -eq $RequestedIndex } | Select-Object -First 1
        if (-not $selectedImage) {
            throw "Image index $RequestedIndex is not available in '$ImagePath'."
        }

        Write-Output "Using image index $RequestedIndex."
        return $selectedImage
    }

    while ($true) {
        $images
        $selectedIndexInput = Read-Host "Please enter the image index"
        $selectedIndex = 0

        if (-not [int]::TryParse($selectedIndexInput, [ref]$selectedIndex)) {
            Write-Warning "Invalid image index. Please enter a number."
            continue
        }

        $selectedImage = $images | Where-Object { $_.ImageIndex -eq $selectedIndex } | Select-Object -First 1
        if ($selectedImage) {
            return $selectedImage
        }

        Write-Warning "Image index $selectedIndex is not available in '$ImagePath'."
    }
}

function Test-BuildWorkspace {
    param (
        [string]$BuildRoot,
        [string]$SourceDrive
    )

    $requiredCommands = 'Get-WindowsImage', 'Export-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage', 'robocopy'
    foreach ($requiredCommand in $requiredCommands) {
        if (-not (Get-Command -Name $requiredCommand -ErrorAction SilentlyContinue)) {
            throw "Required command '$requiredCommand' is not available. Install the DISM PowerShell tools and retry."
        }
    }

    if (-not (Test-Path -LiteralPath $BuildRoot)) {
        New-Item -ItemType Directory -Path $BuildRoot -Force -ErrorAction Stop | Out-Null
    }

    $buildRootItem = Get-Item -LiteralPath $BuildRoot -ErrorAction Stop
    if (-not $buildRootItem.PSIsContainer) {
        throw "The scratch location '$BuildRoot' is not a directory."
    }

    $scratchProbePath = Join-Path -Path $buildRootItem.FullName -ChildPath ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratchProbePath -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $scratchProbePath -Recurse -Force -ErrorAction Stop

    $bootWimPath = "$SourceDrive\sources\boot.wim"
    $installWimPath = "$SourceDrive\sources\install.wim"
    $installEsdPath = "$SourceDrive\sources\install.esd"
    if (-not (Test-Path -LiteralPath $bootWimPath)) {
        throw "Cannot find '$bootWimPath'. Make sure the Windows 11 ISO is mounted correctly."
    }

    if (-not ((Test-Path -LiteralPath $installWimPath) -or (Test-Path -LiteralPath $installEsdPath))) {
        throw "Cannot find '$installWimPath' or '$installEsdPath'. Make sure the Windows 11 installation media is complete."
    }

    try {
        $sourceBytes = (Get-ChildItem -Path "$SourceDrive\*" -Recurse -File -ErrorAction Stop | Measure-Object -Property Length -Sum).Sum
        if (-not $sourceBytes) {
            $sourceBytes = 0
        }

        $buildRootFullPath = [System.IO.Path]::GetFullPath($buildRootItem.FullName)
        $buildDriveRoot = [System.IO.Path]::GetPathRoot($buildRootFullPath)
        $driveInfo = New-Object System.IO.DriveInfo($buildDriveRoot)
        $requiredBytes = [long][Math]::Ceiling(($sourceBytes * 2.5) + 2GB)

        if ($driveInfo.AvailableFreeSpace -lt $requiredBytes) {
            throw "Not enough free space on $buildDriveRoot. Approximately $(Format-ByteSize -Bytes $requiredBytes) required, $(Format-ByteSize -Bytes $driveInfo.AvailableFreeSpace) available."
        }
    } catch {
        throw "Unable to validate free space for '$BuildRoot'. $($_.Exception.Message)"
    }
}

function Invoke-RegCommand {
    param (
        [string[]]$Arguments,
        [string]$OperationDescription,
        [switch]$Quiet
    )

    Invoke-NativeCommand -FilePath 'reg' -Arguments $Arguments -OperationDescription $OperationDescription -Quiet:$Quiet
}

function Load-OfflineRegistryHives {
    param (
        [pscustomobject]$Context
    )

    $Context.OfflineRegistryLoaded = $true
    Invoke-RegCommand -Arguments @('load', 'HKLM\zCOMPONENTS', "$($Context.ScratchDirectoryPath)\Windows\System32\config\COMPONENTS") -OperationDescription 'loading the COMPONENTS hive'
    Invoke-RegCommand -Arguments @('load', 'HKLM\zDEFAULT', "$($Context.ScratchDirectoryPath)\Windows\System32\config\default") -OperationDescription 'loading the DEFAULT hive'
    Invoke-RegCommand -Arguments @('load', 'HKLM\zNTUSER', "$($Context.ScratchDirectoryPath)\Users\Default\ntuser.dat") -OperationDescription 'loading the NTUSER hive'
    Invoke-RegCommand -Arguments @('load', 'HKLM\zSOFTWARE', "$($Context.ScratchDirectoryPath)\Windows\System32\config\SOFTWARE") -OperationDescription 'loading the SOFTWARE hive'
    Invoke-RegCommand -Arguments @('load', 'HKLM\zSYSTEM', "$($Context.ScratchDirectoryPath)\Windows\System32\config\SYSTEM") -OperationDescription 'loading the SYSTEM hive'
}

function Unload-OfflineRegistryHives {
    param (
        [pscustomobject]$Context
    )

    $hives = 'HKLM\zCOMPONENTS', 'HKLM\zDEFAULT', 'HKLM\zNTUSER', 'HKLM\zSOFTWARE', 'HKLM\zSYSTEM'

    foreach ($hive in $hives) {
        if (-not (Test-Path -LiteralPath "Registry::$hive")) {
            continue
        }

        try {
            Invoke-RegCommand -Arguments @('unload', $hive) -OperationDescription "unloading offline registry hive $hive" -Quiet
        } catch {
            Write-Warning "Failed to unload $hive. You may need to unload it manually."
        }
    }

    $Context.OfflineRegistryLoaded = $false
}

function Remove-PathIfExists {
    param (
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        Write-Warning "Failed to remove $Description at '$Path'."
    } else {
        Write-Output "$Description removed successfully."
    }
}

function Prepare-SourceMedia {
    param (
        [pscustomobject]$Context,
        [string]$DefaultISO,
        [string]$SourceIsoPath,
        [int]$RequestedImageIndex
    )

    $Context.SourceDrive = Resolve-SourceDrive -Context $Context -DefaultISO $DefaultISO -SourceIsoPath $SourceIsoPath
    $Context.SourceBootWimPath = "$($Context.SourceDrive)\sources\boot.wim"
    $Context.SourceInstallWimPath = "$($Context.SourceDrive)\sources\install.wim"
    $Context.SourceInstallEsdPath = "$($Context.SourceDrive)\sources\install.esd"

    Test-BuildWorkspace -BuildRoot $Context.BuildRoot -SourceDrive $Context.SourceDrive
    Write-Output "Preflight checks passed."

    Remove-PathIfExists -Path $Context.BuildWorkspacePath -Description 'previous tiny11 working folder'
    Remove-PathIfExists -Path $Context.ScratchDirectoryPath -Description 'previous scratch directory'
    New-Item -ItemType Directory -Force -Path $Context.SourcesPath | Out-Null

    if ((Test-Path $Context.SourceBootWimPath) -eq $false -or (Test-Path $Context.SourceInstallWimPath) -eq $false) {
        if ((Test-Path $Context.SourceInstallEsdPath) -eq $true) {
            Write-Output "Found install.esd, converting to install.wim..."
            $Context.SelectedImageMetadata = Select-WindowsImageMetadata -Context $Context -ImagePath $Context.SourceInstallEsdPath -RequestedIndex $RequestedImageIndex
            $Context.ImageIndex = $Context.SelectedImageMetadata.ImageIndex
            $Context.Architecture = Resolve-ImageArchitecture -Architecture $Context.SelectedImageMetadata.Architecture
            Write-Output ' '
            Write-Output 'Converting install.esd to install.wim. This may take a while...'
            Export-WindowsImage -SourceImagePath $Context.SourceInstallEsdPath -SourceIndex $Context.ImageIndex -DestinationImagePath $Context.InstallWimPath -Compressiontype Maximum -CheckIntegrity
        } else {
            throw "Can't find Windows OS installation files in the specified drive letter."
        }
    }

    Write-Output "Copying Windows image..."
    Copy-DirectoryWithRobocopy -SourcePath "$($Context.SourceDrive)\" -DestinationPath $Context.BuildWorkspacePath -Description 'Windows installation media'
    Set-ItemProperty -Path $Context.InstallEsdPath -Name IsReadOnly -Value $false > $null 2>&1
    Remove-Item $Context.InstallEsdPath > $null 2>&1
    Write-Output "Copy complete!"
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Output "Getting image information:"

    if (-not $Context.ImageIndex) {
        $Context.SelectedImageMetadata = Select-WindowsImageMetadata -Context $Context -ImagePath $Context.InstallWimPath -RequestedIndex $RequestedImageIndex
        $Context.ImageIndex = $Context.SelectedImageMetadata.ImageIndex
    }

    if (-not $Context.SelectedImageMetadata) {
        $Context.SelectedImageMetadata = Get-CachedWindowsImageMetadata -Context $Context -ImagePath $Context.InstallWimPath |
            Where-Object { $_.ImageIndex -eq $Context.ImageIndex } |
            Select-Object -First 1
    }

    if ($Context.SelectedImageMetadata) {
        $Context.Architecture = Resolve-ImageArchitecture -Architecture $Context.SelectedImageMetadata.Architecture
        if ($Context.SelectedImageMetadata.ImageName) {
            Write-Output "Selected image: $($Context.SelectedImageMetadata.ImageName)"
        }

        if ($Context.Architecture) {
            Write-Output "Architecture: $($Context.Architecture)"
        }
    }
}

function Invoke-ValidationOnly {
    param (
        [pscustomobject]$Context,
        [string]$DefaultISO,
        [string]$SourceIsoPath,
        [int]$RequestedImageIndex
    )

    Write-Output "ValidateOnly specified. Running preflight checks without modifying image files."
    $Context.SourceDrive = Resolve-SourceDrive -Context $Context -DefaultISO $DefaultISO -SourceIsoPath $SourceIsoPath
    $Context.SourceBootWimPath = "$($Context.SourceDrive)\sources\boot.wim"
    $Context.SourceInstallWimPath = "$($Context.SourceDrive)\sources\install.wim"
    $Context.SourceInstallEsdPath = "$($Context.SourceDrive)\sources\install.esd"

    Test-BuildWorkspace -BuildRoot $Context.BuildRoot -SourceDrive $Context.SourceDrive
    Test-PathParentWritable -Path $Context.OutputIsoPath -Description 'Output ISO'
    Write-Output "Preflight checks passed."

    $imagePathToInspect = if (Test-Path -LiteralPath $Context.SourceInstallWimPath) {
        $Context.SourceInstallWimPath
    } elseif (Test-Path -LiteralPath $Context.SourceInstallEsdPath) {
        $Context.SourceInstallEsdPath
    } else {
        throw "Can't find Windows OS installation files in the specified drive letter."
    }

    $Context.SelectedImageMetadata = Select-WindowsImageMetadata -Context $Context -ImagePath $imagePathToInspect -RequestedIndex $RequestedImageIndex
    $Context.ImageIndex = $Context.SelectedImageMetadata.ImageIndex
    $Context.Architecture = Resolve-ImageArchitecture -Architecture $Context.SelectedImageMetadata.Architecture

    if ($Context.SelectedImageMetadata.ImageName) {
        Write-Output "Selected image: $($Context.SelectedImageMetadata.ImageName)"
    }

    if ($Context.Architecture) {
        Write-Output "Architecture: $($Context.Architecture)"
    }

    Write-Output "Validation completed successfully."
}

function Resolve-OscdimgPath {
    param (
        [pscustomobject]$Context
    )

    $adkDeploymentToolsPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$($Context.HostArchitecture)\Oscdimg"
    if ([System.IO.Directory]::Exists($adkDeploymentToolsPath)) {
        Write-Output "Will be using oscdimg.exe from system ADK."
        return (Join-Path -Path $adkDeploymentToolsPath -ChildPath 'oscdimg.exe')
    }

    Write-Output "ADK folder not found. Will be using bundled oscdimg.exe."
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

    if (-not (Test-Path -Path $Context.LocalOscdimgPath)) {
        Write-Output "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri $url -OutFile $Context.LocalOscdimgPath -ErrorAction Stop

        if (Test-Path $Context.LocalOscdimgPath) {
            Write-Output "oscdimg.exe downloaded successfully."
            $Context.DownloadedOscdimg = $true
        } else {
            throw "Failed to download oscdimg.exe."
        }
    } else {
        Write-Output "oscdimg.exe already exists locally."
    }

    return $Context.LocalOscdimgPath
}

function Get-ProvisionedAppPackageSetCatalog {
    return @{
        default = @(
            'AppUp.IntelManagementandSecurityStatus',
            'Clipchamp.Clipchamp',
            'DolbyLaboratories.DolbyAccess',
            'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
            'Microsoft.BingNews',
            'Microsoft.BingSearch',
            'Microsoft.BingWeather',
            'Microsoft.Copilot',
            'Microsoft.Windows.CrossDevice',
            'Microsoft.GamingApp',
            'Microsoft.GetHelp',
            'Microsoft.Getstarted',
            'Microsoft.Microsoft3DViewer',
            'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.MicrosoftStickyNotes',
            'Microsoft.MixedReality.Portal',
            'Microsoft.MSPaint',
            'Microsoft.Office.OneNote',
            'Microsoft.OfficePushNotificationUtility',
            'Microsoft.OutlookForWindows',
            'Microsoft.Paint',
            'Microsoft.People',
            'Microsoft.PowerAutomateDesktop',
            'Microsoft.SkypeApp',
            'Microsoft.StartExperiencesApp',
            'Microsoft.Todos',
            'Microsoft.Wallet',
            'Microsoft.Windows.DevHome',
            'Microsoft.Windows.Copilot',
            'Microsoft.Windows.Teams',
            'Microsoft.WindowsAlarms',
            'Microsoft.WindowsCamera',
            'microsoft.windowscommunicationsapps',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.WindowsMaps',
            'Microsoft.WindowsSoundRecorder',
            'Microsoft.WindowsTerminal',
            'Microsoft.Xbox.TCUI',
            'Microsoft.XboxApp',
            'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay',
            'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.YourPhone',
            'Microsoft.ZuneMusic',
            'Microsoft.ZuneVideo',
            'MicrosoftCorporationII.MicrosoftFamily',
            'MicrosoftCorporationII.QuickAssist',
            'MSTeams',
            'MicrosoftTeams',
            'Microsoft.WindowsTerminal',
            'Microsoft.549981C3F5F10'
        )
        compatibility = @(
            'Microsoft.BingNews',
            'Microsoft.BingSearch',
            'Microsoft.BingWeather',
            'Microsoft.Copilot',
            'Microsoft.Windows.CrossDevice',
            'Microsoft.GamingApp',
            'Microsoft.Getstarted',
            'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.MixedReality.Portal',
            'Microsoft.OutlookForWindows',
            'Microsoft.People',
            'Microsoft.PowerAutomateDesktop',
            'Microsoft.SkypeApp',
            'Microsoft.StartExperiencesApp',
            'Microsoft.Todos',
            'Microsoft.Wallet',
            'Microsoft.Windows.DevHome',
            'Microsoft.Windows.Copilot',
            'Microsoft.Windows.Teams',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.WindowsMaps',
            'Microsoft.Xbox.TCUI',
            'Microsoft.XboxApp',
            'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay',
            'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.YourPhone',
            'Microsoft.ZuneMusic',
            'Microsoft.ZuneVideo',
            'MicrosoftCorporationII.MicrosoftFamily',
            'MSTeams',
            'MicrosoftTeams',
            'Microsoft.549981C3F5F10'
        )
        minimal = @(
            'AppUp.IntelManagementandSecurityStatus',
            'Clipchamp.Clipchamp',
            'DolbyLaboratories.DolbyAccess',
            'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
            'Microsoft.BingNews',
            'Microsoft.BingSearch',
            'Microsoft.BingWeather',
            'Microsoft.Copilot',
            'Microsoft.Windows.CrossDevice',
            'Microsoft.GamingApp',
            'Microsoft.GetHelp',
            'Microsoft.Getstarted',
            'Microsoft.Microsoft3DViewer',
            'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.MicrosoftStickyNotes',
            'Microsoft.MixedReality.Portal',
            'Microsoft.MSPaint',
            'Microsoft.Office.OneNote',
            'Microsoft.OfficePushNotificationUtility',
            'Microsoft.OutlookForWindows',
            'Microsoft.Paint',
            'Microsoft.People',
            'Microsoft.PowerAutomateDesktop',
            'Microsoft.ScreenSketch',
            'Microsoft.SkypeApp',
            'Microsoft.StartExperiencesApp',
            'Microsoft.Todos',
            'Microsoft.Wallet',
            'Microsoft.Windows.DevHome',
            'Microsoft.Windows.Copilot',
            'Microsoft.Windows.Photos',
            'Microsoft.Windows.Teams',
            'Microsoft.WindowsAlarms',
            'Microsoft.WindowsCamera',
            'microsoft.windowscommunicationsapps',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.WindowsMaps',
            'Microsoft.WindowsNotepad',
            'Microsoft.WindowsSoundRecorder',
            'Microsoft.WindowsTerminal',
            'Microsoft.Xbox.TCUI',
            'Microsoft.XboxApp',
            'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay',
            'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.YourPhone',
            'Microsoft.ZuneMusic',
            'Microsoft.ZuneVideo',
            'MicrosoftCorporationII.MicrosoftFamily',
            'MicrosoftCorporationII.QuickAssist',
            'MSTeams',
            'MicrosoftTeams',
            'Microsoft.WindowsTerminal',
            'Microsoft.549981C3F5F10'
        )
    }
}

function Get-ProvisionedAppPackagePrefixes {
    param (
        [pscustomobject]$Context
    )

    return (Resolve-SetFromCatalog -Catalog (Get-ProvisionedAppPackageSetCatalog) -SelectedSetName $Context.BuildProfile.AppPackageSet -SetDescription 'App package')
}

function Get-InstallImageRegistryActionGroupCatalog {
    return @(
        @{
            Name = 'bypass_system_requirements'
            Message = "Bypassing system requirements(on the system image):"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassStorageCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'disable_sponsored_apps'
            Message = "Disabling Sponsored Apps:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins'; ValueType = 'REG_SZ'; Value = '{"pinnedList": [{}]}' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContentEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall'; Name = 'DisablePushToInstall'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\MRT'; Name = 'DontOfferThroughWUAU'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'RemoveKey'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' },
                @{ Operation = 'RemoveKey'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableConsumerAccountStateContent'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'enable_local_accounts_on_oobe'
            Message = "Enabling Local Accounts on OOBE:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'disable_reserved_storage'
            Message = "Disabling Reserved Storage:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; ValueType = 'REG_DWORD'; Value = '0' }
            )
        },
        @{
            Name = 'disable_bitlocker_device_encryption'
            Message = "Disabling BitLocker Device Encryption"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker'; Name = 'PreventDeviceEncryption'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'disable_chat_icon'
            Message = "Disabling Chat icon:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; ValueType = 'REG_DWORD'; Value = '3' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; ValueType = 'REG_DWORD'; Value = '0' }
            )
        },
        @{
            Name = 'remove_edge_related_registries'
            Message = "Removing Edge related registries"
            Actions = @(
                @{ Operation = 'RemoveKey'; Path = 'HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' },
                @{ Operation = 'RemoveKey'; Path = 'HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' }
            )
        },
        @{
            Name = 'disable_onedrive_folder_backup'
            Message = "Disabling OneDrive folder backup"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'disable_telemetry'
            Message = "Disabling Telemetry:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice'; Name = 'Start'; ValueType = 'REG_DWORD'; Value = '4' }
            )
        },
        @{
            Name = 'prevent_devhome_and_outlook'
            Message = "Prevents installation of DevHome and Outlook:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'; Name = 'workCompleted'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name = 'workCompleted'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name = 'workCompleted'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'RemoveKey'; Path = 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' },
                @{ Operation = 'RemoveKey'; Path = 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' }
            )
        },
        @{
            Name = 'disable_copilot'
            Message = "Disabling Copilot"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'prevent_teams_installation'
            Message = "Prevents installation of Teams:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Teams'; Name = 'DisableInstallation'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        },
        @{
            Name = 'prevent_new_outlook_installation'
            Message = "Prevent installation of New Outlook:"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail'; Name = 'PreventRun'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        }
    )
}

function Get-InstallImageRegistryActionGroups {
    param (
        [pscustomobject]$Context
    )

    return (Resolve-RegistryActionGroupsFromCatalog -Catalog (Get-InstallImageRegistryActionGroupCatalog) -SelectedGroupNames $Context.BuildProfile.InstallRegistryGroups -ProfileName $Context.ProfileName -CatalogDescription 'Install registry')
}

function Get-SetupImageRegistryActionGroupCatalog {
    return @(
        @{
            Name = 'bypass_system_requirements'
            Message = "Bypassing system requirements(on the setup image):"
            Actions = @(
                @{ Operation = 'Set'; Path = 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; ValueType = 'REG_DWORD'; Value = '0' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassStorageCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck'; ValueType = 'REG_DWORD'; Value = '1' },
                @{ Operation = 'Set'; Path = 'HKLM\zSYSTEM\Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; ValueType = 'REG_DWORD'; Value = '1' }
            )
        }
    )
}

function Get-SetupImageRegistryActionGroups {
    param (
        [pscustomobject]$Context
    )

    return (Resolve-RegistryActionGroupsFromCatalog -Catalog (Get-SetupImageRegistryActionGroupCatalog) -SelectedGroupNames $Context.BuildProfile.SetupRegistryGroups -ProfileName $Context.ProfileName -CatalogDescription 'Setup registry')
}

function Get-ScheduledTaskDefinitionSetCatalog {
    return @{
        default = @(
            'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            'Microsoft\Windows\Customer Experience Improvement Program',
            'Microsoft\Windows\Application Experience\ProgramDataUpdater',
            'Microsoft\Windows\Chkdsk\Proxy',
            'Microsoft\Windows\Windows Error Reporting\QueueReporting'
        )
        compatibility = @(
            'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            'Microsoft\Windows\Customer Experience Improvement Program',
            'Microsoft\Windows\Application Experience\ProgramDataUpdater',
            'Microsoft\Windows\Chkdsk\Proxy',
            'Microsoft\Windows\Windows Error Reporting\QueueReporting'
        )
        minimal = @(
            'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            'Microsoft\Windows\Customer Experience Improvement Program',
            'Microsoft\Windows\Application Experience\ProgramDataUpdater',
            'Microsoft\Windows\Chkdsk\Proxy',
            'Microsoft\Windows\Windows Error Reporting\QueueReporting'
        )
    }
}

function Get-ScheduledTaskDefinitionPaths {
    param (
        [pscustomobject]$Context
    )

    return (Resolve-SetFromCatalog -Catalog (Get-ScheduledTaskDefinitionSetCatalog) -SelectedSetName $Context.BuildProfile.ScheduledTaskSet -SetDescription 'Scheduled task')
}

function Invoke-RegistryActionGroups {
    param (
        [object[]]$Groups
    )

    foreach ($group in $Groups) {
        Write-Output $group.Message
        foreach ($action in $group.Actions) {
            switch ($action.Operation) {
                'Set' {
                    Set-RegistryValue $action.Path $action.Name $action.ValueType $action.Value
                }
                'RemoveKey' {
                    Remove-RegistryValue $action.Path
                }
                default {
                    throw "Unsupported registry action '$($action.Operation)'."
                }
            }
        }
    }
}

function Invoke-InstallImageBuild {
    param (
        [pscustomobject]$Context
    )

    Write-Output "Mounting Windows image. This may take a while."
    $wimFilePath = $Context.InstallWimPath
    Invoke-NativeCommand -FilePath 'takeown' -Arguments @('/F', $wimFilePath) -OperationDescription "taking ownership of $wimFilePath" -Quiet
    Invoke-NativeCommand -FilePath 'icacls' -Arguments @($wimFilePath, '/grant', "$($Context.AdminGroupName):(F)") -OperationDescription "granting access to $wimFilePath" -Quiet
    try {
        Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch {
        Write-Error "$wimFilePath not found"
    }

    New-Item -ItemType Directory -Force -Path $Context.ScratchDirectoryPath | Out-Null
    Mount-WindowsImage -ImagePath $Context.InstallWimPath -Index $Context.ImageIndex -Path $Context.ScratchDirectoryPath -ErrorAction Stop
    $Context.MountedImagePath = $Context.ScratchDirectoryPath

    $imageIntl = Invoke-NativeCommand -FilePath 'dism' -Arguments @('/English', '/Get-Intl', "/Image:$($Context.ScratchDirectoryPath)") -OperationDescription 'reading mounted image language information' -CaptureOutput -Quiet
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $Context.LanguageCode = $Matches[1]
        Write-Output "Default system UI language code: $($Context.LanguageCode)"
    } else {
        Write-Output "Default system UI language code not found."
    }

    if (-not $Context.Architecture) {
        Write-Output "Architecture information not found."
    } else {
        Write-Output "Architecture: $($Context.Architecture)"
    }

    Write-Output "Mounting complete! Performing removal of applications..."

    $packages = Invoke-NativeCommand -FilePath 'dism' -Arguments @('/English', "/image:$($Context.ScratchDirectoryPath)", '/Get-ProvisionedAppxPackages') -OperationDescription 'listing provisioned app packages' -CaptureOutput -Quiet |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') {
                $matches[1]
            }
        }

    $packagePrefixes = Get-ProvisionedAppPackagePrefixes -Context $Context

    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "*$_*" })
    }

    foreach ($package in $packagesToRemove) {
        Invoke-NativeCommand -FilePath 'dism' -Arguments @('/English', "/image:$($Context.ScratchDirectoryPath)", '/Remove-ProvisionedAppxPackage', "/PackageName:$package") -OperationDescription "removing provisioned app package $package" -Quiet
    }

    if ($Context.BuildProfile.RemoveEdge) {
        Write-Output "Removing Edge:"
        Remove-Item -Path "$($Context.ScratchDirectoryPath)\Program Files (x86)\Microsoft\Edge" -Recurse -Force | Out-Null
        Remove-Item -Path "$($Context.ScratchDirectoryPath)\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force | Out-Null
        Remove-Item -Path "$($Context.ScratchDirectoryPath)\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force | Out-Null
        Invoke-NativeCommand -FilePath 'takeown' -Arguments @('/f', "$($Context.ScratchDirectoryPath)\Windows\System32\Microsoft-Edge-Webview", '/r') -OperationDescription 'taking ownership of Microsoft Edge WebView files' -Quiet
        Invoke-NativeCommand -FilePath 'icacls' -Arguments @("$($Context.ScratchDirectoryPath)\Windows\System32\Microsoft-Edge-Webview", '/grant', "$($Context.AdminGroupName):(F)", '/T', '/C') -OperationDescription 'granting access to Microsoft Edge WebView files' -Quiet
        Remove-Item -Path "$($Context.ScratchDirectoryPath)\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force | Out-Null
    } else {
        Write-Output "Profile keeps Microsoft Edge."
    }

    if ($Context.BuildProfile.RemoveOneDrive) {
        Write-Output "Removing OneDrive:"
        Invoke-NativeCommand -FilePath 'takeown' -Arguments @('/f', "$($Context.ScratchDirectoryPath)\Windows\System32\OneDriveSetup.exe") -OperationDescription 'taking ownership of OneDrive setup' -Quiet
        Invoke-NativeCommand -FilePath 'icacls' -Arguments @("$($Context.ScratchDirectoryPath)\Windows\System32\OneDriveSetup.exe", '/grant', "$($Context.AdminGroupName):(F)", '/T', '/C') -OperationDescription 'granting access to OneDrive setup' -Quiet
        Remove-Item -Path "$($Context.ScratchDirectoryPath)\Windows\System32\OneDriveSetup.exe" -Force | Out-Null
    } else {
        Write-Output "Profile keeps OneDrive."
    }
    Write-Output "Removal complete!"
    Start-Sleep -Seconds 2
    Clear-Host
    Write-Output "Loading registry..."
    Load-OfflineRegistryHives -Context $Context
    Invoke-RegistryActionGroups -Groups (Get-InstallImageRegistryActionGroups -Context $Context)
    Copy-Item -Path $Context.UnattendPath -Destination "$($Context.ScratchDirectoryPath)\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
    Write-Host "Deleting scheduled task definition files..."

    $tasksPath = "$($Context.ScratchDirectoryPath)\Windows\System32\Tasks"
    foreach ($taskDefinitionPath in Get-ScheduledTaskDefinitionPaths -Context $Context) {
        Remove-Item -Path (Join-Path -Path $tasksPath -ChildPath $taskDefinitionPath) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Task files have been deleted."
    Write-Host "Unmounting Registry..."
    Unload-OfflineRegistryHives -Context $Context
    Write-Output "Cleaning up image..."
    Invoke-NativeCommand -FilePath 'dism' -Arguments @("/Image:$($Context.ScratchDirectoryPath)", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') -OperationDescription 'cleaning up the mounted Windows image'
    Write-Output "Cleanup complete."
    Write-Output ' '
    Write-Output "Unmounting image..."
    Dismount-WindowsImage -Path $Context.ScratchDirectoryPath -Save -ErrorAction Stop
    $Context.MountedImagePath = $null
    Write-Host "Exporting image..."
    Invoke-NativeCommand -FilePath 'dism' -Arguments @('/Export-Image', "/SourceImageFile:$($Context.InstallWimPath)", "/SourceIndex:$($Context.ImageIndex)", "/DestinationImageFile:$($Context.SourcesPath)\install2.wim", '/Compress:recovery') -OperationDescription 'exporting the optimized Windows image'
    Remove-Item -Path $Context.InstallWimPath -Force | Out-Null
    Rename-Item -Path "$($Context.SourcesPath)\install2.wim" -NewName "install.wim" | Out-Null
    Write-Output "Windows image completed. Continuing with boot.wim."
    Start-Sleep -Seconds 2
    Clear-Host
}

function Invoke-BootImageBuild {
    param (
        [pscustomobject]$Context
    )

    Write-Output "Mounting boot image:"
    $wimFilePath = $Context.BootWimPath
    Invoke-NativeCommand -FilePath 'takeown' -Arguments @('/F', $wimFilePath) -OperationDescription "taking ownership of $wimFilePath" -Quiet
    Invoke-NativeCommand -FilePath 'icacls' -Arguments @($wimFilePath, '/grant', "$($Context.AdminGroupName):(F)") -OperationDescription "granting access to $wimFilePath" -Quiet
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
    Mount-WindowsImage -ImagePath $Context.BootWimPath -Index 2 -Path $Context.ScratchDirectoryPath -ErrorAction Stop
    $Context.MountedImagePath = $Context.ScratchDirectoryPath
    Write-Output "Loading registry..."
    Load-OfflineRegistryHives -Context $Context

    Invoke-RegistryActionGroups -Groups (Get-SetupImageRegistryActionGroups -Context $Context)
    Write-Output "Tweaking complete!"

    Write-Output "Unmounting Registry..."
    Unload-OfflineRegistryHives -Context $Context
    Write-Output "Unmounting image..."
    Dismount-WindowsImage -Path $Context.ScratchDirectoryPath -Save -ErrorAction Stop
    $Context.MountedImagePath = $null
    Clear-Host
}

function Build-Tiny11Iso {
    param (
        [pscustomobject]$Context
    )

    Write-Output "The tiny11 image is now completed. Proceeding with the making of the ISO..."
    Write-Output "Copying unattended file for bypassing MS account on OOBE..."
    Copy-Item -Path $Context.UnattendPath -Destination (Join-Path -Path $Context.BuildWorkspacePath -ChildPath 'autounattend.xml') -Force | Out-Null
    Write-Output "Creating ISO image..."

    Ensure-ParentDirectory -Path $Context.OutputIsoPath -Description 'output ISO parent'
    $oscdimgPath = Resolve-OscdimgPath -Context $Context
    Invoke-NativeCommand -FilePath $oscdimgPath -Arguments @('-m', '-o', '-u2', '-udfver102', "-bootdata:2#p0,e,b$($Context.BuildWorkspacePath)\boot\etfsboot.com#pEF,e,b$($Context.BuildWorkspacePath)\efi\microsoft\boot\efisys.bin", $Context.BuildWorkspacePath, $Context.OutputIsoPath) -OperationDescription 'creating the final tiny11 ISO'
}

function Invoke-BuildCleanup {
    param (
        [pscustomobject]$Context
    )

    if ($Context.BuildSucceeded -and -not $Context.NoCleanup) {
        Write-Output "Performing Cleanup..."
        Remove-PathIfExists -Path $Context.BuildWorkspacePath -Description 'tiny11 working folder'
        Remove-PathIfExists -Path $Context.ScratchDirectoryPath -Description 'scratch directory'
    } elseif ($Context.BuildSucceeded) {
        Write-Output "NoCleanup specified. Preserving working files in '$($Context.BuildWorkspacePath)' and '$($Context.ScratchDirectoryPath)'."
    } else {
        if ($Context.NoCleanup) {
            Write-Warning "Build failed and NoCleanup is set. Working files were preserved in '$($Context.BuildWorkspacePath)' and '$($Context.ScratchDirectoryPath)'."
        } else {
            Remove-PathIfExists -Path $Context.ScratchDirectoryPath -Description 'scratch directory'
            Write-Warning "Build failed. The working files in '$($Context.BuildWorkspacePath)' have been preserved for troubleshooting."
        }
    }

    if ($Context.AutoMountedSourceIso -and $Context.SourceIsoPath) {
        Write-Output "Dismounting source ISO..."
        try {
            Dismount-DiskImage -ImagePath $Context.SourceIsoPath -ErrorAction Stop
            Write-Output "Source ISO dismounted."
        } catch {
            Write-Warning "Could not automatically dismount source ISO '$($Context.SourceIsoPath)'."
        }
    } elseif ($Context.BuildSucceeded -and $Context.SourceDrive) {
        Write-Output "Ejecting ISO drive..."
        try {
            Get-Volume -DriveLetter $Context.SourceDrive[0] -ErrorAction Stop | Get-DiskImage -ErrorAction Stop | Dismount-DiskImage -ErrorAction Stop
            Write-Output "ISO drive ejected."
        } catch {
            Write-Warning "Could not automatically eject drive $($Context.SourceDrive)."
        }
    }

    if ($Context.DownloadedOscdimg -and -not $Context.KeepDownloadedTools) {
        Remove-PathIfExists -Path $Context.LocalOscdimgPath -Description 'downloaded oscdimg.exe'
    } elseif ($Context.DownloadedOscdimg -and $Context.KeepDownloadedTools) {
        Write-Output "KeepDownloadedTools specified. Preserving '$($Context.LocalOscdimgPath)'."
    }
}

#---------[ Execution ]---------#
if ($env:TINY11MAKER_SKIP_MAIN -eq '1') {
    return
}

if ($ISO -and $SourceIsoPath) {
    throw "Specify either -ISO/-SourceDrive or -SourceIsoPath, but not both."
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole))
{
    Write-Output "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $PSHOME 'powershell.exe')
    $newProcess.Arguments = Get-ElevationArguments -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Output "PowerShell is running with a Restricted execution policy. tiny11maker will continue in this session using Bypass scope only."
    Set-ExecutionPolicy Bypass -Scope Process -Force
}
$Context = New-BuildContext -BuildRoot $ScratchDisk -ScriptRoot $PSScriptRoot -AdminGroupName $adminGroup.Value -OutputIsoPath $OutputPath -UnattendPath $UnattendPath -ProfileName $Profile -ProfilePath $ProfilePath -NoCleanup:$NoCleanup -KeepDownloadedTools:$KeepDownloadedTools -PauseAtEnd:(-not $NoPause)

if (-not (Test-Path -Path $Context.UnattendPath)) {
    Invoke-RestMethod "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile $Context.UnattendPath -ErrorAction Stop
}

try {
    Start-Transcript -Path $Context.TranscriptPath -ErrorAction Stop
    $Context.TranscriptStarted = $true

    $Host.UI.RawUI.WindowTitle = "Tiny11 image creator"
    Clear-Host
    Write-Output "Welcome to the tiny11 image creator! Release: 09-07-25"
    Import-BuildProfile -Context $Context

    if ($ValidateOnly) {
        Invoke-BuildStage -Context $Context -Name 'Validate build inputs' -ScriptBlock {
            Invoke-ValidationOnly -Context $Context -DefaultISO $ISO -SourceIsoPath $SourceIsoPath -RequestedImageIndex $Index
        }
    } else {
        Invoke-BuildStage -Context $Context -Name 'Prepare source media' -ScriptBlock {
            Prepare-SourceMedia -Context $Context -DefaultISO $ISO -SourceIsoPath $SourceIsoPath -RequestedImageIndex $Index
        }
        Invoke-BuildStage -Context $Context -Name 'Build install image' -ScriptBlock {
            Invoke-InstallImageBuild -Context $Context
        }
        Invoke-BuildStage -Context $Context -Name 'Patch boot image' -ScriptBlock {
            Invoke-BootImageBuild -Context $Context
        }
        Invoke-BuildStage -Context $Context -Name 'Create ISO' -ScriptBlock {
            Build-Tiny11Iso -Context $Context
        }
    }

    $Context.BuildSucceeded = $true
    Write-BuildSummary -Context $Context
    if ($ValidateOnly) {
        Write-Output "Validation completed."
    } elseif ($Context.PauseAtEnd) {
        Write-Output "Creation completed! Press any key to exit the script..."
        Read-Host "Press Enter to continue"
    } else {
        Write-Output "Creation completed."
    }
} catch {
    $Context.ExitCode = 1
    Write-Error "tiny11 image creation failed: $($_.Exception.Message)"
    Write-BuildSummary -Context $Context
} finally {
    if ($Context.OfflineRegistryLoaded) {
        Write-Output "Attempting to unload offline registry hives..."
        Unload-OfflineRegistryHives -Context $Context
    }

    if ($Context.MountedImagePath) {
        Write-Output "Attempting to dismount the mounted image..."
        try {
            Dismount-WindowsImage -Path $Context.MountedImagePath -Discard -ErrorAction Stop
            Write-Output "Mounted image discarded successfully."
        } catch {
            Write-Warning "Failed to dismount $($Context.MountedImagePath). You may need to discard it manually."
        } finally {
            $Context.MountedImagePath = $null
        }
    }

    Invoke-BuildCleanup -Context $Context

    if ($Context.TranscriptStarted) {
        Stop-Transcript
    }
}

exit $Context.ExitCode

