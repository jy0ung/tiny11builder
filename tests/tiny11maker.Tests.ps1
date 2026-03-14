$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$scriptPath = Join-Path -Path $repoRoot -ChildPath 'tiny11maker.ps1'
$profilesPath = Join-Path -Path $repoRoot -ChildPath 'tiny11maker.profiles.psd1'
$unattendPath = Join-Path -Path $repoRoot -ChildPath 'autounattend.xml'

$env:TINY11MAKER_SKIP_MAIN = '1'
. $scriptPath
Remove-Item Env:TINY11MAKER_SKIP_MAIN -ErrorAction SilentlyContinue

function New-TestBuildContext {
    param (
        [string]$ProfileName = $null
    )

    return New-BuildContext -BuildRoot $repoRoot -ScriptRoot $repoRoot -AdminGroupName 'BUILTIN\Administrators' -OutputIsoPath (Join-Path -Path $repoRoot -ChildPath 'artifacts\tiny11.iso') -UnattendPath $unattendPath -ProfileName $ProfileName -ProfilePath $profilesPath -PauseAtEnd:$false
}

Describe 'tiny11maker script metadata' {
    It 'exposes the ValidateOnly parameter' {
        $command = Get-Command $scriptPath
        $command.Parameters.ContainsKey('ValidateOnly') | Should Be $true
    }

    It 'validates ISO as a single drive letter' {
        $command = Get-Command $scriptPath
        $attribute = $command.Parameters['ISO'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
        $attribute.RegexPattern | Should Be '^[c-zC-Z]$'
    }

    It 'validates Index in the expected range' {
        $command = Get-Command $scriptPath
        $attribute = $command.Parameters['Index'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
        $attribute.MinRange | Should Be 1
        $attribute.MaxRange | Should Be 999
    }
}

Describe 'tiny11maker profiles' {
    It 'loads the default profile when none is specified' {
        $context = New-TestBuildContext
        Import-BuildProfile -Context $context

        $context.ProfileName | Should Be 'default'
        $context.BuildProfile.AppPackageSet | Should Be 'default'
        $context.BuildProfile.RemoveEdge | Should Be $true
        $context.BuildProfile.RemoveOneDrive | Should Be $true
    }

    It 'loads the compatibility profile overrides' {
        $context = New-TestBuildContext -ProfileName 'compatibility'
        Import-BuildProfile -Context $context

        $context.ProfileName | Should Be 'compatibility'
        $context.BuildProfile.AppPackageSet | Should Be 'compatibility'
        $context.BuildProfile.RemoveEdge | Should Be $false
        $context.BuildProfile.RemoveOneDrive | Should Be $false
    }

    It 'throws for an unknown profile name' {
        $context = New-TestBuildContext -ProfileName 'does-not-exist'
        { Import-BuildProfile -Context $context } | Should Throw
    }
}

Describe 'tiny11maker helper functions' {
    It 'normalizes architecture aliases' {
        Resolve-ImageArchitecture -Architecture 'x64' | Should Be 'amd64'
        Resolve-ImageArchitecture -Architecture 9 | Should Be 'amd64'
        Resolve-ImageArchitecture -Architecture 'arm64' | Should Be 'arm64'
    }

    It 'caches image metadata per image path' {
        Mock Get-WindowsImage {
            @(
                [pscustomobject]@{
                    ImageIndex = 1
                    ImageName = 'Windows 11 Pro'
                    Architecture = 'x64'
                }
            )
        }

        $context = New-TestBuildContext
        $first = Get-CachedWindowsImageMetadata -Context $context -ImagePath 'C:\test\install.wim'
        $second = Get-CachedWindowsImageMetadata -Context $context -ImagePath 'C:\test\install.wim'

        $first[0].ImageName | Should Be 'Windows 11 Pro'
        $second[0].ImageIndex | Should Be 1
        Assert-MockCalled Get-WindowsImage -Times 1 -Exactly
    }

    It 'selects requested image metadata from the cached catalog' {
        Mock Get-WindowsImage {
            @(
                [pscustomobject]@{
                    ImageIndex = 1
                    ImageName = 'Windows 11 Home'
                    Architecture = 'x64'
                },
                [pscustomobject]@{
                    ImageIndex = 2
                    ImageName = 'Windows 11 Pro'
                    Architecture = 'x64'
                }
            )
        }

        $context = New-TestBuildContext
        $selected = Select-WindowsImageMetadata -Context $context -ImagePath 'C:\test\install.wim' -RequestedIndex 2

        $selected.ImageIndex | Should Be 2
        $selected.ImageName | Should Be 'Windows 11 Pro'
    }
}
