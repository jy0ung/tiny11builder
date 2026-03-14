@{
    DefaultProfile = 'default'
    Profiles = @{
        default = @{
            Description = 'Matches the current tiny11maker behavior.'
            AppPackageSet = 'default'
            InstallRegistryGroups = @(
                'bypass_system_requirements'
                'disable_sponsored_apps'
                'enable_local_accounts_on_oobe'
                'disable_reserved_storage'
                'disable_bitlocker_device_encryption'
                'disable_chat_icon'
                'remove_edge_related_registries'
                'disable_onedrive_folder_backup'
                'disable_telemetry'
                'prevent_devhome_and_outlook'
                'disable_copilot'
                'prevent_teams_installation'
                'prevent_new_outlook_installation'
            )
            SetupRegistryGroups = @(
                'bypass_system_requirements'
            )
            ScheduledTaskSet = 'default'
            RemoveEdge = $true
            RemoveOneDrive = $true
        }
        compatibility = @{
            Description = 'Keeps Edge and OneDrive while using a lighter app-removal set.'
            AppPackageSet = 'compatibility'
            InstallRegistryGroups = @(
                'bypass_system_requirements'
                'disable_sponsored_apps'
                'enable_local_accounts_on_oobe'
                'disable_reserved_storage'
                'disable_bitlocker_device_encryption'
                'disable_chat_icon'
                'disable_telemetry'
                'prevent_devhome_and_outlook'
                'disable_copilot'
                'prevent_teams_installation'
                'prevent_new_outlook_installation'
            )
            SetupRegistryGroups = @(
                'bypass_system_requirements'
            )
            ScheduledTaskSet = 'compatibility'
            RemoveEdge = $false
            RemoveOneDrive = $false
        }
        minimal = @{
            Description = 'Builds a more stripped-down image by removing a few extra inbox apps.'
            AppPackageSet = 'minimal'
            InstallRegistryGroups = @(
                'bypass_system_requirements'
                'disable_sponsored_apps'
                'enable_local_accounts_on_oobe'
                'disable_reserved_storage'
                'disable_bitlocker_device_encryption'
                'disable_chat_icon'
                'remove_edge_related_registries'
                'disable_onedrive_folder_backup'
                'disable_telemetry'
                'prevent_devhome_and_outlook'
                'disable_copilot'
                'prevent_teams_installation'
                'prevent_new_outlook_installation'
            )
            SetupRegistryGroups = @(
                'bypass_system_requirements'
            )
            ScheduledTaskSet = 'minimal'
            RemoveEdge = $true
            RemoveOneDrive = $true
        }
    }
}
