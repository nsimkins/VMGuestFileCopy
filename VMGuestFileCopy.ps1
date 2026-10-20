<#
.SYNOPSIS
    GUI front end for the PowerCLI Copy-VMGuestFile cmdlet.

.DESCRIPTION
    Connects to a vCenter Server or ESXi host, lists VMs, and copies files to or
    from a guest OS via VMware Tools. Uses only components built into Windows
    (PowerShell 5.1 + WPF). PowerCLI is loaded from a .\Modules folder next to
    this script if present, otherwise from the normal PSModulePath.

    Favourites (server and certificate option - no usernames or passwords) are
    stored per user in %APPDATA%\VMGuestFileCopy\favourites.json.

.NOTES
    Version : 0.13
    Increase by 0.01 for every change (0.1 -> 0.11 -> 0.12 ...) and keep
    $script:AppVersion below in step with it.
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

$script:AppVersion = '0.13'

# WPF needs an STA thread. Relaunch if we were started from an MTA host.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppDataDir = Join-Path $env:APPDATA 'VMGuestFileCopy'
$script:FavFile    = Join-Path $script:AppDataDir 'favourites.json'
$script:ModulesDir = Join-Path $PSScriptRoot 'Modules'

$script:ModuleLoaded = $false
$script:Connected    = $false
$script:Busy         = $false
$script:SuppressFavLoad = $false
$script:AllVMs       = @()
$script:SelectedVMId = $null
$script:UpdatingGrid = $false
$script:Favourites   = @()

#region XAML
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM Guest File Copy" Width="940" Height="800" MinWidth="780" MinHeight="660"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12">
    <Window.Resources>
        <Style TargetType="GroupBox">
            <Setter Property="Padding" Value="8"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="10,3"/>
            <Setter Property="Margin" Value="4,2"/>
            <Setter Property="MinWidth" Value="70"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Margin" Value="4,2"/>
            <Setter Property="Padding" Value="2"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Margin" Value="4,2"/>
            <Setter Property="Padding" Value="2"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="4,2,12,2"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="140"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="150"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Connection -->
        <GroupBox Grid.Row="0" Header="Connection (vCenter Server or ESXi host)">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Label Grid.Row="0" Grid.Column="0" Content="Server:"/>
                <ComboBox Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="3" x:Name="cmbServer"
                          IsEditable="True" Margin="4,2" Padding="4,3"
                          ToolTip="Type a host name / IP, or pick a favourite"/>
                <StackPanel Grid.Row="0" Grid.Column="4" Orientation="Horizontal">
                    <Button x:Name="btnAddFav" Content="Save favourite"
                            ToolTip="Save server and certificate option to favourites"/>
                    <Button x:Name="btnRemoveFav" Content="Remove"
                            ToolTip="Remove the selected server from favourites"/>
                </StackPanel>

                <Label Grid.Row="1" Grid.Column="0" Content="Username:"/>
                <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtUser"/>
                <Label Grid.Row="1" Grid.Column="2" Content="Password:"/>
                <PasswordBox Grid.Row="1" Grid.Column="3" x:Name="pwdPassword"/>

                <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="5" Orientation="Horizontal" Margin="0,4,0,0">
                    <CheckBox x:Name="chkIgnoreCert" Content="Ignore certificate errors"/>
                    <Button x:Name="btnConnect" Content="Connect" IsDefault="False"/>
                    <Button x:Name="btnDisconnect" Content="Disconnect"/>
                    <TextBlock x:Name="txtConnStatus" VerticalAlignment="Center" Margin="10,0,0,0"
                               Text="Not connected" Foreground="Gray"/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- VM list -->
        <GroupBox Grid.Row="1" Header="Virtual machine">
            <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
                    <Label DockPanel.Dock="Left" Content="Filter:"/>
                    <Button DockPanel.Dock="Right" x:Name="btnRefresh" Content="Refresh VMs"/>
                    <TextBox x:Name="txtFilter" ToolTip="Filter VMs by name"/>
                </DockPanel>
                <DataGrid x:Name="dgVMs" AutoGenerateColumns="False" IsReadOnly="True"
                          SelectionMode="Single" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                          CanUserAddRows="False" CanUserDeleteRows="False">
                    <DataGrid.CellStyle>
                        <!-- Keep the selected VM highlighted when focus moves to another control -->
                        <Style TargetType="DataGridCell">
                            <Style.Triggers>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/>
                                    <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.HighlightTextBrushKey}}"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                    </DataGrid.CellStyle>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Name"        Binding="{Binding Name}"       Width="2*"/>
                        <DataGridTextColumn Header="Power state" Binding="{Binding PowerState}" Width="100"/>
                        <DataGridTextColumn Header="VMware Tools" Binding="{Binding Tools}"     Width="110"/>
                        <DataGridTextColumn Header="Guest OS"    Binding="{Binding GuestOS}"    Width="2*"/>
                        <DataGridTextColumn Header="Host"        Binding="{Binding VMHost}"     Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </DockPanel>
        </GroupBox>

        <!-- Transfer -->
        <GroupBox Grid.Row="2" Header="File transfer">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Label Grid.Row="0" Grid.Column="0" Content="Direction:"/>
                <StackPanel Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="3" Orientation="Horizontal">
                    <RadioButton x:Name="rbToGuest" GroupName="dir" IsChecked="True" Margin="4,2,20,2"
                                 VerticalAlignment="Center" Content="Local &#x2192; Guest (upload)"/>
                    <RadioButton x:Name="rbFromGuest" GroupName="dir" Margin="4,2"
                                 VerticalAlignment="Center" Content="Guest &#x2192; Local (download)"/>
                </StackPanel>

                <Label Grid.Row="1" Grid.Column="0" Content="Guest user:"/>
                <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtGuestUser"
                         ToolTip="Account inside the guest OS, e.g. Administrator, DOMAIN\user or root"/>
                <Label Grid.Row="1" Grid.Column="2" Content="Guest password:"/>
                <PasswordBox Grid.Row="1" Grid.Column="3" x:Name="pwdGuestPassword"/>

                <Label Grid.Row="2" Grid.Column="0" x:Name="lblSource" Content="Source (local):"/>
                <DockPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3">
                    <Button DockPanel.Dock="Right" x:Name="btnSrcFolder" Content="Folder..."/>
                    <Button DockPanel.Dock="Right" x:Name="btnSrcFile" Content="File(s)..."/>
                    <TextBox x:Name="txtSource"
                             ToolTip="Separate multiple sources with ;  Guest paths are typed manually, e.g. C:\Logs\app.log or /var/log/messages"/>
                </DockPanel>

                <Label Grid.Row="3" Grid.Column="0" x:Name="lblDest" Content="Destination (guest):"/>
                <DockPanel Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="3">
                    <Button DockPanel.Dock="Right" x:Name="btnDestFolder" Content="Folder..."/>
                    <TextBox x:Name="txtDest"
                             ToolTip="Guest folder should end with a separator, e.g. C:\Temp\ or /tmp/"/>
                </DockPanel>

                <StackPanel Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,6,0,0">
                    <CheckBox x:Name="chkForce" Content="Force (create destination folder if it does not exist)"/>
                    <Label Content="Tools wait (s):"/>
                    <TextBox x:Name="txtToolsWait" Text="20" Width="45"
                             ToolTip="Seconds to wait for VMware Tools to respond"/>
                    <Button x:Name="btnCopy" Content="Copy" FontWeight="Bold" MinWidth="100" Margin="16,2,4,2"/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- Log -->
        <GroupBox Grid.Row="3" Header="Log" Margin="0">
            <TextBox x:Name="txtLog" IsReadOnly="True" TextWrapping="Wrap" Margin="0"
                     VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"
                     FontFamily="Consolas" FontSize="11"/>
        </GroupBox>

        <!-- Status bar -->
        <DockPanel Grid.Row="4" Margin="0,6,0,0">
            <TextBlock DockPanel.Dock="Right" x:Name="txtVersion" VerticalAlignment="Center"
                       Margin="10,0,0,0" Foreground="Gray"/>
            <ProgressBar DockPanel.Dock="Right" x:Name="prgBusy" Width="160" Height="14"/>
            <TextBlock x:Name="txtStatus" VerticalAlignment="Center" Text="Starting..."/>
        </DockPanel>
    </Grid>
</Window>
'@
#endregion

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.GetAttribute('Name', $xamlNs)
    if ($name) { $ui[$name] = $window.FindName($name) }
}
$window.Title = "VM Guest File Copy v$script:AppVersion"
$ui.txtVersion.Text = "v$script:AppVersion"

#region Helpers
function Write-Log {
    param([string]$Message)
    $ui.txtLog.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine))
    $ui.txtLog.ScrollToEnd()
}

function Update-UiState {
    $ready = $script:ModuleLoaded -and -not $script:Busy
    $ui.btnConnect.IsEnabled    = $ready
    $ui.btnDisconnect.IsEnabled = $ready -and $script:Connected
    $ui.btnRefresh.IsEnabled    = $ready -and $script:Connected
    $ui.btnCopy.IsEnabled       = $ready -and $script:Connected
    $ui.prgBusy.IsIndeterminate = $script:Busy

    $toGuest = [bool]$ui.rbToGuest.IsChecked
    $ui.btnSrcFile.IsEnabled    = $toGuest
    $ui.btnSrcFolder.IsEnabled  = $toGuest
    $ui.btnDestFolder.IsEnabled = -not $toGuest
    if ($toGuest) {
        $ui.lblSource.Content = 'Source (local):'
        $ui.lblDest.Content   = 'Destination (guest):'
    }
    else {
        $ui.lblSource.Content = 'Source (guest):'
        $ui.lblDest.Content   = 'Destination (local):'
    }
}

function Set-Status {
    param([string]$Text)
    $ui.txtStatus.Text = $Text
}

function Get-ErrorMessage {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) {
        $ex = $ex.InnerException
    }
    if ($ex -is [System.Management.Automation.ActionPreferenceStopException] -and $ex.ErrorRecord) {
        return $ex.ErrorRecord.Exception.Message
    }
    return $ex.Message
}
#endregion

#region Favourites
function Read-Favourites {
    $list = @()
    if (Test-Path -LiteralPath $script:FavFile) {
        try {
            $data = Get-Content -LiteralPath $script:FavFile -Raw | ConvertFrom-Json
            foreach ($item in $data) {
                $list += [pscustomobject]@{
                    Server     = $item.Server
                    IgnoreCert = [bool]$item.IgnoreCert
                }
            }
        }
        catch { Write-Log "Could not read favourites file: $($_.Exception.Message)" }
        # Purge usernames/passwords saved by earlier versions of this tool.
        $legacy = $data | Where-Object { $_.PSObject.Properties['Username'] -or $_.PSObject.Properties['Password'] }
        if (@($legacy).Count) {
            $script:Favourites = @($list | Sort-Object Server)
            try { Write-Favourites; Write-Log 'Removed saved usernames/passwords from favourites file.' }
            catch { Write-Log "Could not update favourites file: $($_.Exception.Message)" }
        }
    }
    $script:Favourites = @($list | Sort-Object Server)
}

function Write-Favourites {
    if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
    }
    ConvertTo-Json -InputObject @($script:Favourites) -Depth 3 |
        Set-Content -LiteralPath $script:FavFile -Encoding UTF8
}

function Update-FavouritesList {
    # Rebuilding the list re-selects the current item; don't let that overwrite the form.
    $script:SuppressFavLoad = $true
    try {
        $current = $ui.cmbServer.Text
        $ui.cmbServer.Items.Clear()
        foreach ($fav in $script:Favourites) { [void]$ui.cmbServer.Items.Add($fav.Server) }
        $ui.cmbServer.Text = $current
    }
    finally { $script:SuppressFavLoad = $false }
}

function Find-Favourite {
    param([string]$Server)
    $script:Favourites | Where-Object { $_.Server -eq $Server } | Select-Object -First 1
}
#endregion

#region Background runspace
# All PowerCLI work runs in one dedicated runspace so the UI stays responsive and
# the vCenter/ESXi session persists between operations.
$script:Runspace = [runspacefactory]::CreateRunspace()
$script:Runspace.Open()
$script:Jobs = New-Object System.Collections.ArrayList

function Start-BgTask {
    param(
        [string]$Description,
        [scriptblock]$Script,
        [hashtable]$Parameters = @{},
        [scriptblock]$OnSuccess,
        [scriptblock]$OnFailure
    )
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Runspace
    # Pass as text so the scriptblock is bound to the background runspace, not this one.
    [void]$ps.AddScript($Script.ToString())
    foreach ($key in $Parameters.Keys) { [void]$ps.AddParameter($key, $Parameters[$key]) }

    $script:Busy = $true
    Set-Status "$Description..."
    Update-UiState

    [void]$script:Jobs.Add([pscustomobject]@{
        PS        = $ps
        Handle    = $ps.BeginInvoke()
        OnSuccess = $OnSuccess
        OnFailure = $OnFailure
    })
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    foreach ($job in @($script:Jobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        [void]$script:Jobs.Remove($job)

        $result = $null
        $failure = $null
        try { $result = $job.PS.EndInvoke($job.Handle) }
        catch { $failure = Get-ErrorMessage $_ }

        foreach ($w in $job.PS.Streams.Warning) { Write-Log "WARNING: $($w.Message)" }
        if (-not $failure) {
            foreach ($e in $job.PS.Streams.Error) { Write-Log "ERROR: $($e.Exception.Message)" }
        }
        $job.PS.Dispose()

        $script:Busy = $false
        Set-Status 'Ready'
        try {
            if ($failure) {
                Write-Log "ERROR: $failure"
                Set-Status 'Last operation failed - see log'
                if ($job.OnFailure) { & $job.OnFailure $failure }
            }
            elseif ($job.OnSuccess) {
                & $job.OnSuccess $result
            }
        }
        catch { Write-Log "ERROR (UI): $($_.Exception.Message)" }
        Update-UiState
    }
})
#endregion

#region Background scripts
$bgLoadModule = {
    param($ModulesDir)
    $ErrorActionPreference = 'Stop'
    if (Test-Path -LiteralPath $ModulesDir) {
        if (($env:PSModulePath -split ';') -notcontains $ModulesDir) {
            $env:PSModulePath = "$ModulesDir;$env:PSModulePath"
        }
    }
    $mod = Get-Module -ListAvailable -Name VMware.VimAutomation.Core |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        throw "PowerCLI (VMware.VimAutomation.Core) not found. Copy it into '$ModulesDir' (see README.md) or install it."
    }
    Import-Module $mod -ErrorAction Stop -WarningAction SilentlyContinue
    try {
        $null = Set-PowerCLIConfiguration -Scope Session -DisplayDeprecationWarnings $false -Confirm:$false
    }
    catch { }
    "PowerCLI $($mod.Version) loaded from $($mod.ModuleBase)"
}

$bgConnect = {
    param($Server, $User, $Password, $IgnoreCert)
    $ErrorActionPreference = 'Stop'
    $action = if ($IgnoreCert) { 'Ignore' } else { 'Fail' }
    $null = Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $action -Confirm:$false
    if ($global:DefaultVIServers) {
        Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    $cred = New-Object System.Management.Automation.PSCredential($User, $Password)
    $vi = Connect-VIServer -Server $Server -Credential $cred -WarningAction SilentlyContinue
    [pscustomobject]@{
        Name        = $vi.Name
        Version     = $vi.Version
        Build       = $vi.Build
        ProductLine = $vi.ProductLine
        User        = $vi.User
    }
}

$bgDisconnect = {
    Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue
}

$bgGetVMs = {
    $ErrorActionPreference = 'Stop'
    Get-View -ViewType VirtualMachine -Property Name, Runtime.PowerState, Runtime.Host,
        Guest.ToolsRunningStatus, Guest.GuestFullName, Config.GuestFullName, Config.Template |
        Where-Object { -not $_.Config.Template } |
        ForEach-Object -Begin {
            $hosts = @{}
            Get-View -ViewType HostSystem -Property Name | ForEach-Object { $hosts[$_.MoRef.Value] = $_.Name }
        } -Process {
            $tools = switch ($_.Guest.ToolsRunningStatus) {
                'guestToolsRunning'          { 'Running' }
                'guestToolsNotRunning'       { 'Not running' }
                'guestToolsExecutingScripts' { 'Starting' }
                default                      { [string]$_.Guest.ToolsRunningStatus }
            }
            $os = $_.Guest.GuestFullName
            if (-not $os) { $os = $_.Config.GuestFullName }
            [pscustomobject]@{
                Name       = $_.Name
                Id         = 'VirtualMachine-' + $_.MoRef.Value
                PowerState = ([string]$_.Runtime.PowerState) -replace '^powered', 'Powered '
                Tools      = $tools
                GuestOS    = $os
                VMHost     = $hosts[$_.Runtime.Host.Value]
            }
        } | Sort-Object Name
}

$bgCopy = {
    param($VMId, $Direction, [string[]]$Source, $Destination, $GuestUser, $GuestPassword, $Force, $ToolsWaitSecs)
    $ErrorActionPreference = 'Stop'
    $vm = Get-VM -Id $VMId
    $params = @{
        VM              = $vm
        Source          = $Source
        Destination     = $Destination
        GuestCredential = New-Object System.Management.Automation.PSCredential($GuestUser, $GuestPassword)
        ToolsWaitSecs   = $ToolsWaitSecs
        Force           = [bool]$Force
    }
    if ($Direction -eq 'LocalToGuest') { $params.LocalToGuest = $true } else { $params.GuestToLocal = $true }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Copy-VMGuestFile @params
    'Copy completed in {0:N1}s' -f $sw.Elapsed.TotalSeconds
}
#endregion

#region Event handlers
$ui.cmbServer.Add_SelectionChanged({
    if ($script:SuppressFavLoad) { return }
    $name = $ui.cmbServer.SelectedItem
    if (-not $name) { return }
    $fav = Find-Favourite $name
    if (-not $fav) { return }
    $ui.chkIgnoreCert.IsChecked = [bool]$fav.IgnoreCert
    $ui.pwdPassword.Clear()
    if ($ui.txtUser.Text) { [void]$ui.pwdPassword.Focus() } else { [void]$ui.txtUser.Focus() }
})

$ui.btnAddFav.Add_Click({
    $server = $ui.cmbServer.Text.Trim()
    if (-not $server) { Write-Log 'Enter a server name before saving a favourite.'; return }
    $entry = [pscustomobject]@{
        Server     = $server
        IgnoreCert = [bool]$ui.chkIgnoreCert.IsChecked
    }
    $script:Favourites = @(@($script:Favourites | Where-Object { $_.Server -ne $server }) + $entry | Sort-Object Server)
    try {
        Write-Favourites
        Update-FavouritesList
        Write-Log "Saved favourite '$server'."
    }
    catch { Write-Log "ERROR: could not save favourites: $($_.Exception.Message)" }
})

$ui.btnRemoveFav.Add_Click({
    $server = $ui.cmbServer.Text.Trim()
    if (-not (Find-Favourite $server)) { Write-Log "'$server' is not in favourites."; return }
    $answer = [System.Windows.MessageBox]::Show("Remove '$server' from favourites?", 'Remove favourite', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $script:Favourites = @($script:Favourites | Where-Object { $_.Server -ne $server })
    try {
        Write-Favourites
        $ui.cmbServer.Text = ''
        Update-FavouritesList
        Write-Log "Removed favourite '$server'."
    }
    catch { Write-Log "ERROR: could not save favourites: $($_.Exception.Message)" }
})

$ui.btnConnect.Add_Click({
    $server = $ui.cmbServer.Text.Trim()
    $user   = $ui.txtUser.Text.Trim()
    if (-not $server) { Write-Log 'Enter a server to connect to.'; return }
    if (-not $user)   { Write-Log 'Enter a username.'; return }

    $script:Connected = $false
    $script:AllVMs = @()
    $ui.dgVMs.ItemsSource = $null
    $ui.txtConnStatus.Text = 'Not connected'
    $ui.txtConnStatus.Foreground = 'Gray'
    Write-Log "Connecting to $server as $user (ignore certificate errors: $([bool]$ui.chkIgnoreCert.IsChecked))..."

    Start-BgTask -Description "Connecting to $server" -Script $bgConnect -Parameters @{
        Server     = $server
        User       = $user
        Password   = $ui.pwdPassword.SecurePassword
        IgnoreCert = [bool]$ui.chkIgnoreCert.IsChecked
    } -OnSuccess {
        param($result)
        $vi = $result | Select-Object -First 1
        $script:Connected = $true
        # PowerCLI keeps its own session, so the password is no longer needed.
        $ui.pwdPassword.Clear()
        $ui.txtConnStatus.Text = "Connected to $($vi.Name) - $($vi.ProductLine) $($vi.Version) build $($vi.Build) as $($vi.User)"
        $ui.txtConnStatus.Foreground = 'DarkGreen'
        Write-Log "Connected to $($vi.Name) ($($vi.ProductLine) $($vi.Version))."
        Invoke-RefreshVMs
    } -OnFailure {
        param($msg)
        if ($msg -match 'certificate|SSL|TLS|trust relationship') {
            Write-Log "Hint: tick 'Ignore certificate errors' if the server uses a self-signed certificate."
        }
    }
})

$ui.btnDisconnect.Add_Click({
    Start-BgTask -Description 'Disconnecting' -Script $bgDisconnect -OnSuccess {
        $script:Connected = $false
        $script:AllVMs = @()
        $ui.dgVMs.ItemsSource = $null
        $ui.txtConnStatus.Text = 'Not connected'
        $ui.txtConnStatus.Foreground = 'Gray'
        Write-Log 'Disconnected.'
    }
})

function Update-VMGrid {
    $filter = $ui.txtFilter.Text.Trim()
    if ($filter) {
        $items = @($script:AllVMs | Where-Object {
            $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    else {
        $items = @($script:AllVMs)
    }

    # Re-select the user's chosen VM whenever it is in the (filtered) list, even if
    # an earlier filter hid it for a while.
    $script:UpdatingGrid = $true
    try {
        $ui.dgVMs.ItemsSource = $items
        if ($script:SelectedVMId) {
            $match = $items | Where-Object { $_.Id -eq $script:SelectedVMId } | Select-Object -First 1
            if ($match) {
                $ui.dgVMs.SelectedItem = $match
                $ui.dgVMs.ScrollIntoView($match)
            }
        }
    }
    finally { $script:UpdatingGrid = $false }
}

$ui.dgVMs.Add_SelectionChanged({
    # Only remember selections the user makes, not ones caused by re-filtering.
    if ($script:UpdatingGrid) { return }
    $script:SelectedVMId = if ($ui.dgVMs.SelectedItem) { $ui.dgVMs.SelectedItem.Id } else { $null }
})

function Invoke-RefreshVMs {
    Start-BgTask -Description 'Retrieving VM list' -Script $bgGetVMs -OnSuccess {
        param($result)
        $script:AllVMs = @($result)
        Update-VMGrid
        Write-Log "Found $($script:AllVMs.Count) VM(s)."
    }
}

$ui.btnRefresh.Add_Click({ Invoke-RefreshVMs })
$ui.txtFilter.Add_TextChanged({ Update-VMGrid })

$ui.rbToGuest.Add_Checked({ Update-UiState })
$ui.rbFromGuest.Add_Checked({ Update-UiState })

$ui.btnSrcFile.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Select file(s) to copy to the guest'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog($window)) { $ui.txtSource.Text = $dlg.FileNames -join ';' }
})

$ui.btnSrcFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select a folder to copy to the guest'
    if ($dlg.ShowDialog() -eq 'OK') { $ui.txtSource.Text = $dlg.SelectedPath }
})

$ui.btnDestFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the local destination folder'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { $ui.txtDest.Text = $dlg.SelectedPath }
})

$ui.btnCopy.Add_Click({
    $vm = $ui.dgVMs.SelectedItem
    if (-not $vm) { Write-Log 'Select a VM first.'; return }
    $guestUser = $ui.txtGuestUser.Text.Trim()
    if (-not $guestUser) { Write-Log 'Enter the guest OS username.'; return }
    $sources = @($ui.txtSource.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $sources) { Write-Log 'Enter a source path.'; return }
    $dest = $ui.txtDest.Text.Trim()
    if (-not $dest) { Write-Log 'Enter a destination path.'; return }
    $wait = 0
    if (-not [int]::TryParse($ui.txtToolsWait.Text, [ref]$wait) -or $wait -lt 0) {
        Write-Log 'Tools wait must be a whole number of seconds.'; return
    }

    $direction = if ($ui.rbToGuest.IsChecked) { 'LocalToGuest' } else { 'GuestToLocal' }
    if ($direction -eq 'LocalToGuest') {
        $missing = @($sources | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing) { Write-Log "Local source not found: $($missing -join ', ')"; return }
    }
    elseif (-not (Test-Path -LiteralPath $dest) -and -not $ui.chkForce.IsChecked) {
        Write-Log "Local destination '$dest' does not exist. Tick Force to create it."
        return
    }
    if ($vm.PowerState -ne 'Powered On') { Write-Log "Warning: $($vm.Name) is $($vm.PowerState)." }
    if ($vm.Tools -ne 'Running')         { Write-Log "Warning: VMware Tools on $($vm.Name) reports '$($vm.Tools)'." }

    $arrow = if ($direction -eq 'LocalToGuest') { 'local -> guest' } else { 'guest -> local' }
    Write-Log "Copying ($arrow) on $($vm.Name): $($sources -join ', ') => $dest (Force: $([bool]$ui.chkForce.IsChecked))"

    Start-BgTask -Description "Copying files ($arrow) on $($vm.Name)" -Script $bgCopy -Parameters @{
        VMId          = $vm.Id
        Direction     = $direction
        Source        = [string[]]$sources
        Destination   = $dest
        GuestUser     = $guestUser
        GuestPassword = $ui.pwdGuestPassword.SecurePassword
        Force         = [bool]$ui.chkForce.IsChecked
        ToolsWaitSecs = $wait
    } -OnSuccess {
        param($result)
        foreach ($line in $result) { Write-Log "$line" }
        Set-Status 'Copy completed'
    }
})

$window.Add_Loaded({
    Read-Favourites
    Update-FavouritesList
    Update-UiState
    $timer.Start()
    Write-Log "VM Guest File Copy v$script:AppVersion"
    Write-Log 'Loading PowerCLI (this can take a little while)...'
    Start-BgTask -Description 'Loading PowerCLI' -Script $bgLoadModule -Parameters @{ ModulesDir = $script:ModulesDir } -OnSuccess {
        param($result)
        $script:ModuleLoaded = $true
        foreach ($line in $result) { Write-Log "$line" }
    }
})

$window.Add_Closing({
    $timer.Stop()
    if ($script:Connected -and -not $script:Busy) {
        try {
            $ps = [powershell]::Create()
            $ps.Runspace = $script:Runspace
            [void]$ps.AddScript($bgDisconnect.ToString()).Invoke()
            $ps.Dispose()
        }
        catch { }
    }
    try { $script:Runspace.Dispose() } catch { }
})
#endregion

[void]$window.ShowDialog()
