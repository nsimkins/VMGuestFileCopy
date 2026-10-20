<#
.SYNOPSIS
    Downloads the minimum PowerCLI modules needed for Copy-VMGuestFile into a
    .\Modules folder, so the GUI can be copied to servers with nothing installed.

.DESCRIPTION
    Run this once on any machine with internet access to the PowerShell Gallery,
    then copy the whole folder (script + Modules) to the target server.
    Only VMware.VimAutomation.Core and its dependencies are saved (~a fraction
    of the full PowerCLI bundle).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'Modules')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
}

Write-Host "Saving VMware.VimAutomation.Core and dependencies to $Path ..."
Save-Module -Name VMware.VimAutomation.Core -Path $Path -Repository PSGallery

# Remove the "downloaded from the internet" mark so the files load without prompts.
Get-ChildItem -LiteralPath $Path -Recurse -File | Unblock-File

Get-ChildItem -LiteralPath $Path -Directory | ForEach-Object {
    $versions = (Get-ChildItem -LiteralPath $_.FullName -Directory).Name -join ', '
    Write-Host ("  {0} {1}" -f $_.Name, $versions)
}
Write-Host 'Done. Copy this whole folder to the target server.'
