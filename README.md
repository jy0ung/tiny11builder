# tiny11builder

PowerShell scripts for building a trimmed-down Windows 11 image.

## Scripts

- `tiny11maker.ps1`
  The regular builder. It removes common inbox apps and applies setup/privacy tweaks while keeping the image serviceable.
- `tiny11Coremaker.ps1`
  The more aggressive builder. It produces a much smaller image, but it is not intended for normal long-term use because serviceability is heavily reduced.

## Requirements

- Windows with PowerShell 5.1
- Administrator privileges
- DISM PowerShell cmdlets available:
  `Get-WindowsImage`, `Export-WindowsImage`, `Mount-WindowsImage`, `Dismount-WindowsImage`
- `robocopy` available on the host
- A Windows 11 ISO or a mounted Windows 11 install drive

## Quick Start

1. Open an elevated PowerShell window.
2. Change into the repository folder.
3. Run one of the examples below.

Mounted ISO drive example:

```powershell
.\tiny11maker.ps1 -ISO E -SCRATCH D -Index 1
```

Direct ISO path example:

```powershell
.\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -SCRATCH D -Index 1
```

Fully unattended example:

```powershell
.\tiny11maker.ps1 `
  -SourceIsoPath C:\ISO\Win11.iso `
  -SCRATCH D `
  -Index 1 `
  -Profile compatibility `
  -OutputPath C:\ISO\tiny11-custom.iso `
  -UnattendPath .\autounattend.xml `
  -NoPause
```

The finished ISO is written to `tiny11.iso` in the repo root unless `-OutputPath` is provided.

## Validate Only

Use `-ValidateOnly` to check source media, selected image index, profile selection, scratch path, and output path without starting the actual image build.

```powershell
.\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -Index 1 -Profile default -ValidateOnly
```

This mode is useful before long unattended runs.

## Profiles

`tiny11maker.ps1` now supports build profiles from [`tiny11maker.profiles.psd1`](/C:/Users/user/Documents/GitHub/tiny11builder/tiny11maker.profiles.psd1).

Built-in profiles:

- `default`
  Matches the current regular tiny11maker behavior.
- `compatibility`
  Keeps Edge and OneDrive and uses a lighter app-removal set.
- `minimal`
  Removes a few more inbox apps than `default`.

Select a profile with:

```powershell
.\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -Index 1 -Profile compatibility
```

Use a custom profile file with:

```powershell
.\tiny11maker.ps1 -SourceIsoPath C:\ISO\Win11.iso -Index 1 -Profile myprofile -ProfilePath .\tiny11maker.profiles.psd1
```

## Parameters

Common parameters for `tiny11maker.ps1`:

| Parameter | Purpose |
| --- | --- |
| `-ISO` / `-SourceDrive` | Mounted Windows install drive letter |
| `-SourceIsoPath` | ISO file path to mount automatically |
| `-SCRATCH` / `-ScratchDrive` | Scratch/build drive letter |
| `-Index` / `-ImageIndex` | Windows image index to build |
| `-OutputPath` | Output ISO path or directory |
| `-UnattendPath` | Custom unattended XML file |
| `-Profile` | Build profile name |
| `-ProfilePath` | Custom profile data file |
| `-NoCleanup` | Preserve build workspace and scratch directory |
| `-KeepDownloadedTools` | Preserve downloaded `oscdimg.exe` |
| `-NoPause` | Skip the final prompt |
| `-ValidateOnly` | Run fast validation without building the ISO |

Run `Get-Help .\tiny11maker.ps1 -Detailed` for inline script help.

## Cleanup and Logging

- Successful builds remove the working folder and scratch directory by default.
- `-NoCleanup` preserves those folders for inspection.
- If the script auto-mounted the source ISO, it will try to dismount it during cleanup.
- The script writes a transcript log named like `tiny11_YYYYMMDD_HHMMSS.log` in the repo root.
- A build summary is printed at the end with stage timings, selected image, profile, and output path.

## Tests

Phase 7 added a lightweight Pester suite for helper logic, profile loading, and parameter metadata.

Run the tests with:

```powershell
Invoke-Pester .\tests\tiny11maker.Tests.ps1
```

The tests do not build an ISO. They load the script in a test mode that skips the main execution path.

## What tiny11maker removes

The default profile removes common inbox apps and applies tweaks such as:

- Clipchamp
- News
- Weather
- Xbox apps
- Get Help / Get Started
- Office Hub
- Solitaire
- People
- Power Automate
- To Do
- Feedback Hub
- Maps
- Sound Recorder
- Phone Link
- Outlook for Windows
- Teams consumer packages
- Edge
- OneDrive

The exact set now depends on the selected profile.

## Known Notes

- `tiny11maker.ps1` still needs an elevated PowerShell session for DISM image operations.
- A full elevated end-to-end build should still be considered the final verification step after code changes.
- `tiny11Coremaker.ps1` remains the aggressive option and is not documented here in the same detail.

## Support

If this project helps you, consider supporting the original project:

**[Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)**
