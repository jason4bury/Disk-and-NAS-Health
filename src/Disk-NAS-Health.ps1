<#
.SYNOPSIS
    Disk and NAS Health - free space, drive health and the biggest folders, for this PC and your NAS.

.DESCRIPTION
    PowerShell/WPF tool for checking free space, drive health and the biggest folders on a PC and a Synology NAS.

    Read only: it never writes to, formats, tests or changes any disk, here or on the NAS.
      - This PC: drives from Win32_LogicalDisk, physical disks from Get-PhysicalDisk, and (run as
        administrator) temperature, wear, power-on hours and error counts from
        Get-StorageReliabilityCounter.
      - NAS: one SSH connection (Windows' own ssh.exe, key login) runs a read-only shell script that
        prints df, /proc/mdstat, the disks in /sys/block and, where allowed, smartctl -H -i -A.
      - Biggest folders: this PC's folders are measured by a small C# scanner that only lists them;
        the NAS uses du over SSH.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Disk and NAS Health v<version>\" release folders, their zips and
                                        "Disk and NAS Health.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Disk and NAS Health

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Disk and NAS Health v<version>".
$script:AppName     = 'Disk and NAS Health'
$script:AppVersion  = '1.00'
$script:Description = 'PowerShell/WPF tool for checking free space, drive health and the biggest folders on a PC and a Synology NAS'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Disk-NAS-Health'
$script:IsPrivate   = $false   # private tools keep their data in <project>\Data, inside the vault
$script:AppId       = 'jason4bury.Disk-NAS-Health'   # taskbar ID; the shortcut made by New-DiskNASHealthShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Disk and NAS Health v<version>\
#  (or wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Never inside Source\ (keeps personal data out of git)
       or a release folder (each version has its own, so data kept there would be left behind). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
#  C#: the folder scanner (fast, read only) and the dark title bar
# ---------------------------------------------------------------------------
if (-not ('DiskNasHealth.Scanner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace DiskNasHealth {
    // Shared with the window while a scan runs: progress, and Cancel to stop it.
    public class ScanState {
        public volatile bool Cancel;
        public long Files;
        public long Bytes;
        public long Folders;
        public long Skipped;
        public volatile string Current = "";
    }

    public class DirSize {
        public string Path;
        public string Name;
        public int Depth;
        public long Bytes;
        public long Files;
        public long Folders;
        public long OwnBytes;
        public long OwnFiles;
    }

    public class FileEntry {
        public string Path;
        public string Name;
        public string Folder;
        public long Bytes;
    }

    public class ScanResult {
        public string Root;
        public int KeepDepth;
        public bool Cancelled;
        public Dictionary<string, DirSize> Map = new Dictionary<string, DirSize>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, List<DirSize>> Children = new Dictionary<string, List<DirSize>>(StringComparer.OrdinalIgnoreCase);
        public List<FileEntry> TopFiles = new List<FileEntry>();

        public DirSize Get(string path) {
            DirSize d;
            return Map.TryGetValue(path, out d) ? d : null;
        }
        // True when this folder's subfolders were kept, so it can be shown without scanning again.
        public bool Knows(string path) {
            DirSize d;
            return Map.TryGetValue(path, out d) && d.Depth < KeepDepth;
        }
        public List<DirSize> ChildrenOf(string path) {
            List<DirSize> l;
            return Children.TryGetValue(path, out l) ? l : new List<DirSize>();
        }
    }

    public static class Scanner {
        const int TopCount = 500;

        public static string Normalize(string path) {
            string p = System.IO.Path.GetFullPath(path);
            if (p.Length > 3) p = p.TrimEnd('\\');
            return p;
        }

        // Lists every folder under root and adds up file sizes. It only reads folder listings:
        // no file is opened. Junctions and symbolic links are skipped (no loops, nothing counted twice),
        // and online-only cloud files (OneDrive) count as 0 bytes, because they use no disk space.
        public static ScanResult Scan(string root, int keepDepth, ScanState st) {
            ScanResult r = new ScanResult();
            r.Root = Normalize(root);
            r.KeepDepth = keepDepth;
            long minTop = 0;
            Walk(new DirectoryInfo(r.Root), 0, r, st, ref minTop);
            Trim(r);
            r.Cancelled = st.Cancel;
            return r;
        }

        static void Trim(ScanResult r) {
            r.TopFiles.Sort(delegate (FileEntry a, FileEntry b) { return b.Bytes.CompareTo(a.Bytes); });
            if (r.TopFiles.Count > TopCount) r.TopFiles.RemoveRange(TopCount, r.TopFiles.Count - TopCount);
        }

        static DirSize Walk(DirectoryInfo dir, int depth, ScanResult r, ScanState st, ref long minTop) {
            DirSize me = new DirSize();
            me.Depth = depth;
            try {
                me.Path = dir.FullName;
                me.Name = dir.Name;
                if (depth <= 3) st.Current = me.Path;
                foreach (FileSystemInfo fsi in dir.EnumerateFileSystemInfos()) {
                    if (st.Cancel) break;
                    try {
                        FileAttributes attr = fsi.Attributes;
                        if ((attr & FileAttributes.Directory) != 0) {
                            if ((attr & FileAttributes.ReparsePoint) != 0) continue;
                            DirSize child = Walk((DirectoryInfo)fsi, depth + 1, r, st, ref minTop);
                            me.Bytes += child.Bytes;
                            me.Files += child.Files;
                            me.Folders += child.Folders + 1;
                            Interlocked.Increment(ref st.Folders);
                        } else {
                            long len = ((FileInfo)fsi).Length;
                            // Offline, RecallOnOpen, RecallOnDataAccess: a placeholder, not on this disk.
                            if (((int)attr & (0x1000 | 0x40000 | 0x400000)) != 0) len = 0;
                            me.Bytes += len; me.Files++;
                            me.OwnBytes += len; me.OwnFiles++;
                            Interlocked.Increment(ref st.Files);
                            Interlocked.Add(ref st.Bytes, len);
                            if (len > 0 && (len > minTop || r.TopFiles.Count < TopCount)) {
                                FileEntry fe = new FileEntry();
                                fe.Path = fsi.FullName; fe.Name = fsi.Name; fe.Folder = me.Path; fe.Bytes = len;
                                r.TopFiles.Add(fe);
                                if (r.TopFiles.Count >= TopCount * 2) {
                                    Trim(r);
                                    minTop = r.TopFiles[r.TopFiles.Count - 1].Bytes;
                                }
                            }
                        }
                    } catch (Exception) { Interlocked.Increment(ref st.Skipped); }
                }
            } catch (Exception) {
                Interlocked.Increment(ref st.Skipped);   // no permission (System Volume Information...) or path too long
            }
            if (me.Path != null && depth <= r.KeepDepth) {
                r.Map[me.Path] = me;
                if (depth >= 1) {
                    string parent = System.IO.Path.GetDirectoryName(me.Path);
                    if (parent != null) {
                        List<DirSize> list;
                        if (!r.Children.TryGetValue(parent, out list)) { list = new List<DirSize>(); r.Children[parent] = list; }
                        list.Add(me);
                    }
                }
            }
            return me;
        }
    }

    public static class Native {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // Dark or light title bar (Windows 10 2004 and later use 20, older builds 19).
        public static void SetDarkTitleBar(IntPtr hwnd, bool dark) {
            int v = dark ? 1 : 0;
            if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref v, 4);
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetBytes {
    <# An asset by file name, from assets\ (beside the script in a release, Source\assets\ in the repo). #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllBytes($path) }
    return $null
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $bytes = Get-AssetBytes $Name
    if (-not $bytes) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, $bytes)
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}

function Get-WindowIcon {
    <# The .ico with all its sizes (BitmapImage would keep only the first, 16 px, frame, so the
       taskbar would show a tiny icon). WPF picks the best size for the title bar and the taskbar. #>
    $bytes = Get-AssetBytes 'Disk-NAS-Health.ico'
    if (-not $bytes) { return $null }
    try {
        $dec = [Windows.Media.Imaging.BitmapDecoder]::Create((New-Object IO.MemoryStream (, $bytes)), 'None', 'OnLoad')
        $best = $dec.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
        return $best
    } catch { Write-AppLog "Icon not loaded: $($_.Exception.Message)"; return (Get-AssetImage 'Disk-NAS-Health.png') }
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml)
    $Xaml = $Xaml.Replace('<!--STYLES-->', $script:StyleXaml)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    $w = [Windows.Markup.XamlReader]::Load($reader)
    Set-ThemeBrush $w
    return $w
}

function Format-Size([double]$Bytes) {
    <# Binary units, the way Explorer and DSM show them. #>
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Format-Hours([double]$Hours) {
    if ($Hours -ge 24 * 365) { return ('{0:N0} hours ({1:N1} years)' -f $Hours, ($Hours / (24 * 365.25))) }
    if ($Hours -ge 48) { return ('{0:N0} hours ({1:N0} days)' -f $Hours, ($Hours / 24)) }
    return ('{0:N0} hours' -f $Hours)
}

function Format-Uptime([double]$Seconds) {
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalDays -ge 1) { return ('{0} days {1} h' -f [int][Math]::Floor($t.TotalDays), $t.Hours) }
    return ('{0} h {1} min' -f $t.Hours, $t.Minutes)
}

function ConvertTo-ShQuote([string]$Text) {
    <# One word for the remote (POSIX) shell. #>
    if ($Text -match '^[A-Za-z0-9_./:=@%+,-]+$') { return $Text }
    return "'" + $Text.Replace("'", "'\''") + "'"
}

function Join-CommandLine([string[]]$Arguments) {
    <# A Windows command line from separate arguments, quoted the way programs read them back. #>
    return (($Arguments | ForEach-Object {
                if ($_ -eq '') { '""' }
                elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
                else { $_ }
            }) -join ' ')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$script:IsAdmin = Test-IsAdmin

# ---------------------------------------------------------------------------
#  Settings (%APPDATA%\Disk and NAS Health\settings.json)
# ---------------------------------------------------------------------------
function Get-AppSetting {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try { return (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{}
}

function Save-AppSetting {
    try { $script:Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

function Import-Machine {
    <# The first time, the NAS list is copied from Homelab or Docker Container Manager, which keep
       the same machines (Name, Login as user@address, Port). Nothing is hard-coded here. #>
    foreach ($app in 'Homelab', 'Docker Container Manager') {
        $path = Join-Path (Join-Path ([Environment]::GetFolderPath('ApplicationData')) $app) 'settings.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $s = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $list = @(foreach ($m in @($s.Machines)) {
                    if ($m -and $m.Name -and $m.Login) { [pscustomobject]@{ Name = [string]$m.Name; Login = [string]$m.Login; Port = [string]$m.Port } }
                })
            if ($list.Count) { Write-AppLog "Machines copied from $app's settings."; return $list }
        } catch { Write-AppLog "Couldn't read $app's machines: $($_.Exception.Message)" }
    }
    return @()
}

$script:Settings = Get-AppSetting
$defaults = [ordered]@{
    WarnFreePercent = 15; CritFreePercent = 5; HddTempWarn = 50; SsdTempWarn = 70
    RefreshMinutes = 15; Theme = 'Auto'; FolderPaths = [pscustomobject]@{}; Window = $null
}
foreach ($k in $defaults.Keys) {
    if ($null -eq $script:Settings.PSObject.Properties[$k]) { $script:Settings | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
}
if ($null -eq $script:Settings.PSObject.Properties['Machines']) {
    $script:Settings | Add-Member -NotePropertyName Machines -NotePropertyValue @(Import-Machine)
    Save-AppSetting
}
$script:Settings.Machines = @($script:Settings.Machines | Where-Object { $_ -and $_.Name -and $_.Login })

function Get-SettingNumber([string]$Name, [double]$Default) {
    $v = 0.0
    if ([double]::TryParse([string]$script:Settings.$Name, [ref]$v) -and $v -ge 0) { return $v }
    return $Default
}

# ---------------------------------------------------------------------------
#  Theme: follows Windows (Auto), or Light / Dark from Settings
# ---------------------------------------------------------------------------
$script:Palettes = @{
    Light = @{ Bg = '#F3F4F6'; Header = '#FFFFFF'; Card = '#FFFFFF'; Input = '#FFFFFF'; Fg = '#1F2937'; Muted = '#6B7280'; Border = '#E2E5E9'
               Accent = '#2563EB'; Good = '#15803D'; Warn = '#B45309'; Bad = '#DC2626'; Unknown = '#8A9099'; BarBg = '#E5E7EB'; BtnBg = '#F9FAFB'; Banner = '#FEF3C7' }
    Dark  = @{ Bg = '#1C1D20'; Header = '#25272B'; Card = '#2B2D31'; Input = '#1F2023'; Fg = '#E6E7EA'; Muted = '#A0A4AB'; Border = '#3C3F45'
               Accent = '#5B9BFF'; Good = '#34C46A'; Warn = '#F2A93B'; Bad = '#FF6B6B'; Unknown = '#8A9099'; BarBg = '#3C3F45'; BtnBg = '#33363B'; Banner = '#3D3420' }
}

function Test-DarkTheme {
    switch ([string]$script:Settings.Theme) {
        'Dark'  { return $true }
        'Light' { return $false }
    }
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 0)
    } catch { return $false }
}

function Set-ThemeBrush($Element) {
    $p = if (Test-DarkTheme) { $script:Palettes.Dark } else { $script:Palettes.Light }
    foreach ($k in $p.Keys) {
        # ::new, not New-Object: a PSObject-wrapped brush in Resources isn't seen as a Brush by WPF.
        $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($p[$k]))
        $b.Freeze()
        $Element.Resources[$k] = $b
    }
    if ($Element -is [Windows.Window]) {
        $dark = Test-DarkTheme
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $Element).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            try { [DiskNasHealth.Native]::SetDarkTitleBar($hwnd, $dark) } catch { Write-Verbose 'No dark title bar.' }
            return
        }
        $Element.Add_SourceInitialized({
                param($s, $e)
                try { [DiskNasHealth.Native]::SetDarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $s).Handle, $dark) }
                catch { Write-Verbose 'No dark title bar.' }
            }.GetNewClosure())
    }
}

# Styles shared by every window (put into each window's Resources).
$script:StyleXaml = @'
<Style TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="Padding" Value="12,5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="Button">
                <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="White"/>
</Style>
<Style TargetType="TextBox">
    <Setter Property="Background" Value="{DynamicResource Input}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource Fg}"/>
    <Setter Property="Padding" Value="4,3"/>
</Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource Fg}"/></Style>
<Style TargetType="TabControl">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0"/>
</Style>
<Style TargetType="TabItem">
    <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="TabItem">
                <Border x:Name="B" Padding="14,7" Margin="0,0,4,0" BorderThickness="0,0,0,2" BorderBrush="Transparent" Background="Transparent" Cursor="Hand">
                    <ContentPresenter ContentSource="Header"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                        <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
                    </Trigger>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{DynamicResource Fg}"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style TargetType="ListView">
    <Setter Property="Background" Value="{DynamicResource Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
</Style>
<Style TargetType="ListBox">
    <Setter Property="Background" Value="{DynamicResource Input}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
</Style>
<Style TargetType="GridViewColumnHeader">
    <Setter Property="Background" Value="{DynamicResource Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="HorizontalContentAlignment" Value="Left"/>
    <Setter Property="Padding" Value="6,4"/>
</Style>
<Style TargetType="ComboBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="Background" Value="{DynamicResource Input}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="MinHeight" Value="26"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="ComboBox">
                <Grid>
                    <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                        <ToggleButton.Template>
                            <ControlTemplate TargetType="ToggleButton">
                                <Border x:Name="B" Background="{DynamicResource Input}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="5">
                                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0" Data="M0,0 L4,4 L8,0" Stroke="{DynamicResource Muted}" StrokeThickness="1.5"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </ToggleButton.Template>
                    </ToggleButton>
                    <ContentPresenter IsHitTestVisible="False" Margin="8,3,26,3" HorizontalAlignment="Left" VerticalAlignment="Center"
                                      Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                      ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
                    <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                        <Border Background="{DynamicResource Card}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="5" Margin="0,2,0,0" Padding="0,3"
                                MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                            <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                        </Border>
                    </Popup>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="ComboBoxItem">
                <Border x:Name="B" Background="Transparent" Padding="8,4" Margin="3,0">
                    <ContentPresenter VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource BarBg}"/></Trigger>
                    <Trigger Property="IsHighlighted" Value="True">
                        <Setter TargetName="B" Property="Background" Value="{DynamicResource Accent}"/>
                        <Setter Property="Foreground" Value="White"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style TargetType="ProgressBar">
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
    <Setter Property="Background" Value="{DynamicResource BarBg}"/>
    <Setter Property="BorderThickness" Value="0"/>
</Style>
'@

# ---------------------------------------------------------------------------
#  Background work: runspaces, so the window never waits for disks or SSH
# ---------------------------------------------------------------------------
$script:Pool = [RunspaceFactory]::CreateRunspacePool(1, 4)
$script:Pool.Open()
$script:Tasks = New-Object System.Collections.ArrayList

function Start-Background([scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone, $State) {
    <# Runs Work on a pool thread; Update-Background calls OnDone(output, error, State) on the UI thread. #>
    try {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($Work.ToString())
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        [void]$script:Tasks.Add(@{ PS = $ps; Handle = $handle; OnDone = $OnDone; State = $State })
    } catch {
        Write-AppLog "Couldn't start background work: $($_.Exception.Message)"
        & $OnDone @() $_.Exception.Message $State
    }
}

function Update-Background {
    foreach ($t in @($script:Tasks)) {
        if (-not $t.Handle.IsCompleted) { continue }
        $script:Tasks.Remove($t)
        $out = @(); $err = ''
        try { $out = @($t.PS.EndInvoke($t.Handle)) } catch { $err = $_.Exception.Message }
        if (-not $err -and $t.PS.Streams.Error.Count) { $err = [string]$t.PS.Streams.Error[0] }
        $t.PS.Dispose()
        try { & $t.OnDone $out $err $t.State }
        catch { Show-Problem "Something went wrong: $($_.Exception.Message)" }
    }
}

# This PC: drives, physical disks and (as administrator) their reliability counters.
$script:PcWork = {
    $r = [ordered]@{ Volumes = @(); Disks = @(); IsAdmin = $false; Errors = @(); Time = [DateTime]::Now }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $r.IsAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $letterToDisk = @{}
    try {
        foreach ($p in @(Get-Partition -ErrorAction Stop)) {
            if ([int][char]$p.DriveLetter -gt 0) { $letterToDisk["$($p.DriveLetter):"] = [string]$p.DiskNumber }
        }
    } catch { $r.Errors += "Partitions: $($_.Exception.Message)" }

    try {
        foreach ($v in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 2 OR DriveType = 3' -ErrorAction Stop)) {
            if (-not $v.Size) { continue }   # a card reader with no card in it
            $r.Volumes += [pscustomobject]@{
                Letter = [string]$v.DeviceID; Label = [string]$v.VolumeName; FileSystem = [string]$v.FileSystem
                Size = [double]$v.Size; Free = [double]$v.FreeSpace; Removable = ($v.DriveType -eq 2); DiskNumber = $letterToDisk[[string]$v.DeviceID]
            }
        }
    } catch { $r.Errors += "Drives: $($_.Exception.Message)" }

    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })) {
            $o = [ordered]@{
                Number = [string]$d.DeviceId; Model = ([string]$d.FriendlyName).Trim(); Media = [string]$d.MediaType; Bus = [string]$d.BusType
                Size = [double]$d.Size; Health = [string]$d.HealthStatus; Operational = (@($d.OperationalStatus) -join ', ')
                Serial = ([string]$d.SerialNumber).Trim(); Spindle = $d.SpindleSpeed
                Temperature = $null; TemperatureMax = $null; Wear = $null; PowerOnHours = $null; ReadErrors = $null; WriteErrors = $null; Counters = 'admin'
            }
            if ($r.IsAdmin) {
                try {
                    $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($c) {
                        $o.Counters = 'ok'
                        $o.Temperature = $c.Temperature; $o.TemperatureMax = $c.TemperatureMax; $o.Wear = $c.Wear
                        $o.PowerOnHours = $c.PowerOnHours; $o.ReadErrors = $c.ReadErrorsUncorrected; $o.WriteErrors = $c.WriteErrorsUncorrected
                    } else { $o.Counters = 'none' }
                } catch { $o.Counters = 'none' }
            }
            $r.Disks += [pscustomobject]$o
        }
    } catch { $r.Errors += "Physical disks: $($_.Exception.Message)" }
    [pscustomobject]$r
}

# Runs a program (ssh.exe) with InputText on its stdin, and returns ExitCode, Output, Error.
# Control (a synchronized hashtable) holds its process id and Cancel, so Stop can end it.
$script:ProcessWork = {
    param([string]$Exe, [string]$ArgumentLine, [string]$InputText, [int]$TimeoutSeconds, $Control)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgumentLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $env:USERPROFILE
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    $why = ''
    try {
        [void]$p.Start()
        if ($Control) { $Control.Pid = $p.Id }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Write(($InputText -replace "`r`n", "`n"))
        $p.StandardInput.Close()
        $deadline = [DateTime]::Now.AddSeconds($TimeoutSeconds)
        while (-not $p.WaitForExit(250)) {
            if ($Control -and $Control.Cancel) { $why = 'Stopped.'; break }
            if ([DateTime]::Now -gt $deadline) { $why = "Timed out after $TimeoutSeconds seconds."; break }
        }
        if ($why) {
            try {
                $tk = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList @('/T', '/F', '/PID', $p.Id) -WindowStyle Hidden -PassThru -Wait
                $tk.Dispose()
            } catch { Write-Verbose 'taskkill failed.' }
            try { if (-not $p.HasExited) { $p.Kill() } } catch { Write-Verbose 'Already ended.' }
            [void]$p.WaitForExit(5000)
        } else { $p.WaitForExit() }
        [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 5000)
        $out = if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $outTask.Result } else { '' }
        $err = if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $errTask.Result } else { '' }
        if ($why) { $err = ("$err`n$why").Trim() }
        [pscustomobject]@{ ExitCode = $(if ($why) { -1 } else { $p.ExitCode }); Output = $out; Error = $err; Stopped = [bool]$why }
    } finally { $p.Dispose() }
}

# ---------------------------------------------------------------------------
#  NAS over SSH (read only)
# ---------------------------------------------------------------------------
function Find-Ssh {
    foreach ($dir in @((Join-Path $env:SystemRoot 'Sysnative\OpenSSH'), (Join-Path $env:SystemRoot 'System32\OpenSSH'))) {
        $p = Join-Path $dir 'ssh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-SshArguments($Machine) {
    # BatchMode: key login only, never a password prompt. The script itself is sent on stdin to sh -s.
    $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ServerAliveInterval=20')
    if ([string]$Machine.Port) { $a += @('-p', [string]$Machine.Port) }
    return $a + @([string]$Machine.Login, 'sh', '-s')
}

function Start-Ssh($Machine, [string]$ShellScript, [int]$TimeoutSeconds, [scriptblock]$OnDone, $Context, $Control) {
    <# Runs ShellScript on the machine (sh -s, over ssh). OnDone gets the result (ExitCode, Output, Error), then Context. #>
    $exe = Find-Ssh
    if (-not $exe) {
        & $OnDone ([pscustomobject]@{ ExitCode = -1; Output = ''; Error = "ssh.exe wasn't found. Turn on the OpenSSH Client in Windows Settings > System > Optional features." }) $Context
        return
    }
    Start-Background -Work $script:ProcessWork -Arguments @($exe, (Join-CommandLine (Get-SshArguments $Machine)), $ShellScript, $TimeoutSeconds, $Control) `
        -State @{ Callback = $OnDone; Context = $Context } -OnDone {
        param($out, $err, $state)
        $res = if ($out.Count) { $out[0] } else { [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $err; Stopped = $false } }
        & $state.Callback $res $state.Context
    }
}

function Get-SshProblem($Result) {
    <# A short reason when ssh itself failed (not the script). #>
    $e = ([string]$Result.Error).Trim()
    if ($Result.ExitCode -eq 255 -or $e -match 'ssh: |Connection refused|Connection timed out|Could not resolve hostname|Permission denied \(|Host key verification failed|No route to host') {
        $line = @($e -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $msg = if ($line.Count) { $line[0] } else { "ssh stopped with code $($Result.ExitCode)." }
        if ($msg -match 'Permission denied') { $msg += ' (The SSH key isn''t accepted: Disk and NAS Health only uses key login.)' }
        return $msg
    }
    if ($Result.Stopped) { return $e }
    return ''
}

# One read-only report: who it is, free space, RAID, disks and SMART. Each part is marked ##NAME.
$script:NasReportScript = @'
PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin:/usr/syno/sbin"
export LC_ALL=C
echo '##HOST'; hostname 2>/dev/null
echo '##VERSION'; cat /etc.defaults/VERSION 2>/dev/null
echo '##KERNEL'; uname -sr 2>/dev/null
echo '##UPTIME'; cat /proc/uptime 2>/dev/null
echo '##LOAD'; cat /proc/loadavg 2>/dev/null
echo '##MEM'; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
echo '##THERMAL'
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null
for h in /sys/class/hwmon/hwmon*; do
  case "$(cat "$h/name" 2>/dev/null)" in coretemp|k10temp|cpu_thermal|x86_pkg_temp) cat "$h"/temp*_input 2>/dev/null ;; esac
done
echo '##DF'; df -kP 2>/dev/null
echo '##MOUNTS'; grep ' /volume' /proc/mounts 2>/dev/null
echo '##MDSTAT'; cat /proc/mdstat 2>/dev/null
echo '##DISKS'
for d in /sys/block/*; do
  n=${d##*/}
  case "$n" in sata*|sd*|nvme*|hd*) ;; *) continue ;; esac
  echo "DISK|$n|$(cat "$d/size" 2>/dev/null)|$(cat "$d/device/model" 2>/dev/null | tr -s ' ')|$(cat "$d/queue/rotational" 2>/dev/null)|$(cat "$d/removable" 2>/dev/null)"
done
SC=$(command -v smartctl 2>/dev/null)
smart() { if [ "$(id -u)" = 0 ]; then "$SC" "$@"; else sudo -n "$SC" "$@"; fi; }
for d in /sys/block/*; do
  n=${d##*/}
  case "$n" in sata*|sd*|nvme*|hd*) ;; *) continue ;; esac
  echo "##SMART|$n"
  if [ -z "$SC" ]; then echo 'SMART-NO-SMARTCTL'; continue; fi
  out=$(smart -H -i -A "/dev/$n" 2>&1)
  case "$out" in *"specify device type"*|*"Unknown USB bridge"*) out=$(smart -d sat -H -i -A "/dev/$n" 2>&1) ;; esac
  printf '%s\n' "$out"
done
echo '##END'
'@

function Get-FirstNumber([string]$Text) {
    if ($Text -match '(\d[\d,]*)') { return [double]($Matches[1] -replace ',', '') }
    return $null
}

function ConvertFrom-SmartText([string[]]$Lines) {
    <# smartctl -H -i -A output -> Status (PASSED, FAILED, NeedsRoot, None, Unknown) and the numbers that matter. #>
    $s = [ordered]@{ Status = 'Unknown'; Model = ''; Serial = ''; Temperature = $null; PowerOnHours = $null; Reallocated = $null
                     Pending = $null; Uncorrectable = $null; Crc = $null; PercentUsed = $null; MediaErrors = $null; Failing = @(); Note = '' }
    $text = $Lines -join "`n"
    if ($text -match 'SMART-NO-SMARTCTL') { $s.Status = 'None'; $s.Note = 'smartctl is not installed on the NAS.'; return [pscustomobject]$s }
    foreach ($l in $Lines) {
        if ($l -match 'SMART overall-health self-assessment test result:\s*(\S+)') { $s.Status = $Matches[1] }
        elseif ($l -match 'SMART Health Status:\s*(\S+)') { $s.Status = $(if ($Matches[1] -eq 'OK') { 'PASSED' } else { $Matches[1] }) }
        elseif ($l -match '^(Device Model|Model Number|Product):\s*(.+)$') { $s.Model = $Matches[2].Trim() }
        elseif ($l -match '^Serial Number:\s*(.+)$') { $s.Serial = $Matches[1].Trim() }
        elseif ($l -match '^Temperature:\s*(\d+) Celsius') { $s.Temperature = [double]$Matches[1] }
        elseif ($l -match '^Current Drive Temperature:\s*(\d+) C') { $s.Temperature = [double]$Matches[1] }
        elseif ($l -match '^Percentage Used:\s*(\d+)%') { $s.PercentUsed = [double]$Matches[1] }
        elseif ($l -match '^Power On Hours:\s*([\d,]+)') { $s.PowerOnHours = [double]($Matches[1] -replace ',', '') }
        elseif ($l -match '^Media and Data Integrity Errors:\s*([\d,]+)') { $s.MediaErrors = [double]($Matches[1] -replace ',', '') }
        elseif ($l -match '^\s*(\d+)\s+(\S+)\s+0x[0-9a-fA-F]+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(.*)$') {
            # ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
            $attrId = [int]$Matches[1]; $name = $Matches[2]; $when = $Matches[3]; $raw = Get-FirstNumber $Matches[4]
            if ($when -ne '-') { $s.Failing += "$name ($when)" }
            switch ($attrId) {
                5   { $s.Reallocated = $raw }
                9   { $s.PowerOnHours = $raw }
                194 { $s.Temperature = $raw }
                190 { if ($null -eq $s.Temperature) { $s.Temperature = $raw } }
                197 { $s.Pending = $raw }
                198 { $s.Uncorrectable = $raw }
                199 { $s.Crc = $raw }
            }
        }
    }
    if ($s.Status -eq 'Unknown' -and $text -match 'SMART-NEEDS-ROOT|password is required|Permission denied|Operation not permitted|a terminal is required|sudo: not found|not in the sudoers|may not run sudo') {
        $s.Status = 'NeedsRoot'; $s.Note = 'Reading SMART on the NAS needs a sudo rule for smartctl (see Help).'
    } elseif ($s.Status -eq 'Unknown' -and $text -match 'Unavailable - device lacks SMART|SMART support is:\s*Unavailable') {
        $s.Status = 'None'; $s.Note = 'This disk has no SMART.'
    }
    return [pscustomobject]$s
}

function ConvertFrom-MdStat([string[]]$Lines) {
    <# /proc/mdstat -> one object per array: Name, Level, Members, Failed, Wanted, Up, Map, Blocks, Action, Progress, Finish. #>
    $arrays = @(); $cur = $null
    foreach ($l in $Lines) {
        if ($l -match '^(md\d+)\s*:\s*(\S+)\s+(?:\([^)]*\)\s+)?(raid\d+|linear|multipath)?\s*(.*)$') {
            if ($cur) { $arrays += [pscustomobject]$cur }
            $members = @(); $failed = @()
            foreach ($m in [regex]::Matches($Matches[4], '(\S+?)\[\d+\](\([A-Z]\))?')) {
                $dev = $m.Groups[1].Value
                if ($m.Groups[2].Value -eq '(F)') { $failed += $dev } elseif ($m.Groups[2].Value -ne '(S)') { $members += $dev }
            }
            $cur = [ordered]@{ Name = $Matches[1]; State = $Matches[2]; Level = [string]$Matches[3]; Members = $members; Failed = $failed
                               Wanted = $null; Up = $null; Map = ''; Blocks = $null; Action = ''; Progress = $null; Finish = '' }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s+(\d+) blocks') { $cur.Blocks = [double]$Matches[1] }
        if ($l -match '\[(\d+)/(\d+)\]\s*\[([U_]+)\]') { $cur.Wanted = [int]$Matches[1]; $cur.Up = [int]$Matches[2]; $cur.Map = $Matches[3] }
        if ($l -match '(recovery|resync|reshape|check)\s*=\s*([\d.]+)%') {
            $cur.Action = $Matches[1]; $cur.Progress = [double]$Matches[2]
            if ($l -match 'finish=(\S+)') { $cur.Finish = $Matches[1] }
        } elseif ($l -match '(resync|recovery|reshape|check)\s*=\s*(DELAYED|PENDING)') { $cur.Action = $Matches[1]; $cur.Finish = $Matches[2].ToLower() }
        if ($l -match '^\s*$') { $arrays += [pscustomobject]$cur; $cur = $null }
    }
    if ($cur) { $arrays += [pscustomobject]$cur }
    return $arrays
}

function ConvertFrom-NasReport([string]$Text) {
    $sec = [ordered]@{}; $key = 'PRE'; $sec[$key] = New-Object Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^##([A-Z]+(\|\S+)?)\s*$') { $key = $Matches[1]; $sec[$key] = New-Object Collections.Generic.List[string]; continue }
        $sec[$key].Add($line)
    }
    $get = { param($k) if ($sec.Contains($k)) { @($sec[$k]) } else { @() } }
    $r = [ordered]@{ Host = ''; Version = ''; Uptime = $null; Load = ''; MemTotal = $null; MemAvailable = $null; Temperature = $null
                     Volumes = @(); Arrays = @(); Disks = @(); Complete = $sec.Contains('END'); Time = [DateTime]::Now }
    $r.Host = (@(& $get 'HOST' | Where-Object { $_.Trim() }) + @(''))[0].Trim()

    $ver = @{}
    foreach ($l in (& $get 'VERSION')) { if ($l -match '^(\w+)="?([^"]*)"?') { $ver[$Matches[1]] = $Matches[2] } }
    if ($ver.productversion) {
        $r.Version = "DSM $($ver.productversion)" + $(if ($ver.buildnumber) { "-$($ver.buildnumber)" } else { '' }) +
            $(if ($ver.smallfixnumber -and $ver.smallfixnumber -ne '0') { " Update $($ver.smallfixnumber)" } else { '' })
    } elseif ($ver.majorversion) { $r.Version = "DSM $($ver.majorversion).$($ver.minorversion)-$($ver.buildnumber)" }
    else { $r.Version = (@(& $get 'KERNEL' | Where-Object { $_.Trim() }) + @(''))[0].Trim() }

    $up = @(& $get 'UPTIME' | Where-Object { $_ -match '^\d' })
    if ($up.Count) { $r.Uptime = [double](($up[0] -split '\s+')[0]) }
    $ld = @(& $get 'LOAD' | Where-Object { $_.Trim() })
    if ($ld.Count) { $r.Load = (($ld[0] -split '\s+')[0..2]) -join '  ' }
    foreach ($l in (& $get 'MEM')) {
        if ($l -match '^MemTotal:\s*(\d+)') { $r.MemTotal = [double]$Matches[1] * 1KB }
        if ($l -match '^MemAvailable:\s*(\d+)') { $r.MemAvailable = [double]$Matches[1] * 1KB }
    }
    $temps = @(& $get 'THERMAL' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [double]$_ / 1000 } | Where-Object { $_ -gt 0 -and $_ -lt 150 })
    if ($temps.Count) { $r.Temperature = ($temps | Measure-Object -Maximum).Maximum }

    $fsType = @{}
    foreach ($l in (& $get 'MOUNTS')) { $f = $l -split '\s+'; if ($f.Count -ge 3) { $fsType[$f[1]] = $f[2] } }
    $seen = @{}
    foreach ($l in (& $get 'DF')) {
        $f = @($l -split '\s+' | Where-Object { $_ })
        if ($f.Count -lt 6 -or $f[1] -notmatch '^\d+$') { continue }
        $mount = ($f[5..($f.Count - 1)]) -join ' '
        if ($mount -notmatch '^/volume[A-Za-z]*\d+(/[A-Za-z]+share\d*)?$' -or $seen[$mount]) { continue }
        $seen[$mount] = $true
        $size = [double]$f[1] * 1KB
        if ($size -le 0) { continue }
        $r.Volumes += [pscustomobject]@{ Mount = $mount; Size = $size; Free = [double]$f[3] * 1KB; Used = [double]$f[2] * 1KB; FileSystem = [string]$fsType[$mount]; Device = $f[0] }
    }
    $r.Arrays = @(ConvertFrom-MdStat @(& $get 'MDSTAT'))

    foreach ($l in (& $get 'DISKS')) {
        if ($l -notmatch '^DISK\|') { continue }
        $f = $l -split '\|'
        $name = $f[1]
        $smart = ConvertFrom-SmartText @(& $get "SMART|$name")
        $model = if ($smart.Model) { $smart.Model } else { ([string]$f[3]).Trim() }
        $isNvme = $name -like 'nvme*'
        $r.Disks += [pscustomobject]@{
            Name = $name; Size = $(if ($f[2] -match '^\d+$') { [double]$f[2] * 512 } else { 0 }); Model = $model
            Rotational = ($f[4] -eq '1'); Removable = ($f[5] -eq '1'); Nvme = $isNvme; Smart = $smart
        }
    }
    return [pscustomobject]$r
}

# ---------------------------------------------------------------------------
#  Health rules: 0 good, 1 warning, 2 problem, 3 unknown
# ---------------------------------------------------------------------------
$script:LevelKeys  = @('Good', 'Warn', 'Bad', 'Unknown')
$script:LevelNames = @('Healthy', 'Warning', 'Problem', 'Unknown')

function Get-FreeLevel([double]$Size, [double]$Free) {
    if ($Size -le 0) { return 3 }
    $pct = 100 * $Free / $Size
    if ($pct -lt (Get-SettingNumber 'CritFreePercent' 5)) { return 2 }
    if ($pct -lt (Get-SettingNumber 'WarnFreePercent' 15)) { return 1 }
    return 0
}

function Get-PcDiskHealth($Disk) {
    <# Level and the reasons for it, for one disk from Get-PhysicalDisk (+ reliability counters). #>
    $lvl = 0; $why = @()
    switch ($Disk.Health) {
        'Healthy'   { }
        'Warning'   { $lvl = 1; $why += 'Windows reports its health as Warning' }
        'Unhealthy' { $lvl = 2; $why += 'Windows reports it as Unhealthy' }
        default     { $lvl = 3 }
    }
    if ($Disk.Operational -and $Disk.Operational -ne 'OK') { $lvl = [Math]::Max($lvl, 1); $why += "status: $($Disk.Operational)" }
    $isHdd = ($Disk.Media -eq 'HDD')
    $limit = if ($isHdd) { Get-SettingNumber 'HddTempWarn' 50 } else { Get-SettingNumber 'SsdTempWarn' 70 }
    if ($Disk.Temperature -and $Disk.Temperature -gt $limit) { $lvl = [Math]::Max($lvl, 1); $why += "running hot ($($Disk.Temperature) °C)" }
    if ($null -ne $Disk.Wear -and $Disk.Wear -ge 100) { $lvl = 2; $why += "worn out ($($Disk.Wear)% used)" }
    elseif ($null -ne $Disk.Wear -and $Disk.Wear -ge 90) { $lvl = [Math]::Max($lvl, 1); $why += "nearly worn out ($($Disk.Wear)% used)" }
    $errs = [double]$Disk.ReadErrors + [double]$Disk.WriteErrors
    if ($errs -gt 0) { $lvl = [Math]::Max($lvl, 1); $why += "$errs uncorrected read/write errors" }
    return @{ Level = $lvl; Why = $why }
}

function Get-NasDiskHealth($Disk) {
    $s = $Disk.Smart; $lvl = 0; $why = @()
    switch ($s.Status) {
        'PASSED'    { }
        'NeedsRoot' { $lvl = 3 }
        'None'      { $lvl = 3 }
        'Unknown'   { $lvl = 3 }
        default     { $lvl = 2; $why += "SMART says $($s.Status)" }
    }
    if ($s.Failing.Count) { $lvl = 2; $why += 'failing: ' + ($s.Failing -join ', ') }
    if ($s.Pending -gt 0) { $lvl = 2; $why += "$($s.Pending) pending sectors" }
    if ($s.Uncorrectable -gt 0) { $lvl = 2; $why += "$($s.Uncorrectable) uncorrectable sectors" }
    if ($s.Reallocated -gt 0) { if ($lvl -ne 2) { $lvl = 1 }; $why += "$($s.Reallocated) reallocated sectors" }
    if ($s.MediaErrors -gt 0) { if ($lvl -ne 2) { $lvl = 1 }; $why += "$($s.MediaErrors) media errors" }
    if ($null -ne $s.PercentUsed -and $s.PercentUsed -ge 100) { $lvl = 2; $why += "worn out ($($s.PercentUsed)% used)" }
    elseif ($null -ne $s.PercentUsed -and $s.PercentUsed -ge 90) { if ($lvl -ne 2) { $lvl = 1 }; $why += "nearly worn out ($($s.PercentUsed)% used)" }
    $limit = if ($Disk.Rotational) { Get-SettingNumber 'HddTempWarn' 50 } else { Get-SettingNumber 'SsdTempWarn' 70 }
    if ($s.Temperature -and $s.Temperature -gt $limit) { if ($lvl -ne 2) { $lvl = 1 }; $why += "running hot ($($s.Temperature) °C)" }
    return @{ Level = $lvl; Why = $why }
}

function Get-ArrayInfo($Array) {
    <# Title, level and state text for one /proc/mdstat array. #>
    $title = switch ($Array.Name) { 'md0' { 'DSM system' } 'md1' { 'Swap' } default { "Storage ($($Array.Name))" } }
    $level = if ($Array.Level -match '^raid(\d+)$') { "RAID $($Matches[1])" } elseif ($Array.Level) { $Array.Level } else { '' }
    $lvl = 0; $state = 'Healthy'
    $degraded = ($Array.Failed.Count -gt 0) -or ($null -ne $Array.Up -and $Array.Up -lt $Array.Wanted) -or ($Array.Map -match '_')
    if ($Array.Action -in 'recovery', 'reshape') {
        $lvl = 1
        $state = if ($null -ne $Array.Progress) { "Rebuilding $($Array.Progress)%" } else { "Rebuilding ($($Array.Finish))" }
        if ($Array.Finish -match '^([\d.]+)min$') { $state += ", about $(Format-Uptime ([double]$Matches[1] * 60)) left" }
    } elseif ($degraded) { $lvl = 2; $state = 'Degraded' }
    elseif ($Array.Action -eq 'resync') { $lvl = 1; $state = if ($null -ne $Array.Progress) { "Resyncing $($Array.Progress)%" } else { 'Resync waiting' } }
    elseif ($Array.Action -eq 'check') { $state = if ($null -ne $Array.Progress) { "Healthy, data scrubbing $($Array.Progress)%" } else { 'Healthy, scrub waiting' } }
    if ($Array.State -ne 'active' -and $lvl -lt 2) { $lvl = [Math]::Max($lvl, 1); $state += " ($($Array.State))" }
    return @{ Title = $title; RaidLevel = $level; Level = $lvl; State = $state }
}

# ---------------------------------------------------------------------------
#  Building blocks for the cards
# ---------------------------------------------------------------------------
function Set-Brush($Element, $Property, [string]$Key) { $Element.SetResourceReference($Property, $Key) }

function New-Text([string]$Text, [double]$Size = 13, [switch]$Bold, [string]$Brush = 'Fg', [string]$Margin = '0') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    Set-Brush $t ([Windows.Controls.TextBlock]::ForegroundProperty) $Brush
    return $t
}

function New-Card([double]$Width = 300) {
    $b = New-Object Windows.Controls.Border
    $b.Width = $Width; $b.Margin = '0,0,12,12'; $b.Padding = '14,12'; $b.CornerRadius = 8; $b.BorderThickness = 1; $b.HorizontalAlignment = 'Left'
    Set-Brush $b ([Windows.Controls.Border]::BackgroundProperty) 'Card'
    Set-Brush $b ([Windows.Controls.Border]::BorderBrushProperty) 'Border'
    $b.Child = New-Object Windows.Controls.StackPanel
    return $b
}

function New-Bar([double]$Percent, [string]$Brush) {
    <# A rounded bar, filled Percent of the way. #>
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $g = New-Object Windows.Controls.Grid
    $g.Height = 8; $g.Margin = '0,10,0,6'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength ([Math]::Max($Percent, 0.001)), 'Star'
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength ([Math]::Max(100 - $Percent, 0.001)), 'Star'
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $bg = New-Object Windows.Controls.Border; $bg.CornerRadius = 4
    Set-Brush $bg ([Windows.Controls.Border]::BackgroundProperty) 'BarBg'
    [Windows.Controls.Grid]::SetColumnSpan($bg, 2)
    $fill = New-Object Windows.Controls.Border; $fill.CornerRadius = 4
    Set-Brush $fill ([Windows.Controls.Border]::BackgroundProperty) $Brush
    [void]$g.Children.Add($bg); [void]$g.Children.Add($fill)
    return $g
}

function New-Pill([string]$Text, [string]$Brush) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 9; $b.Padding = '8,1,8,2'; $b.BorderThickness = 1; $b.VerticalAlignment = 'Top'; $b.HorizontalAlignment = 'Right'
    Set-Brush $b ([Windows.Controls.Border]::BorderBrushProperty) $Brush
    $b.Child = New-Text $Text 11.5 -Bold -Brush $Brush
    return $b
}

function New-CardTitle([string]$Title, [string]$Subtitle, $Pill) {
    <# Title and subtitle on the left, an optional pill on the right. #>
    $d = New-Object Windows.Controls.DockPanel
    if ($Pill) { [Windows.Controls.DockPanel]::SetDock($Pill, 'Right'); $Pill.Margin = '8,0,0,0'; [void]$d.Children.Add($Pill) }
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Title 15 -Bold))
    if ($Subtitle) { [void]$sp.Children.Add((New-Text $Subtitle 12 -Brush 'Muted' -Margin '0,2,0,0')) }
    [void]$d.Children.Add($sp)
    return $d
}

function New-DetailGrid {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = '0,10,0,0'
    $a = New-Object Windows.Controls.ColumnDefinition; $a.Width = New-Object Windows.GridLength 132
    $b = New-Object Windows.Controls.ColumnDefinition; $b.Width = New-Object Windows.GridLength 1, 'Star'
    [void]$g.ColumnDefinitions.Add($a); [void]$g.ColumnDefinitions.Add($b)
    return $g
}

function Add-DetailRow($Grid, [string]$Label, [string]$Value, [string]$Brush = 'Fg') {
    $row = $Grid.RowDefinitions.Count
    [void]$Grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $l = New-Text $Label 12.5 -Brush 'Muted' -Margin '0,2,8,2'
    $v = New-Text $Value 12.5 -Brush $Brush -Margin '0,2,0,2'
    [Windows.Controls.Grid]::SetRow($l, $row); [Windows.Controls.Grid]::SetRow($v, $row); [Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$Grid.Children.Add($l); [void]$Grid.Children.Add($v)
}

function New-Section([string]$Title, [string]$Note) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,6,0,8'
    [void]$sp.Children.Add((New-Text $Title 16 -Bold))
    if ($Note) { [void]$sp.Children.Add((New-Text $Note 12 -Brush 'Muted' -Margin '0,2,0,0')) }
    return $sp
}

function New-Wrap { $w = New-Object Windows.Controls.WrapPanel; $w.Margin = '0,0,0,8'; return $w }

function New-Banner([object[]]$Issues) {
    <# The list of problems and warnings at the top of a tab. #>
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 8; $b.Padding = '14,10'; $b.Margin = '0,0,12,14'; $b.BorderThickness = 1
    Set-Brush $b ([Windows.Controls.Border]::BackgroundProperty) 'Banner'
    $worst = ($Issues | Measure-Object -Property Level -Maximum).Maximum
    Set-Brush $b ([Windows.Controls.Border]::BorderBrushProperty) $script:LevelKeys[$worst]
    $sp = New-Object Windows.Controls.StackPanel
    foreach ($i in ($Issues | Sort-Object Level -Descending)) {
        $word = if ($i.Level -eq 2) { 'Problem' } else { 'Warning' }
        $t = New-Text "$($word): $($i.Text)" 13 -Brush $script:LevelKeys[$i.Level] -Margin '0,1,0,1'
        [void]$sp.Children.Add($t)
    }
    $b.Child = $sp
    return $b
}

function New-TabHeader([string]$Text) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    [Windows.Automation.AutomationProperties]::SetName($sp, $Text)
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8; $dot.Margin = '0,0,7,0'; $dot.VerticalAlignment = 'Center'
    Set-Brush $dot ([Windows.Shapes.Shape]::FillProperty) 'Unknown'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    [void]$sp.Children.Add($dot); [void]$sp.Children.Add($t)
    return @{ Header = $sp.PSObject.BaseObject; Dot = $dot.PSObject.BaseObject }
}

function Set-TabLevel($Header, [int]$Level) { Set-Brush $Header.Dot ([Windows.Shapes.Shape]::FillProperty) $script:LevelKeys[$Level] }

function Get-WorstLevel([object[]]$Issues, [bool]$Known = $true) {
    if (-not $Known) { return 3 }
    if (-not $Issues -or -not $Issues.Count) { return 0 }
    return [int](($Issues | Measure-Object -Property Level -Maximum).Maximum)
}

# ---------------------------------------------------------------------------
#  This PC tab
# ---------------------------------------------------------------------------
function Get-DiskKind($Disk) {
    $media = switch ($Disk.Media) { 'SSD' { 'SSD' } 'HDD' { 'HDD' } 'SCM' { 'SCM' } default { '' } }
    if (-not $media -and $Disk.Spindle -gt 0 -and $Disk.Spindle -lt 100000) { $media = 'HDD' }
    $bus = switch ($Disk.Bus) { 'NVMe' { 'NVMe' } 'SATA' { 'SATA' } 'USB' { 'USB' } 'SAS' { 'SAS' } 'RAID' { 'RAID' } 'Spaces' { 'Storage Spaces' } default { [string]$Disk.Bus } }
    return (@($bus, $media) | Where-Object { $_ }) -join ' '
}

function Show-PcHealth {
    $panel = $script:Ui.PanelPc
    $panel.Children.Clear()
    $r = $script:PcResult
    $issues = New-Object Collections.Generic.List[object]
    if (-not $r) { [void]$panel.Children.Add((New-Text 'Reading the drives...' 14 -Brush 'Muted')); return }

    $diskOf = @{}
    foreach ($d in $r.Disks) { $diskOf[[string]$d.Number] = $d }
    $lettersOf = @{}
    foreach ($v in $r.Volumes) { if ($v.DiskNumber) { $lettersOf[[string]$v.DiskNumber] = @($lettersOf[[string]$v.DiskNumber]) + $v.Letter | Where-Object { $_ } } }

    # Drives (volumes)
    $volWrap = New-Wrap
    foreach ($v in ($r.Volumes | Sort-Object Letter)) {
        $lvl = Get-FreeLevel $v.Size $v.Free
        $pct = if ($v.Size) { 100 * $v.Free / $v.Size } else { 0 }
        if ($lvl -in 1, 2) { [void]$issues.Add([pscustomobject]@{ Level = $lvl; Text = ('{0} has {1} free ({2:N0}%)' -f $v.Letter, (Format-Size $v.Free), $pct) }) }
        $card = New-Card 262
        $title = if ($v.Label) { "$($v.Letter)  $($v.Label)" } else { "$($v.Letter)  Local disk" }
        $disk = $diskOf[[string]$v.DiskNumber]
        $sub = (@($(if ($disk) { $disk.Model }), $v.FileSystem, $(if ($v.Removable) { 'removable' })) | Where-Object { $_ }) -join ' · '
        [void]$card.Child.Children.Add((New-CardTitle $title $sub $null))
        [void]$card.Child.Children.Add((New-Bar (100 - $pct) $script:LevelKeys[$lvl]))
        $line = New-Object Windows.Controls.DockPanel
        $pctText = New-Text ('{0:N0}% free' -f $pct) 12.5 -Bold -Brush $script:LevelKeys[$lvl]
        [Windows.Controls.DockPanel]::SetDock($pctText, 'Right')
        [void]$line.Children.Add($pctText)
        [void]$line.Children.Add((New-Text ('{0} free of {1}' -f (Format-Size $v.Free), (Format-Size $v.Size)) 12.5 -Brush 'Muted'))
        [void]$card.Child.Children.Add($line)
        $card.ToolTip = "Used: $(Format-Size ($v.Size - $v.Free))"
        [void]$volWrap.Children.Add($card)
    }

    # Physical disks
    $diskWrap = New-Wrap
    foreach ($d in $r.Disks) {
        $h = Get-PcDiskHealth $d
        $name = if ($d.Model) { $d.Model } else { "Disk $($d.Number)" }
        foreach ($w in $h.Why) { [void]$issues.Add([pscustomobject]@{ Level = $h.Level; Text = "$($name): $w" }) }
        if ($h.Level -eq 3 -and -not $h.Why.Count) { Write-AppLog "Disk $($d.Number) health: '$($d.Health)'." }
        $card = New-Card 320
        $letters = @($lettersOf[[string]$d.Number]) -join ', '
        $sub = (@((Get-DiskKind $d), (Format-Size $d.Size), "Disk $($d.Number)", $letters) | Where-Object { $_ }) -join ' · '
        $pillText = if ($d.Health) { $d.Health } else { 'Unknown' }
        [void]$card.Child.Children.Add((New-CardTitle $name $sub (New-Pill $pillText $script:LevelKeys[$h.Level])))
        $g = New-DetailGrid
        if ($d.Counters -eq 'ok') {
            $limit = if ($d.Media -eq 'HDD') { Get-SettingNumber 'HddTempWarn' 50 } else { Get-SettingNumber 'SsdTempWarn' 70 }
            if ($d.Temperature) {
                $t = "$($d.Temperature) °C" + $(if ($d.TemperatureMax) { " (warns at $($d.TemperatureMax) °C)" } else { '' })
                Add-DetailRow $g 'Temperature' $t $(if ($d.Temperature -gt $limit) { 'Warn' } else { 'Fg' })
            }
            if ($null -ne $d.Wear) { Add-DetailRow $g 'Wear' "$($d.Wear)% used" $(if ($d.Wear -ge 90) { 'Warn' } else { 'Fg' }) }
            if ($d.PowerOnHours) { Add-DetailRow $g 'Powered on' (Format-Hours $d.PowerOnHours) }
            if ($null -ne $d.ReadErrors -or $null -ne $d.WriteErrors) {
                $errs = [double]$d.ReadErrors + [double]$d.WriteErrors
                Add-DetailRow $g 'Uncorrected errors' ('{0:N0} read, {1:N0} write' -f [double]$d.ReadErrors, [double]$d.WriteErrors) $(if ($errs -gt 0) { 'Warn' } else { 'Fg' })
            }
            if (-not $g.Children.Count) { Add-DetailRow $g 'Details' 'This disk reports no temperature or wear.' 'Muted' }
        } elseif ($d.Counters -eq 'admin') {
            Add-DetailRow $g 'Details' 'Temperature, wear and error counts need administrator rights.' 'Muted'
        } else {
            Add-DetailRow $g 'Details' 'This disk reports no temperature or wear (common for USB drives).' 'Muted'
        }
        if ($d.Operational -and $d.Operational -ne 'OK') { Add-DetailRow $g 'Status' $d.Operational 'Warn' }
        if ($d.Serial) { $card.ToolTip = "Serial number: $($d.Serial)" }   # not on the card, so screenshots don't show it
        [void]$card.Child.Children.Add($g)
        [void]$diskWrap.Children.Add($card)
    }

    if ($issues.Count) { [void]$panel.Children.Add((New-Banner $issues.ToArray())) }
    if (-not $r.IsAdmin) {
        $note = New-Object Windows.Controls.DockPanel
        $note.Margin = '0,0,12,12'
        $btn = New-Object Windows.Controls.Button
        $btn.Content = 'Restart as administrator'; $btn.Margin = '12,0,0,0'
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        $btn.Add_Click({ Restart-Elevated })
        [void]$note.Children.Add($btn)
        $txt = New-Text 'Running without administrator rights: free space and Windows'' health verdict are shown, but disk temperatures, wear and error counts need administrator rights.' 12.5 -Brush 'Muted'
        $txt.VerticalAlignment = 'Center'
        [void]$note.Children.Add($txt)
        [void]$panel.Children.Add($note)
    }
    [void]$panel.Children.Add((New-Section 'Drives' 'Free space on each drive letter. Amber below the warning level, red below the critical level (Settings).'))
    if ($volWrap.Children.Count) { [void]$panel.Children.Add($volWrap) } else { [void]$panel.Children.Add((New-Text 'No drives found.' -Brush 'Muted' -Margin '0,0,0,12')) }
    [void]$panel.Children.Add((New-Section 'Physical disks' 'Health as Windows sees it, with the disks'' own counters where they report them.'))
    if ($diskWrap.Children.Count) { [void]$panel.Children.Add($diskWrap) } else { [void]$panel.Children.Add((New-Text 'No physical disks found.' -Brush 'Muted' -Margin '0,0,0,12')) }
    foreach ($e in $r.Errors) { [void]$panel.Children.Add((New-Text "Couldn't read $e" 12 -Brush 'Warn' -Margin '0,0,0,4')) }

    $script:Issues['This PC'] = $issues.ToArray()
    Set-TabLevel $script:PcHeader (Get-WorstLevel $issues.ToArray())
    Update-Summary
}

# ---------------------------------------------------------------------------
#  NAS tabs
# ---------------------------------------------------------------------------
function Show-NasHealth([string]$Name) {
    $tab = $script:MachineTabs[$Name]
    if (-not $tab) { return }
    $panel = $tab.Panel
    $panel.Children.Clear()
    $state = $script:NasResults[$Name]
    $issues = New-Object Collections.Generic.List[object]

    if (-not $state -or ($state.Busy -and -not $state.Report -and -not $state.Error)) {
        [void]$panel.Children.Add((New-Text "Reading $Name over SSH..." 14 -Brush 'Muted'))
        Set-TabLevel $tab.Header 3
        return
    }
    if ($state.Error) {
        $card = New-Card 640
        [void]$card.Child.Children.Add((New-CardTitle "Couldn't reach $Name" $state.Login (New-Pill 'Offline' 'Bad')))
        [void]$card.Child.Children.Add((New-Text $state.Error 13 -Margin '0,10,0,0'))
        [void]$card.Child.Children.Add((New-Text 'Check the NAS is on and that SSH is enabled (DSM: Control Panel > Terminal and SNMP), then press Refresh. The address, user and port are in Settings.' 12.5 -Brush 'Muted' -Margin '0,8,0,0'))
        [void]$panel.Children.Add($card)
        $script:Issues[$Name] = @([pscustomobject]@{ Level = 2; Text = "$($Name): couldn't be reached" })
        Set-TabLevel $tab.Header 2
        Update-Summary
        return
    }
    $n = $state.Report

    # System card
    $sys = New-Card 400
    $sub = (@($n.Version, $state.Login) | Where-Object { $_ }) -join ' · '
    [void]$sys.Child.Children.Add((New-CardTitle $(if ($n.Host) { $n.Host } else { $Name }) $sub $null))
    $g = New-DetailGrid
    if ($n.Uptime) { Add-DetailRow $g 'Up for' (Format-Uptime $n.Uptime) }
    if ($n.Load) { Add-DetailRow $g 'Load (1, 5, 15 min)' $n.Load }
    if ($n.MemTotal) {
        $usedMem = $n.MemTotal - [double]$n.MemAvailable
        Add-DetailRow $g 'Memory' ('{0} of {1} in use' -f (Format-Size $usedMem), (Format-Size $n.MemTotal))
    }
    if ($n.Temperature) { Add-DetailRow $g 'System temperature' ('{0:N0} °C' -f $n.Temperature) }
    Add-DetailRow $g 'Read at' $n.Time.ToString('HH:mm:ss') 'Muted'
    if (-not $n.Complete) { Add-DetailRow $g 'Note' 'The report stopped early, so some parts may be missing.' 'Warn' }
    [void]$sys.Child.Children.Add($g)

    # Volumes
    $volWrap = New-Wrap
    foreach ($v in ($n.Volumes | Sort-Object Mount)) {
        $lvl = Get-FreeLevel $v.Size $v.Free
        $pct = 100 * $v.Free / $v.Size
        if ($lvl -in 1, 2) { [void]$issues.Add([pscustomobject]@{ Level = $lvl; Text = ('{0} {1} has {2} free ({3:N0}%)' -f $Name, $v.Mount, (Format-Size $v.Free), $pct) }) }
        $card = New-Card 262
        [void]$card.Child.Children.Add((New-CardTitle $v.Mount $v.FileSystem $null))
        [void]$card.Child.Children.Add((New-Bar (100 - $pct) $script:LevelKeys[$lvl]))
        $line = New-Object Windows.Controls.DockPanel
        $pctText = New-Text ('{0:N0}% free' -f $pct) 12.5 -Bold -Brush $script:LevelKeys[$lvl]
        [Windows.Controls.DockPanel]::SetDock($pctText, 'Right')
        [void]$line.Children.Add($pctText)
        [void]$line.Children.Add((New-Text ('{0} free of {1}' -f (Format-Size $v.Free), (Format-Size $v.Size)) 12.5 -Brush 'Muted'))
        [void]$card.Child.Children.Add($line)
        [void]$volWrap.Children.Add($card)
    }

    # RAID arrays
    $raidWrap = New-Wrap
    foreach ($a in ($n.Arrays | Sort-Object { if ($_.Name -in 'md0', 'md1') { 1 } else { 0 } }, { [int]($_.Name -replace '\D', '') })) {
        $i = Get-ArrayInfo $a
        if ($i.Level -in 1, 2) { [void]$issues.Add([pscustomobject]@{ Level = $i.Level; Text = "$Name $($i.Title): $($i.State)" }) }
        $card = New-Card 262
        $sub = (@($i.RaidLevel, $(if ($a.Blocks) { Format-Size ($a.Blocks * 1KB) })) | Where-Object { $_ }) -join ' · '
        $pill = if ($i.Level -eq 0) { 'Healthy' } elseif ($i.Level -eq 1) { 'Busy' } else { 'Degraded' }
        if ($i.State -like 'Rebuilding*') { $pill = 'Rebuilding' }
        [void]$card.Child.Children.Add((New-CardTitle $i.Title $sub (New-Pill $pill $script:LevelKeys[$i.Level])))
        $dg = New-DetailGrid
        Add-DetailRow $dg 'State' $i.State $(if ($i.Level) { $script:LevelKeys[$i.Level] } else { 'Fg' })
        if ($null -ne $a.Wanted) { Add-DetailRow $dg 'Disks working' "$($a.Up) of $($a.Wanted)" }
        $members = @($a.Members | ForEach-Object { $_ -replace '(p\d+|\d+)$', '' -replace '^(sata\d+|nvme\d+n\d+).*$', '$1' } | Sort-Object -Unique)
        if ($members.Count) { Add-DetailRow $dg 'Members' ($members -join ', ') }
        if ($a.Failed.Count) { Add-DetailRow $dg 'Failed' ($a.Failed -join ', ') 'Bad' }
        [void]$card.Child.Children.Add($dg)
        [void]$raidWrap.Children.Add($card)
    }

    # Disks with SMART
    $diskWrap = New-Wrap
    $needsRoot = $false
    foreach ($d in $n.Disks) {
        $h = Get-NasDiskHealth $d
        $s = $d.Smart
        if ($s.Status -eq 'NeedsRoot') { $needsRoot = $true }
        $diskName = if ($d.Model) { $d.Model } else { $d.Name }
        foreach ($w in $h.Why) { [void]$issues.Add([pscustomobject]@{ Level = $h.Level; Text = "$Name $($d.Name) ($diskName): $w" }) }
        $kind = if ($d.Nvme) { 'NVMe SSD' } elseif ($d.Rotational) { 'HDD' } else { 'SSD' }
        if ($d.Removable -or $d.Name -like 'sd*') { $kind += ' (USB or eSATA)' }
        $card = New-Card 320
        $sub = (@($kind, $(if ($d.Size) { Format-Size $d.Size }), $d.Name) | Where-Object { $_ }) -join ' · '
        $pillText = switch ($s.Status) { 'PASSED' { 'SMART OK' } 'NeedsRoot' { 'No SMART access' } 'None' { 'No SMART' } 'Unknown' { 'SMART unknown' } default { "SMART $($s.Status)" } }
        [void]$card.Child.Children.Add((New-CardTitle $diskName $sub (New-Pill $pillText $script:LevelKeys[$h.Level])))
        $dg = New-DetailGrid
        $limit = if ($d.Rotational) { Get-SettingNumber 'HddTempWarn' 50 } else { Get-SettingNumber 'SsdTempWarn' 70 }
        if ($s.Temperature) { Add-DetailRow $dg 'Temperature' "$($s.Temperature) °C" $(if ($s.Temperature -gt $limit) { 'Warn' } else { 'Fg' }) }
        if ($s.PowerOnHours) { Add-DetailRow $dg 'Powered on' (Format-Hours $s.PowerOnHours) }
        if ($null -ne $s.Reallocated) { Add-DetailRow $dg 'Reallocated sectors' ('{0:N0}' -f $s.Reallocated) $(if ($s.Reallocated -gt 0) { 'Warn' } else { 'Fg' }) }
        if ($null -ne $s.Pending) { Add-DetailRow $dg 'Pending sectors' ('{0:N0}' -f $s.Pending) $(if ($s.Pending -gt 0) { 'Bad' } else { 'Fg' }) }
        if ($null -ne $s.Uncorrectable) { Add-DetailRow $dg 'Uncorrectable' ('{0:N0}' -f $s.Uncorrectable) $(if ($s.Uncorrectable -gt 0) { 'Bad' } else { 'Fg' }) }
        if ($null -ne $s.Crc) { Add-DetailRow $dg 'Cable (CRC) errors' ('{0:N0}' -f $s.Crc) $(if ($s.Crc -gt 0) { 'Warn' } else { 'Fg' }) }
        if ($null -ne $s.PercentUsed) { Add-DetailRow $dg 'Wear' "$($s.PercentUsed)% used" $(if ($s.PercentUsed -ge 90) { 'Warn' } else { 'Fg' }) }
        if ($null -ne $s.MediaErrors) { Add-DetailRow $dg 'Media errors' ('{0:N0}' -f $s.MediaErrors) $(if ($s.MediaErrors -gt 0) { 'Warn' } else { 'Fg' }) }
        if ($s.Note) { Add-DetailRow $dg 'Details' $s.Note 'Muted' }
        if ($s.Serial) { $card.ToolTip = "Serial number: $($s.Serial)" }
        [void]$card.Child.Children.Add($dg)
        [void]$diskWrap.Children.Add($card)
    }

    if ($issues.Count) { [void]$panel.Children.Add((New-Banner $issues.ToArray())) }
    # The system card sits beside the volumes, so the whole tab fits on one screen.
    $volWrap.Children.Insert(0, $sys)
    [void]$panel.Children.Add((New-Section 'System and volumes' 'Free space on each volume (df).'))
    [void]$panel.Children.Add($volWrap)
    if ($raidWrap.Children.Count) {
        [void]$panel.Children.Add((New-Section 'RAID' 'Each Linux RAID array from /proc/mdstat. md0 and md1 are DSM''s own system and swap copies on every disk; the others hold your storage pools.'))
        [void]$panel.Children.Add($raidWrap)
    }
    $note = if ($needsRoot) { 'SMART needs a sudo rule on the NAS so smartctl can run without a password. See Help > NAS SMART. Everything else works without it.' } else { 'SMART health from smartctl on the NAS.' }
    [void]$panel.Children.Add((New-Section 'Disks' $note))
    if ($diskWrap.Children.Count) { [void]$panel.Children.Add($diskWrap) } else { [void]$panel.Children.Add((New-Text 'No disks found in /sys/block.' -Brush 'Muted' -Margin '0,0,0,12')) }

    $script:Issues[$Name] = $issues.ToArray()
    Set-TabLevel $tab.Header (Get-WorstLevel $issues.ToArray())
    Update-Summary
}

function Update-Summary {
    $all = @($script:Issues.Values | ForEach-Object { $_ } | Where-Object { $_ })
    $bad = @($all | Where-Object { $_.Level -eq 2 }).Count
    $warn = @($all | Where-Object { $_.Level -eq 1 }).Count
    $busy = $script:Busy -gt 0
    if ($bad -or $warn) {
        $parts = @()
        if ($bad) { $parts += $(if ($bad -eq 1) { '1 problem' } else { "$bad problems" }) }
        if ($warn) { $parts += $(if ($warn -eq 1) { '1 warning' } else { "$warn warnings" }) }
        $first = ($all | Sort-Object Level -Descending | Select-Object -First 1).Text
        $script:Ui.TxtSummary.Text = ($parts -join ', ') + ": $first"
        $script:Ui.TxtSummary.ToolTip = (($all | Sort-Object Level -Descending | ForEach-Object { $_.Text }) -join "`n")
        Set-Brush $script:Ui.DotSummary ([Windows.Shapes.Shape]::FillProperty) $(if ($bad) { 'Bad' } else { 'Warn' })
    } elseif ($busy -and -not $script:Issues.Count) {
        $script:Ui.TxtSummary.Text = 'Checking...'
        $script:Ui.TxtSummary.ToolTip = $null
        Set-Brush $script:Ui.DotSummary ([Windows.Shapes.Shape]::FillProperty) 'Unknown'
    } else {
        $script:Ui.TxtSummary.Text = 'Everything looks healthy'
        $script:Ui.TxtSummary.ToolTip = $null
        Set-Brush $script:Ui.DotSummary ([Windows.Shapes.Shape]::FillProperty) 'Good'
    }
    if ($busy -and $script:Issues.Count) { $script:Ui.TxtSummary.Text += ' (still checking)' }
}

# ---------------------------------------------------------------------------
#  Reading everything: this PC and each NAS, in the background
# ---------------------------------------------------------------------------
$script:PcResult    = $null
$script:NasResults  = @{}
$script:Issues      = @{}
$script:Busy        = 0
$script:Fitted      = $false   # the window is sized to its cards once, after the first check
$script:LastChecked = $null

function Show-Problem([string]$Message) {
    Write-AppLog $Message
    $script:Ui.TxtStatus.Text = $Message
    Set-Brush $script:Ui.TxtStatus ([Windows.Controls.TextBlock]::ForegroundProperty) 'Bad'
}

function Update-StatusLine {
    Set-Brush $script:Ui.TxtStatus ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    if ($script:Busy -gt 0) { $script:Ui.TxtStatus.Text = 'Checking...'; return }
    if (-not $script:LastChecked) { $script:Ui.TxtStatus.Text = ''; return }
    $text = 'Last checked at ' + $script:LastChecked.ToString('HH:mm')
    $mins = Get-SettingNumber 'RefreshMinutes' 15
    if ($mins -gt 0) { $text += ", next at $($script:LastChecked.AddMinutes($mins).ToString('HH:mm'))" }
    $text += '. F5 checks again.'
    $script:Ui.TxtStatus.Text = $text
}

function Resize-ToFit {
    <# Sizes the window so every card on This PC and each NAS tab shows without scrolling: tries
       widths from the current one up to the screen's work area and takes the one that needs the
       least height, then keeps the window on screen. Never smaller than it is now; never when maximised. #>
    $w = $script:Ui.Window
    if ($w.WindowState -ne 'Normal' -or -not $script:Ui.SvPc.IsLoaded) { return }
    try {
        $work = [Windows.SystemParameters]::WorkArea
        $sv = $script:Ui.SvPc
        $chromeW = $w.ActualWidth - $sv.ActualWidth + 18          # room for a scroll bar, just in case
        $chromeH = $w.ActualHeight - $sv.ActualHeight
        $panels = @($script:Ui.PanelPc) + @($script:MachineTabs.Values | ForEach-Object { $_.Panel })
        $best = $null
        for ($width = [Math]::Max($w.ActualWidth, $w.MinWidth); $width -le $work.Width; $width += 40) {
            $inner = $width - $chromeW
            $need = 0
            foreach ($p in $panels) {
                $p.Measure((New-Object Windows.Size $inner, ([double]::PositiveInfinity)))
                $need = [Math]::Max($need, $p.DesiredSize.Height)
            }
            $height = $need + $chromeH
            if (-not $best -or $height -lt $best.Height - 1) { $best = @{ Width = $width; Height = $height } }
            if ($height -le $work.Height) { break }   # the narrowest width that shows everything
        }
        if (-not $best) { return }
        $newW = [Math]::Min($work.Width, [Math]::Max($w.ActualWidth, $best.Width))
        $newH = [Math]::Min($work.Height, [Math]::Max($w.ActualHeight, $best.Height))
        $w.Width = $newW; $w.Height = $newH
        if ($w.Left + $newW -gt $work.Right) { $w.Left = [Math]::Max($work.Left, $work.Right - $newW) }
        if ($w.Top + $newH -gt $work.Bottom) { $w.Top = [Math]::Max($work.Top, $work.Bottom - $newH) }
    } catch { Write-AppLog "Couldn't fit the window: $($_.Exception.Message)" }
    finally { foreach ($p in $panels) { try { $p.InvalidateMeasure() } catch { Write-Verbose 'Gone.' } } }
}

function Set-BusyChange([int]$Delta) {
    $script:Busy = [Math]::Max(0, $script:Busy + $Delta)
    $script:Ui.BtnRefresh.IsEnabled = ($script:Busy -eq 0)
    $script:Ui.BtnRefresh.Content = if ($script:Busy) { 'Checking...' } else { 'Refresh' }
    if ($script:Busy -eq 0) {
        $script:LastChecked = Get-Date
        if ($script:RefreshTimer.IsEnabled) { $script:RefreshTimer.Stop(); $script:RefreshTimer.Start() }   # next check counts from now
        if (-not $script:Fitted) { $script:Fitted = $true; [void]$script:Ui.Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ Resize-ToFit }) }   # first check: show every card
    }
    Update-StatusLine
    Update-Summary
}

function Update-AllHealth {
    if ($script:Busy -gt 0) { return }
    Set-BusyChange 1
    Start-Background -Work $script:PcWork -Arguments @() -State $null -OnDone {
        param($out, $err, $state)
        if ($out.Count) { $script:PcResult = $out[0] }
        elseif ($err) { Show-Problem "Couldn't read this PC's drives: $err" }
        Show-PcHealth
        Set-BusyChange -1
    }
    foreach ($m in @($script:Settings.Machines)) {
        $name = [string]$m.Name
        $old = $script:NasResults[$name]
        $script:NasResults[$name] = @{ Busy = $true; Report = $(if ($old) { $old.Report } else { $null }); Error = ''; Login = [string]$m.Login }
        if (-not $old) { Show-NasHealth $name }
        Set-BusyChange 1
        Start-Ssh $m $script:NasReportScript 90 {
            param($res, $ctx)
            $st = $script:NasResults[$ctx]
            if (-not $st) { Set-BusyChange -1; return }   # removed in Settings meanwhile
            $st.Busy = $false
            $problem = Get-SshProblem $res
            if ($problem) { $st.Error = $problem; $st.Report = $null }
            else {
                try {
                    $rep = ConvertFrom-NasReport $res.Output
                    if (-not $rep.Host -and -not $rep.Volumes.Count -and -not $rep.Disks.Count) {
                        $st.Error = 'The NAS answered but sent no report. ' + ([string]$res.Error).Trim()
                    } else { $st.Report = $rep; $st.Error = '' }
                } catch { $st.Error = "The report couldn't be read: $($_.Exception.Message)" }
            }
            if ($st.Error) { Write-AppLog "$($ctx): $($st.Error)" }
            Show-NasHealth $ctx
            Set-BusyChange -1
        } $name $null
    }
}

function Initialize-MachineTab {
    <# One tab per machine, between This PC and Biggest folders. With none, one tab that says how to add one. #>
    $tabs = $script:Ui.Tabs
    foreach ($t in @($tabs.Items | Where-Object { $_.Tag -eq 'machine' })) { $tabs.Items.Remove($t) }
    $script:MachineTabs = @{}
    foreach ($k in @($script:Issues.Keys)) { if ($k -ne 'This PC') { $script:Issues.Remove($k) } }
    foreach ($k in @($script:NasResults.Keys)) { if (@($script:Settings.Machines | Where-Object { $_.Name -eq $k }).Count -eq 0) { $script:NasResults.Remove($k) } }
    $i = 1
    foreach ($m in @($script:Settings.Machines)) {
        $tab = New-Object Windows.Controls.TabItem
        $tab.Tag = 'machine'
        $h = New-TabHeader ([string]$m.Name)
        $tab.Header = $h.Header
        [Windows.Automation.AutomationProperties]::SetName($tab, [string]$m.Name)
        $sv = New-Object Windows.Controls.ScrollViewer
        $sv.VerticalScrollBarVisibility = 'Auto'
        $panel = New-Object Windows.Controls.StackPanel
        $panel.Margin = '4,12,4,12'
        $sv.Content = $panel.PSObject.BaseObject
        $tab.Content = $sv.PSObject.BaseObject
        $tabs.Items.Insert($i, $tab); $i++
        $script:MachineTabs[[string]$m.Name] = @{ Tab = $tab; Panel = $panel; Header = $h }
        Show-NasHealth ([string]$m.Name)
    }
    if (-not @($script:Settings.Machines).Count) {
        $tab = New-Object Windows.Controls.TabItem
        $tab.Tag = 'machine'; $tab.Header = 'NAS'
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = '4,16,4,12'; $sp.MaxWidth = 620; $sp.HorizontalAlignment = 'Left'
        [void]$sp.Children.Add((New-Text 'No NAS added yet' 16 -Bold))
        [void]$sp.Children.Add((New-Text 'Add your NAS in Settings: a name, the SSH login (user@address) and the SSH port. Disk and NAS Health reads it over SSH with your key, read only: free space, RAID state, disk SMART health and the biggest folders.' 13 -Brush 'Muted' -Margin '0,6,0,12'))
        $b = New-Object Windows.Controls.Button
        $b.Content = 'Open Settings'; $b.HorizontalAlignment = 'Left'
        $b.Add_Click({ Show-Settings })
        [void]$sp.Children.Add($b)
        $tab.Content = $sp.PSObject.BaseObject
        $tabs.Items.Insert(1, $tab)
    }
    Update-WhereList
    Update-Summary
}

# ---------------------------------------------------------------------------
#  Biggest folders
# ---------------------------------------------------------------------------
$script:ScanResult  = $null    # the last scan of this PC (DiskNasHealth.ScanResult)
$script:ScanState   = $null    # while a PC scan runs
$script:SshControl  = $null    # while a NAS du runs
$script:Scanning    = $false
$script:ScanStarted = $null
$script:ScanLabel   = ''
$script:NasDu       = @{}      # "<machine>|<path>" -> du result, for going up and down again
$script:Where       = 'This PC'
$script:Current     = ''

function Get-NasMachine([string]$Name) { @($script:Settings.Machines | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1 }

function Get-DefaultFolder([string]$Where) {
    $saved = $script:Settings.FolderPaths.PSObject.Properties[$Where]
    if ($saved -and $saved.Value) { return [string]$saved.Value }
    if ($Where -eq 'This PC') { return ($env:SystemDrive + '\') }
    $st = $script:NasResults[$Where]
    if ($st -and $st.Report -and $st.Report.Volumes.Count) { return ($st.Report.Volumes | Sort-Object Mount | Select-Object -First 1).Mount }
    return '/volume1'
}

function Save-FolderPath {
    if (-not $script:Current) { return }
    $script:Settings.FolderPaths | Add-Member -NotePropertyName $script:Where -NotePropertyValue $script:Current -Force
}

function Update-WhereList {
    $cmb = $script:Ui.CmbWhere
    $keep = $script:Where
    $cmb.Items.Clear()
    [void]$cmb.Items.Add('This PC')
    foreach ($m in @($script:Settings.Machines)) { [void]$cmb.Items.Add([string]$m.Name) }
    if ($cmb.Items.Contains($keep)) { $cmb.SelectedItem = $keep } else { $cmb.SelectedIndex = 0 }
}

function Set-ScanBusy([bool]$On) {
    $script:Scanning = $On
    $u = $script:Ui
    $u.BtnScan.IsEnabled = -not $On; $u.BtnUp.IsEnabled = -not $On; $u.CmbWhere.IsEnabled = -not $On
    $u.BtnBrowse.IsEnabled = (-not $On) -and ($script:Where -eq 'This PC')
    $u.BtnStop.IsEnabled = $On
    $u.TxtPath.IsReadOnly = $On
}

function New-FolderRow([string]$Name, [string]$Path, [double]$Bytes, [double]$Total, [string]$Files, [bool]$IsFiles) {
    $pct = if ($Total -gt 0) { 100 * $Bytes / $Total } else { 0 }
    [pscustomobject]@{
        Name = $Name; Path = $Path; Bytes = $Bytes; SizeText = (Format-Size $Bytes); Percent = $pct
        PercentText = $(if ($pct -ge 0.1) { '{0:N1}%' -f $pct } else { '' }); FilesText = $Files; IsFiles = $IsFiles
    }
}

function Show-PcFolder([string]$Path) {
    $r = $script:ScanResult
    $me = $r.Get($Path)
    if (-not $me) { return }
    $script:Current = $Path
    $script:Ui.TxtPath.Text = $Path
    $rows = New-Object Collections.ArrayList
    foreach ($c in $r.ChildrenOf($Path)) {
        [void]$rows.Add((New-FolderRow $c.Name $c.Path $c.Bytes $me.Bytes ('{0:N0}' -f $c.Files) $false))
    }
    if ($me.OwnFiles -gt 0) { [void]$rows.Add((New-FolderRow '(files in this folder)' $Path $me.OwnBytes $me.Bytes ('{0:N0}' -f $me.OwnFiles) $true)) }
    $script:Ui.LstFolders.ItemsSource = [Collections.ArrayList]@($rows | Sort-Object Bytes -Descending | Select-Object -First 300)

    $prefix = $Path.TrimEnd('\') + '\'
    $files = New-Object Collections.ArrayList
    foreach ($f in $r.TopFiles) {
        if ($f.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$files.Add([pscustomobject]@{ Name = $f.Name; Path = $f.Path; SizeText = (Format-Size $f.Bytes); Folder = $f.Folder })
            if ($files.Count -ge 100) { break }
        }
    }
    $script:Ui.LstFiles.ItemsSource = $files
    $script:Ui.TxtFilesTitle.Text = 'Largest files'
    $script:Ui.TxtScan.Text = ('{0}: {1} in {2:N0} files and {3:N0} folders' -f $Path, (Format-Size $me.Bytes), $me.Files, $me.Folders) +
        $(if ($r.Cancelled) { ' (scan stopped early, so it''s only part of it)' } else { '' })
    Save-FolderPath
}

function Show-NasFolder([string]$Key) {
    $d = $script:NasDu[$Key]
    $script:Current = $d.Path
    $script:Ui.TxtPath.Text = $d.Path
    $rows = New-Object Collections.ArrayList
    foreach ($e in $d.Entries) { [void]$rows.Add((New-FolderRow $e.Name $e.Path $e.Bytes $d.Total '' $false)) }
    $script:Ui.LstFolders.ItemsSource = [Collections.ArrayList]@($rows | Sort-Object Bytes -Descending | Select-Object -First 300)
    $script:Ui.LstFiles.ItemsSource = $null
    $script:Ui.TxtFilesTitle.Text = 'Largest files (this PC only)'
    $msg = '{0}: {1} (measured at {2})' -f $d.Path, (Format-Size $d.Total), $d.Time.ToString('HH:mm')
    if ($d.Denied) { $msg += ". $($d.Denied) folders couldn't be read by the SSH user, so they aren't counted" }
    $script:Ui.TxtScan.Text = $msg
    Save-FolderPath
}

function ConvertTo-NasPath([string]$Path) {
    $p = $Path.Trim() -replace '\\', '/'
    if ($p.Length -gt 1) { $p = $p.TrimEnd('/') }
    return $p
}

function Start-FolderScan([string]$Path, [switch]$Force) {
    if ($script:Scanning) { return }
    $u = $script:Ui
    if ($script:Where -eq 'This PC') {
        $Path = $Path.Trim().Trim('"')
        if ($Path -match '^[A-Za-z]:$') { $Path += '\' }
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { $u.TxtScan.Text = "That folder wasn't found: $Path"; return }
        $root = [DiskNasHealth.Scanner]::Normalize($Path)
        if (-not $Force -and $script:ScanResult -and $script:ScanResult.Knows($root)) { Show-PcFolder $root; return }
        $script:ScanState = New-Object DiskNasHealth.ScanState
        $script:ScanStarted = [DateTime]::Now
        $script:ScanLabel = $root
        $u.LstFolders.ItemsSource = $null; $u.LstFiles.ItemsSource = $null
        Set-ScanBusy $true
        Start-Background -Work { param($root, $st) [DiskNasHealth.Scanner]::Scan($root, 5, $st) } -Arguments @($root, $script:ScanState) -State $root -OnDone {
            param($out, $err, $state)
            $st = $script:ScanState
            Set-ScanBusy $false
            if ($out.Count -and $out[0]) {
                $script:ScanResult = $out[0]
                Show-PcFolder $state
                $secs = ([DateTime]::Now - $script:ScanStarted).TotalSeconds
                $extra = '  Scanned in {0:N0} s' -f $secs
                if ($st.Skipped -gt 0) { $extra += ('; {0:N0} folders couldn''t be read (no permission), so aren''t counted' -f $st.Skipped) }
                $script:Ui.TxtScan.Text += ".$extra."
            } else { $script:Ui.TxtScan.Text = "The scan failed: $err" }
            $script:ScanState = $null
        }
    } else {
        $m = Get-NasMachine $script:Where
        if (-not $m) { return }
        $Path = ConvertTo-NasPath $Path
        if ($Path -notlike '/*') { $u.TxtScan.Text = 'NAS folders start with /, for example /volume1.'; return }
        $key = "$($m.Name)|$Path"
        if (-not $Force -and $script:NasDu[$key]) { Show-NasFolder $key; return }
        $q = ConvertTo-ShQuote $Path
        $sh = @"
PATH="`$PATH:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C
p=$q
[ -d "`$p" ] || { echo '##NOTFOUND'; exit 0; }
if du -k -d 0 /dev/null >/dev/null 2>&1; then D='-d 1'; else D='--max-depth=1'; fi
echo '##DU'
du -k `$D "`$p" 2>&1
echo '##END'
"@
        $script:SshControl = [hashtable]::Synchronized(@{ Cancel = $false; Pid = 0 })
        $script:ScanStarted = [DateTime]::Now
        $script:ScanLabel = "$Path on $($m.Name)"
        $u.LstFolders.ItemsSource = $null; $u.LstFiles.ItemsSource = $null
        Set-ScanBusy $true
        Start-Ssh $m $sh 3600 {
            param($res, $ctx)
            Set-ScanBusy $false
            $script:SshControl = $null
            $problem = Get-SshProblem $res
            if ($problem) { $script:Ui.TxtScan.Text = "Couldn't measure it: $problem"; return }
            if ($res.Output -match '##NOTFOUND') { $script:Ui.TxtScan.Text = "That folder wasn't found on $($ctx.Machine): $($ctx.Path)"; return }
            $entries = @(); $denied = 0; $total = 0.0
            foreach ($l in ($res.Output -split "`r?`n")) {
                if ($l -match '^du: ') { $denied++; continue }
                if ($l -notmatch '^(\d+)\s+(.+)$') { continue }
                $bytes = [double]$Matches[1] * 1KB; $p = ConvertTo-NasPath $Matches[2]
                if ($p -eq $ctx.Path) { $total = $bytes; continue }
                $entries += [pscustomobject]@{ Name = ($p -split '/')[-1]; Path = $p; Bytes = $bytes }
            }
            if (-not $total) { $total = ($entries | Measure-Object -Property Bytes -Sum).Sum }
            $script:NasDu[$ctx.Key] = @{ Path = $ctx.Path; Entries = $entries; Total = [double]$total; Denied = $denied; Time = [DateTime]::Now }
            Show-NasFolder $ctx.Key
        } @{ Key = $key; Path = $Path; Machine = $m.Name } $script:SshControl
    }
}

function Stop-FolderScan {
    if ($script:ScanState) { $script:ScanState.Cancel = $true }
    if ($script:SshControl) { $script:SshControl.Cancel = $true }
    $script:Ui.TxtScan.Text = 'Stopping...'
}

function Open-FolderRow($Row) {
    if (-not $Row -or $Row.IsFiles -or $script:Scanning) { return }
    Start-FolderScan $Row.Path
}

function Open-ParentFolder {
    if ($script:Scanning -or -not $script:Current) { return }
    if ($script:Where -eq 'This PC') {
        $parent = [IO.Path]::GetDirectoryName($script:Current)
        if ($parent) { Start-FolderScan $parent }
    } else {
        if ($script:Current -eq '/') { return }
        $parent = $script:Current.Substring(0, $script:Current.LastIndexOf('/'))
        if (-not $parent) { $parent = '/' }
        Start-FolderScan $parent
    }
}

function Update-ScanProgress {
    if (-not $script:Scanning) { return }
    $secs = [int]([DateTime]::Now - $script:ScanStarted).TotalSeconds
    if ($script:ScanState) {
        $st = $script:ScanState
        $script:Ui.TxtScan.Text = ('Scanning {0}: {1:N0} files, {2} so far ({3} s). {4}' -f $script:ScanLabel, $st.Files, (Format-Size $st.Bytes), $secs, $st.Current)
    } elseif ($script:SshControl) {
        $script:Ui.TxtScan.Text = "Measuring $($script:ScanLabel) with du ($secs s). A big volume can take a few minutes."
    }
}

function Copy-Text([string]$Text) {
    try { [Windows.Clipboard]::SetText($Text) } catch { Show-Problem "Couldn't copy: $($_.Exception.Message)" }
}

function Open-InExplorer([string]$Path, [switch]$Select) {
    if ($script:Where -ne 'This PC') { return }
    try {
        if ($Select) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$Path`"" }
        else { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Path`"" }
    } catch { Show-Problem "Couldn't open Explorer: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Report for the clipboard
# ---------------------------------------------------------------------------
function Get-ReportText {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("$script:AppName v$script:AppVersion - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void]$sb.AppendLine('')
    $r = $script:PcResult
    if ($r) {
        [void]$sb.AppendLine("This PC ($env:COMPUTERNAME)")
        foreach ($v in ($r.Volumes | Sort-Object Letter)) {
            [void]$sb.AppendLine(('  {0,-4} {1,-20} {2,10} free of {3,10} ({4:N0}%)' -f $v.Letter, $v.Label, (Format-Size $v.Free), (Format-Size $v.Size), (100 * $v.Free / $v.Size)))
        }
        foreach ($d in $r.Disks) {
            $line = '  Disk {0}: {1}, {2}, {3}, health {4}' -f $d.Number, $d.Model, (Get-DiskKind $d), (Format-Size $d.Size), $d.Health
            if ($d.Temperature) { $line += ", $($d.Temperature) °C" }
            if ($null -ne $d.Wear) { $line += ", wear $($d.Wear)%" }
            if ($d.PowerOnHours) { $line += ", $([int]$d.PowerOnHours) hours" }
            [void]$sb.AppendLine($line)
        }
        [void]$sb.AppendLine('')
    }
    foreach ($m in @($script:Settings.Machines)) {
        $st = $script:NasResults[[string]$m.Name]
        [void]$sb.AppendLine("$($m.Name) ($($m.Login))")
        if (-not $st -or $st.Error -or -not $st.Report) { [void]$sb.AppendLine("  Not read: $(if ($st) { $st.Error })"); [void]$sb.AppendLine(''); continue }
        $n = $st.Report
        [void]$sb.AppendLine("  $($n.Host), $($n.Version), up $(if ($n.Uptime) { Format-Uptime $n.Uptime })")
        foreach ($v in $n.Volumes) { [void]$sb.AppendLine(('  {0,-12} {1,10} free of {2,10} ({3:N0}%)' -f $v.Mount, (Format-Size $v.Free), (Format-Size $v.Size), (100 * $v.Free / $v.Size))) }
        foreach ($a in $n.Arrays) { $i = Get-ArrayInfo $a; [void]$sb.AppendLine("  $($a.Name) $($i.RaidLevel): $($i.State)") }
        foreach ($d in $n.Disks) {
            $s = $d.Smart
            $line = '  {0}: {1}, {2}, SMART {3}' -f $d.Name, $d.Model, (Format-Size $d.Size), $s.Status
            if ($s.Temperature) { $line += ", $($s.Temperature) °C" }
            if ($null -ne $s.Reallocated) { $line += ", reallocated $($s.Reallocated)" }
            if ($null -ne $s.Pending) { $line += ", pending $($s.Pending)" }
            [void]$sb.AppendLine($line)
        }
        [void]$sb.AppendLine('')
    }
    $all = @($script:Issues.Values | ForEach-Object { $_ } | Where-Object { $_ })
    if ($all.Count) {
        [void]$sb.AppendLine('Needs a look')
        foreach ($i in ($all | Sort-Object Level -Descending)) { [void]$sb.AppendLine("  $(if ($i.Level -eq 2) { 'Problem' } else { 'Warning' }): $($i.Text)") }
    } else { [void]$sb.AppendLine('Everything looks healthy.') }
    return $sb.ToString()
}

function Restart-Elevated {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:ScriptPath`""
        $script:Ui.Window.Close()
    } catch { Show-Problem 'Not restarted as administrator (the Windows prompt was cancelled).' }
}
$script:ScriptPath = $PSCommandPath

# ---------------------------------------------------------------------------
#  Settings window
# ---------------------------------------------------------------------------
$script:SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="600" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}" UseLayoutRounding="True">
    <Window.Resources><!--STYLES--></Window.Resources>
    <StackPanel Margin="20">
        <TextBlock Text="NAS and other machines" FontWeight="SemiBold" FontSize="15"/>
        <TextBlock Text="Read over SSH with your key (no passwords are asked for or stored). Nothing on them is changed." Foreground="{DynamicResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,10"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <DockPanel Grid.Column="0">
                <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="BtnAdd" Content="Add"/>
                    <Button x:Name="BtnRemove" Content="Remove" Margin="8,0,0,0"/>
                </StackPanel>
                <ListBox x:Name="LstMachines" Height="168"/>
            </DockPanel>
            <StackPanel Grid.Column="2">
                <TextBlock Text="Name"/>
                <TextBox x:Name="TxtName" Margin="0,3,0,8"/>
                <TextBlock Text="SSH login (user@address)"/>
                <TextBox x:Name="TxtLogin" Margin="0,3,0,8"/>
                <TextBlock Text="SSH port (blank for 22)"/>
                <TextBox x:Name="TxtPort" Margin="0,3,0,10" Width="100" HorizontalAlignment="Left"/>
                <Button x:Name="BtnTest" Content="Test connection" HorizontalAlignment="Left"/>
                <TextBlock x:Name="TxtTest" TextWrapping="Wrap" Margin="0,6,0,0" FontSize="12" Foreground="{DynamicResource Muted}"/>
            </StackPanel>
        </Grid>
        <TextBlock Text="Warnings and checks" FontWeight="SemiBold" FontSize="15" Margin="0,20,0,10"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Warning when a drive has less free space than (%)" VerticalAlignment="Center"/>
            <TextBox Grid.Row="0" Grid.Column="1" x:Name="TxtWarn" Margin="0,3"/>
            <TextBlock Grid.Row="1" Text="Problem when a drive has less free space than (%)" VerticalAlignment="Center"/>
            <TextBox Grid.Row="1" Grid.Column="1" x:Name="TxtCrit" Margin="0,3"/>
            <TextBlock Grid.Row="2" Text="Hard disk temperature warning above (°C)" VerticalAlignment="Center"/>
            <TextBox Grid.Row="2" Grid.Column="1" x:Name="TxtHdd" Margin="0,3"/>
            <TextBlock Grid.Row="3" Text="SSD temperature warning above (°C)" VerticalAlignment="Center"/>
            <TextBox Grid.Row="3" Grid.Column="1" x:Name="TxtSsd" Margin="0,3"/>
            <TextBlock Grid.Row="4" Text="Check again every (minutes, 0 = only when you press Refresh)" VerticalAlignment="Center"/>
            <TextBox Grid.Row="4" Grid.Column="1" x:Name="TxtRefresh" Margin="0,3"/>
            <TextBlock Grid.Row="5" Text="Theme" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="5" Grid.Column="1" x:Name="CmbTheme" Margin="0,3">
                <ComboBoxItem Content="Auto"/><ComboBoxItem Content="Light"/><ComboBoxItem Content="Dark"/>
            </ComboBox>
        </Grid>
        <TextBlock x:Name="TxtError" Foreground="{DynamicResource Bad}" TextWrapping="Wrap" Margin="0,12,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnSave" Content="Save" Style="{DynamicResource AccentButton}" MinWidth="80" IsDefault="True"/>
            <Button x:Name="BtnCancel" Content="Cancel" MinWidth="80" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Save-SettingsField {
    <# Copies the Name, Login and Port boxes into the machine being edited. #>
    $c = $script:SettingsCtx
    if ($c.Index -lt 0 -or $c.Index -ge $c.Work.Count) { return }
    $it = $c.Work[$c.Index]
    $it.Name = $c.F.TxtName.Text.Trim(); $it.Login = $c.F.TxtLogin.Text.Trim(); $it.Port = $c.F.TxtPort.Text.Trim()
}

function Update-MachineList([int]$Select) {
    $c = $script:SettingsCtx
    $c.Loading = $true
    $c.F.LstMachines.Items.Clear()
    foreach ($it in $c.Work) { [void]$c.F.LstMachines.Items.Add($(if ($it.Name) { $it.Name } else { '(new machine)' })) }
    $c.Loading = $false
    $c.Index = -1
    if ($c.Work.Count) { $c.F.LstMachines.SelectedIndex = [Math]::Min([Math]::Max($Select, 0), $c.Work.Count - 1) }
    else { foreach ($n in 'TxtName', 'TxtLogin', 'TxtPort') { $c.F[$n].Text = ''; $c.F[$n].IsEnabled = $false } }
}

function Show-Settings {
    $w = New-XamlWindow $script:SettingsXaml
    $w.Owner = $script:Ui.Window; $w.Icon = $script:Ui.Window.Icon
    $f = @{}
    foreach ($n in 'LstMachines', 'BtnAdd', 'BtnRemove', 'TxtName', 'TxtLogin', 'TxtPort', 'BtnTest', 'TxtTest', 'TxtWarn', 'TxtCrit', 'TxtHdd', 'TxtSsd', 'TxtRefresh', 'CmbTheme', 'TxtError', 'BtnSave') { $f[$n] = $w.FindName($n) }
    $work = New-Object Collections.ArrayList
    foreach ($m in @($script:Settings.Machines)) { [void]$work.Add(@{ Name = [string]$m.Name; Login = [string]$m.Login; Port = [string]$m.Port }) }
    $script:SettingsCtx = @{ Index = -1; Loading = $false; Work = $work; F = $f; Saved = $false }

    $f.LstMachines.Add_SelectionChanged({
            if ($script:SettingsCtx.Loading) { return }
            Save-SettingsField
            $i = $script:SettingsCtx.F.LstMachines.SelectedIndex
            $script:SettingsCtx.Index = $i
            $on = $i -ge 0
            foreach ($n in 'TxtName', 'TxtLogin', 'TxtPort') { $script:SettingsCtx.F[$n].IsEnabled = $on }
            if ($on) {
                $it = $script:SettingsCtx.Work[$i]
                $script:SettingsCtx.F.TxtName.Text = $it.Name; $script:SettingsCtx.F.TxtLogin.Text = $it.Login; $script:SettingsCtx.F.TxtPort.Text = $it.Port
            }
            $script:SettingsCtx.F.TxtTest.Text = ''
        })
    $f.TxtName.Add_LostFocus({
            if ($script:SettingsCtx.Index -lt 0) { return }
            Save-SettingsField
            $i = $script:SettingsCtx.Index
            Update-MachineList $i
        })
    $f.BtnAdd.Add_Click({
            Save-SettingsField
            [void]$script:SettingsCtx.Work.Add(@{ Name = 'NAS'; Login = ''; Port = '' })
            Update-MachineList ($script:SettingsCtx.Work.Count - 1)
            $script:SettingsCtx.F.TxtLogin.Focus()
        })
    $f.BtnRemove.Add_Click({
            $i = $script:SettingsCtx.Index
            if ($i -lt 0) { return }
            $script:SettingsCtx.Work.RemoveAt($i)
            $script:SettingsCtx.Index = -1
            Update-MachineList ($i - 1)
        })
    $f.BtnTest.Add_Click({
            Save-SettingsField
            if ($script:SettingsCtx.Index -lt 0) { return }
            $it = $script:SettingsCtx.Work[$script:SettingsCtx.Index]
            if ($it.Login -notmatch '^[^@\s]+@[^@\s]+$') { $script:SettingsCtx.F.TxtTest.Text = 'The login needs to be user@address, for example admin@192.168.1.10.'; return }
            $script:SettingsCtx.F.TxtTest.Text = 'Connecting...'
            $script:SettingsCtx.F.BtnTest.IsEnabled = $false
            $test = @'
PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
echo "##HOST|$(hostname)"
SC=$(command -v smartctl 2>/dev/null)
if [ -z "$SC" ]; then echo '##NOSMART'
elif [ "$(id -u)" = 0 ] || sudo -n "$SC" --version >/dev/null 2>&1; then echo '##SMARTOK'
else echo '##SMARTROOT'; fi
'@
            $m = [pscustomobject]@{ Name = $it.Name; Login = $it.Login; Port = $it.Port }
            Start-Ssh $m $test 30 {
                param($res, $c)
                $c.F.BtnTest.IsEnabled = $true
                $problem = Get-SshProblem $res
                if ($problem) { $c.F.TxtTest.Text = "Couldn't connect: $problem"; return }
                if ($res.Output -notmatch '##HOST\|(.*)') { $c.F.TxtTest.Text = "Connected, but the NAS didn't answer as expected. $($res.Error)".Trim(); return }
                $h = $Matches[1].Trim()
                $smart = if ($res.Output -match '##SMARTOK') { 'SMART can be read.' }
                elseif ($res.Output -match '##NOSMART') { 'smartctl isn''t installed there, so disk SMART won''t show.' }
                else { 'SMART needs a sudo rule for smartctl (see Help > NAS SMART); everything else works.' }
                $c.F.TxtTest.Text = "Connected to $h. $smart"
            } $script:SettingsCtx $null
        })

    $f.TxtWarn.Text = [string](Get-SettingNumber 'WarnFreePercent' 15)
    $f.TxtCrit.Text = [string](Get-SettingNumber 'CritFreePercent' 5)
    $f.TxtHdd.Text = [string](Get-SettingNumber 'HddTempWarn' 50)
    $f.TxtSsd.Text = [string](Get-SettingNumber 'SsdTempWarn' 70)
    $f.TxtRefresh.Text = [string](Get-SettingNumber 'RefreshMinutes' 15)
    $f.CmbTheme.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@('Auto', 'Light', 'Dark'), [string]$script:Settings.Theme))
    Update-MachineList 0

    $f.BtnSave.Add_Click({
            Save-SettingsField
            $err = @()
            $names = @{}
            foreach ($it in $script:SettingsCtx.Work) {
                if (-not $it.Name) { $err += 'Every machine needs a name.' }
                elseif ($it.Name -eq 'This PC' -or $names[$it.Name]) { $err += "The name '$($it.Name)' is already used." }
                $names[$it.Name] = $true
                if ($it.Login -notmatch '^[^@\s]+@[^@\s]+$') { $err += "$($it.Name): the login needs to be user@address." }
                $p = 0
                if ($it.Port -and (-not [int]::TryParse($it.Port, [ref]$p) -or $p -lt 1 -or $p -gt 65535)) { $err += "$($it.Name): the port must be a number from 1 to 65535." }
            }
            $nums = @{}
            foreach ($pair in @(@('TxtWarn', 'WarnFreePercent', 100), @('TxtCrit', 'CritFreePercent', 100), @('TxtHdd', 'HddTempWarn', 120), @('TxtSsd', 'SsdTempWarn', 120), @('TxtRefresh', 'RefreshMinutes', 1440))) {
                $v = 0.0
                if (-not [double]::TryParse($script:SettingsCtx.F[$pair[0]].Text.Trim(), [ref]$v) -or $v -lt 0 -or $v -gt $pair[2]) { $err += "$($pair[1]) must be a number from 0 to $($pair[2])." }
                else { $nums[$pair[1]] = $v }
            }
            if ($nums.CritFreePercent -gt $nums.WarnFreePercent) { $err += 'The problem level should be lower than the warning level.' }
            if ($err.Count) { $script:SettingsCtx.F.TxtError.Text = ($err | Select-Object -Unique) -join "`n"; return }
            $script:Settings.Machines = @(foreach ($it in $script:SettingsCtx.Work) { [pscustomobject]@{ Name = $it.Name; Login = $it.Login; Port = $it.Port } })
            foreach ($k in $nums.Keys) { $script:Settings.$k = $nums[$k] }
            $script:Settings.Theme = @('Auto', 'Light', 'Dark')[[Math]::Max(0, $script:SettingsCtx.F.CmbTheme.SelectedIndex)]
            Save-AppSetting
            $script:SettingsCtx.Saved = $true
            [Windows.Window]::GetWindow($this).Close()
        })
    [void]$w.ShowDialog()

    if ($script:SettingsCtx.Saved) {
        Set-ThemeBrush $script:Ui.Window
        Initialize-MachineTab
        Set-RefreshTimer
        if ($script:PcResult) { Show-PcHealth }
        Update-AllHealth
    }
}

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @(
    @('h', 'What it shows'),
    @('p', 'Disk and NAS Health checks your drives in one window: how full each one is, whether the disks themselves are healthy, and which folders take the space. It only reads. It never writes to, tests, formats or changes a disk, here or on the NAS.'),
    @('p', 'The line under the title sums it up: green when everything looks healthy, amber for warnings and red for problems. Hover over it for the full list. Each tab has a coloured dot too, and its own list at the top.'),
    @('h', 'This PC'),
    @('p', 'Drives: free space on every fixed and removable drive letter. Amber below the warning level and red below the problem level (15% and 5% to start with, set in Settings).'),
    @('p', 'Physical disks: what Windows knows about each disk (Get-PhysicalDisk): model, NVMe, SATA or USB, SSD or HDD, size, which drive letters are on it, and Windows'' health verdict (Healthy, Warning or Unhealthy).'),
    @('p', 'Run as administrator (the button in the header or on the tab) to see each disk''s own counters as well: temperature, wear (how much of an SSD''s rated life is used), power-on hours and uncorrected read and write errors. Windows only shares these with administrators. USB drives often report none.'),
    @('h', 'NAS'),
    @('p', 'Each machine in Settings gets its own tab. Disk and NAS Health connects with Windows'' own ssh.exe and your SSH key (no password prompts), sends one read-only script and reads the answer:'),
    @('b', 'System: host name, DSM version, uptime, load, memory and temperature.'),
    @('b', 'Volumes: free space on each /volume (df).'),
    @('b', 'RAID: each array from /proc/mdstat, with Healthy, Degraded, Rebuilding (with progress and time left) or data scrubbing. md0 and md1 are DSM''s own system and swap partitions, mirrored on every disk.'),
    @('b', 'Disks: model, size and type of each disk, and its SMART health from smartctl: overall result, temperature, power-on hours, reallocated, pending and uncorrectable sectors and cable (CRC) errors, or wear and media errors for NVMe.'),
    @('p', 'Problems: SMART failing, pending or uncorrectable sectors, a degraded array, a worn-out SSD. Warnings: reallocated sectors, a disk running hot, an array rebuilding, low free space.'),
    @('h', 'NAS SMART'),
    @('p', 'smartctl has to run as root. Over SSH your user isn''t root, so SMART only shows if sudo lets your user run smartctl without a password. Everything else works without it. To allow it, sign in to the NAS over SSH yourself and run these (sudo -i asks for your DSM password; put your SSH user name in place of YOURUSER):'),
    @('code', "sudo -i`ncommand -v smartctl`necho 'YOURUSER ALL=(root) NOPASSWD: /usr/bin/smartctl' > /etc/sudoers.d/disk-nas-health`nchmod 440 /etc/sudoers.d/disk-nas-health`nexit"),
    @('p', 'Use the path that command -v smartctl printed if it isn''t /usr/bin/smartctl. Settings > Test connection then says "SMART can be read". A big DSM update can remove the file; just add it again.'),
    @('h', 'Biggest folders'),
    @('p', 'Pick This PC or a NAS, type or browse to a folder and press Scan. You get its folders, biggest first, with their share of the total, and (on this PC) the largest files underneath. Double-click a folder to go into it, Up or Backspace to go back. Right-click for Open in Explorer and Copy path.'),
    @('p', 'This PC: one scan lists every folder underneath and adds up the file sizes, so going in and out afterwards is instant (down to five levels; deeper folders are scanned when you open them). It only reads folder listings, never the files. Junctions and links are skipped so nothing is counted twice, and OneDrive files that are online-only count as 0, because they use no space. Folders Windows won''t let you read (System Volume Information) are skipped; running as administrator reads more of them.'),
    @('p', 'NAS: du measures the folder over SSH, one level at a time. A whole volume can take a few minutes the first time. Folders your SSH user can''t read (some of DSM''s @ folders) aren''t counted, and the line above the list says how many.'),
    @('p', 'Stop ends a scan early; what was measured so far is shown.'),
    @('h', 'Settings'),
    @('b', 'Machines: name, SSH login (user@address) and port. The first time, they''re copied from Homelab or Docker Container Manager if you use them. Test connection checks SSH and whether SMART can be read.'),
    @('b', 'Warning and problem levels for free space, the temperature above which a hard disk or SSD gets a warning, how often to check again by itself, and the theme.'),
    @('p', 'Settings are kept in %APPDATA%\Disk and NAS Health, with a log of anything that went wrong.'),
    @('h', 'Keys'),
    @('b', 'F5: check everything again.  F1: this help.  Backspace (in Biggest folders): up one folder.  Enter in the folder box: scan.'),
    @('h', 'Copy report'),
    @('p', 'Copies a plain-text summary of everything (drives, disks, NAS, and the list of warnings and problems) to the clipboard, to paste into a note or a message.')
)

function Show-Help {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Help" Width="700" Height="640" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}" UseLayoutRounding="True">
    <Window.Resources><!--STYLES--></Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Bottom" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0" Padding="16,10">
            <Button x:Name="BtnClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" IsCancel="True" IsDefault="True"/>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Body" Margin="22,14,22,18"/></ScrollViewer>
    </DockPanel>
</Window>
'@
    $w = New-XamlWindow $xaml
    $w.Owner = $script:Ui.Window; $w.Icon = $script:Ui.Window.Icon
    $body = $w.FindName('Body')
    foreach ($item in $script:HelpText) {
        switch ($item[0]) {
            'h' { [void]$body.Children.Add((New-Text $item[1] 16 -Bold -Margin '0,12,0,4')) }
            'p' { [void]$body.Children.Add((New-Text $item[1] 13 -Margin '0,3,0,3')) }
            'b' { [void]$body.Children.Add((New-Text ("•  " + $item[1]) 13 -Margin '12,2,0,2')) }
            'code' {
                $tb = New-Object Windows.Controls.TextBox
                $tb.Text = $item[1]; $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12.5; $tb.Margin = '0,6,0,6'; $tb.Padding = '8,6'
                $body.Children.Add($tb) | Out-Null
            }
        }
    }
    $w.FindName('BtnClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style)
#  Every Home tool's About shows: logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}">
    <Window.Resources><!--STYLES--></Window.Resources>
    <StackPanel Margin="22" MaxWidth="440">
        <StackPanel Orientation="Horizontal">
            <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
            <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
                <TextBlock x:Name="AboutVersion" Foreground="{DynamicResource Muted}"/>
            </StackPanel>
        </StackPanel>
        <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
        <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource Muted}"/>
        <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{DynamicResource Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
        <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{DynamicResource Muted}"/>
        <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
    </StackPanel>
</Window>
'@

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Disk-NAS-Health.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1120" Height="740" MinWidth="780" MinHeight="480"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}" UseLayoutRounding="True">
    <Window.Resources><!--STYLES--></Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" Background="{DynamicResource Header}" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,1" Padding="16,10">
            <DockPanel>
                <Image x:Name="ImgLogo" DockPanel.Dock="Left" Width="38" Height="38" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnAdmin" Content="Run as administrator" Margin="0,0,8,0" ToolTip="Restart with administrator rights to read disk temperatures, wear and error counts"/>
                    <Button x:Name="BtnRefresh" Content="Refresh" Style="{DynamicResource AccentButton}" MinWidth="96" Margin="0,0,8,0" ToolTip="Check everything again (F5)"/>
                    <Button x:Name="BtnCopy" Content="Copy report" Margin="0,0,8,0" ToolTip="Copy a plain-text summary to the clipboard"/>
                    <Button x:Name="BtnSettings" Content="Settings" Margin="0,0,8,0" ToolTip="NAS logins, warning levels, refresh, theme"/>
                    <Button x:Name="BtnHelp" Content="Help" Margin="0,0,8,0" ToolTip="How it works (F1)"/>
                    <Button x:Name="BtnAbout" Content="About"/>
                </StackPanel>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="TxtTitle" FontSize="18" FontWeight="SemiBold"/>
                    <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                        <Ellipse x:Name="DotSummary" Width="9" Height="9" Margin="0,0,7,0" VerticalAlignment="Center" Fill="{DynamicResource Unknown}"/>
                        <TextBlock x:Name="TxtSummary" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis" Text="Checking..."/>
                    </StackPanel>
                </StackPanel>
            </DockPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Header}" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0" Padding="16,5">
            <DockPanel>
                <TextBlock DockPanel.Dock="Right" Text="Read only: nothing on your disks or NAS is changed" Foreground="{DynamicResource Muted}" FontSize="12"/>
                <TextBlock x:Name="TxtStatus" Foreground="{DynamicResource Muted}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
            </DockPanel>
        </Border>
        <TabControl x:Name="Tabs" Margin="12,8,4,0">
            <TabItem x:Name="TabPc">
                <ScrollViewer x:Name="SvPc" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PanelPc" Margin="4,12,4,12"/></ScrollViewer>
            </TabItem>
            <TabItem x:Name="TabFolders" Header="Biggest folders">
                <Grid Margin="4,12,12,12">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <DockPanel Grid.Row="0">
                        <ComboBox x:Name="CmbWhere" DockPanel.Dock="Left" Width="150" Margin="0,0,8,0" VerticalContentAlignment="Center"/>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                            <Button x:Name="BtnBrowse" Content="Browse..." Margin="8,0,0,0"/>
                            <Button x:Name="BtnUp" Content="Up" Margin="8,0,0,0" ToolTip="Up one folder (Backspace)"/>
                            <Button x:Name="BtnScan" Content="Scan" Style="{DynamicResource AccentButton}" MinWidth="80" Margin="8,0,0,0" ToolTip="Measure this folder (again)"/>
                            <Button x:Name="BtnStop" Content="Stop" Margin="8,0,0,0" IsEnabled="False"/>
                        </StackPanel>
                        <TextBox x:Name="TxtPath" VerticalContentAlignment="Center"/>
                    </DockPanel>
                    <TextBlock Grid.Row="1" x:Name="TxtScan" Foreground="{DynamicResource Muted}" Margin="0,8,0,8" TextTrimming="CharacterEllipsis"
                               Text="Pick This PC or a NAS, choose a folder and press Scan."/>
                    <Grid Grid.Row="2">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
                        <DockPanel Grid.Column="0">
                            <TextBlock DockPanel.Dock="Top" Text="Folders" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <ListView x:Name="LstFolders">
                                <ListView.ContextMenu>
                                    <ContextMenu>
                                        <MenuItem x:Name="MnuOpen" Header="Open"/>
                                        <MenuItem x:Name="MnuExplorer" Header="Open in Explorer"/>
                                        <MenuItem x:Name="MnuCopyFolder" Header="Copy path"/>
                                    </ContextMenu>
                                </ListView.ContextMenu>
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="Folder" Width="250">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                        <GridViewColumn Header="Size" Width="90">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}" TextAlignment="Right" Width="74"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                        <GridViewColumn Header="Share" Width="170">
                                            <GridViewColumn.CellTemplate>
                                                <DataTemplate>
                                                    <StackPanel Orientation="Horizontal">
                                                        <ProgressBar Value="{Binding Percent, Mode=OneWay}" Maximum="100" Width="100" Height="8" VerticalAlignment="Center"/>
                                                        <TextBlock Text="{Binding PercentText}" Margin="8,0,0,0" Foreground="{DynamicResource Muted}"/>
                                                    </StackPanel>
                                                </DataTemplate>
                                            </GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                        <GridViewColumn Header="Files" Width="90">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding FilesText}" TextAlignment="Right" Width="74"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                    </GridView>
                                </ListView.View>
                            </ListView>
                        </DockPanel>
                        <DockPanel Grid.Column="2">
                            <TextBlock x:Name="TxtFilesTitle" DockPanel.Dock="Top" Text="Largest files" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <ListView x:Name="LstFiles" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                                <ListView.ContextMenu>
                                    <ContextMenu>
                                        <MenuItem x:Name="MnuShowFile" Header="Show in Explorer"/>
                                        <MenuItem x:Name="MnuCopyFile" Header="Copy path"/>
                                    </ContextMenu>
                                </ListView.ContextMenu>
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="File" Width="200">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Path}"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                        <GridViewColumn Header="Size" Width="85">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}" TextAlignment="Right" Width="70"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                        <GridViewColumn Header="Folder" Width="260">
                                            <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Folder}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Folder}"/></DataTemplate></GridViewColumn.CellTemplate>
                                        </GridViewColumn>
                                    </GridView>
                                </ListView.View>
                            </ListView>
                        </DockPanel>
                    </Grid>
                </Grid>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@

function Set-RefreshTimer {
    $mins = Get-SettingNumber 'RefreshMinutes' 15
    $script:RefreshTimer.Stop()
    if ($mins -gt 0) {
        $script:RefreshTimer.Interval = [TimeSpan]::FromMinutes($mins)
        $script:RefreshTimer.Start()
    }
    Update-StatusLine
}

function Restore-WindowPlace($Window) {
    <# Size and position from last time, if it's still on a screen. #>
    $p = $script:Settings.Window
    if (-not $p) { return }
    try {
        $vs = [Windows.SystemParameters]
        $left = [double]$p.Left; $top = [double]$p.Top; $width = [double]$p.Width; $height = [double]$p.Height
        if ($width -ge $Window.MinWidth -and $height -ge $Window.MinHeight -and
            $left -ge $vs::VirtualScreenLeft - 20 -and $top -ge $vs::VirtualScreenTop - 20 -and
            $left + 100 -le $vs::VirtualScreenLeft + $vs::VirtualScreenWidth -and $top + 60 -le $vs::VirtualScreenTop + $vs::VirtualScreenHeight) {
            $Window.WindowStartupLocation = 'Manual'
            $Window.Left = $left; $Window.Top = $top; $Window.Width = $width; $Window.Height = $height
        }
        if ($p.Maximized) { $Window.WindowState = 'Maximized' }
    } catch { Write-AppLog "Window position not restored: $($_.Exception.Message)" }
}

function Save-WindowPlace($Window) {
    $b = $Window.RestoreBounds
    if ($b.Width -le 0) { return }
    $script:Settings.Window = [pscustomobject]@{ Left = $b.Left; Top = $b.Top; Width = $b.Width; Height = $b.Height; Maximized = ($Window.WindowState -eq 'Maximized') }
}

try {
    $window = New-XamlWindow $mainXaml
    $script:Ui = @{ Window = $window }
    foreach ($n in 'ImgLogo', 'BtnAdmin', 'BtnRefresh', 'BtnCopy', 'BtnSettings', 'BtnHelp', 'BtnAbout', 'TxtTitle', 'DotSummary', 'TxtSummary', 'TxtStatus',
        'Tabs', 'TabPc', 'SvPc', 'PanelPc', 'TabFolders', 'CmbWhere', 'BtnBrowse', 'BtnUp', 'BtnScan', 'BtnStop', 'TxtPath', 'TxtScan', 'LstFolders', 'LstFiles',
        'TxtFilesTitle', 'MnuOpen', 'MnuExplorer', 'MnuCopyFolder', 'MnuShowFile', 'MnuCopyFile') {
        $script:Ui[$n] = $window.FindName($n)
    }
    $u = $script:Ui
    $window.Title = if ($script:IsAdmin) { "$script:AppName v$script:AppVersion (administrator)" } else { "$script:AppName v$script:AppVersion" }
    $icon = Get-WindowIcon
    if ($icon) { $window.Icon = $icon }
    $u.ImgLogo.Source = Get-AssetImage 'Disk-NAS-Health.png'
    $u.TxtTitle.Text = $script:AppName
    if ($script:IsAdmin) { $u.BtnAdmin.Visibility = 'Collapsed' }
    $script:PcHeader = New-TabHeader 'This PC'
    $u.TabPc.Header = $script:PcHeader.Header
    [Windows.Automation.AutomationProperties]::SetName($u.TabPc, 'This PC')
    Restore-WindowPlace $window

    # Header buttons
    $u.BtnAdmin.Add_Click({ Restart-Elevated })
    $u.BtnRefresh.Add_Click({ Update-AllHealth })
    $u.BtnCopy.Add_Click({ Copy-Text (Get-ReportText); $script:Ui.TxtStatus.Text = 'Report copied to the clipboard.' })
    $u.BtnSettings.Add_Click({ Show-Settings })
    $u.BtnHelp.Add_Click({ Show-Help })
    $u.BtnAbout.Add_Click({ Show-About -Owner $script:Ui.Window })

    # Biggest folders
    $u.CmbWhere.Add_SelectionChanged({
            $new = [string]$script:Ui.CmbWhere.SelectedItem
            if (-not $new -or ($new -eq $script:Where -and $script:Ui.TxtPath.Text)) { return }
            Save-FolderPath
            $script:Where = $new
            $script:Current = ''
            $script:Ui.TxtPath.Text = Get-DefaultFolder $new
            $script:Ui.LstFolders.ItemsSource = $null
            $script:Ui.LstFiles.ItemsSource = $null
            $isPc = ($new -eq 'This PC')
            $script:Ui.BtnBrowse.IsEnabled = $isPc
            $script:Ui.MnuExplorer.IsEnabled = $isPc
            $script:Ui.TxtFilesTitle.Text = if ($isPc) { 'Largest files' } else { 'Largest files (this PC only)' }
            $script:Ui.TxtScan.Text = if ($isPc) { 'Choose a folder or drive and press Scan.' } else { "Choose a folder on $new (such as /volume1) and press Scan. It's measured with du over SSH." }
        })
    $u.BtnScan.Add_Click({ Start-FolderScan $script:Ui.TxtPath.Text -Force })
    $u.BtnStop.Add_Click({ Stop-FolderScan })
    $u.BtnUp.Add_Click({ Open-ParentFolder })
    $u.TxtPath.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-FolderScan $script:Ui.TxtPath.Text; $e.Handled = $true } })
    $u.BtnBrowse.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Folder or drive to measure'
            if ($script:Ui.TxtPath.Text -and (Test-Path -LiteralPath $script:Ui.TxtPath.Text)) { $dlg.SelectedPath = $script:Ui.TxtPath.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $script:Ui.TxtPath.Text = $dlg.SelectedPath; Start-FolderScan $dlg.SelectedPath -Force }
            $dlg.Dispose()
        })
    $u.LstFolders.Add_MouseDoubleClick({ Open-FolderRow $script:Ui.LstFolders.SelectedItem })
    $u.LstFolders.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return') { Open-FolderRow $script:Ui.LstFolders.SelectedItem; $e.Handled = $true }
            elseif ($e.Key -eq 'Back') { Open-ParentFolder; $e.Handled = $true }
        })
    $u.LstFiles.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Back') { Open-ParentFolder; $e.Handled = $true } })
    $u.LstFiles.Add_MouseDoubleClick({ $f = $script:Ui.LstFiles.SelectedItem; if ($f) { Open-InExplorer $f.Path -Select } })
    $u.MnuOpen.Add_Click({ Open-FolderRow $script:Ui.LstFolders.SelectedItem })
    $u.MnuExplorer.Add_Click({ $r = $script:Ui.LstFolders.SelectedItem; if ($r) { Open-InExplorer $r.Path } })
    $u.MnuCopyFolder.Add_Click({ $r = $script:Ui.LstFolders.SelectedItem; if ($r) { Copy-Text $r.Path } })
    $u.MnuShowFile.Add_Click({ $f = $script:Ui.LstFiles.SelectedItem; if ($f) { Open-InExplorer $f.Path -Select } })
    $u.MnuCopyFile.Add_Click({ $f = $script:Ui.LstFiles.SelectedItem; if ($f) { Copy-Text $f.Path } })

    # Keys for the whole window
    $window.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq 'F5') { Update-AllHealth; $e.Handled = $true }
            elseif ($e.Key -eq 'F1') { Show-Help; $e.Handled = $true }
        })

    # Timers: background results (UI thread), scan progress, and the automatic re-check
    $script:PollTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:PollTimer.Add_Tick({
            try { Update-Background; Update-ScanProgress }
            catch { Show-Problem "Something went wrong: $($_.Exception.Message)" }
        })
    $script:RefreshTimer = New-Object Windows.Threading.DispatcherTimer
    $script:RefreshTimer.Add_Tick({ Update-AllHealth })

    $window.Add_Closing({
            param($s, $e)
            Write-AppLog 'Closed.'
            if ($script:ScanState) { $script:ScanState.Cancel = $true }
            if ($script:SshControl) { $script:SshControl.Cancel = $true }
            Save-FolderPath
            Save-WindowPlace $s
            Save-AppSetting
        })
    $window.Add_ContentRendered({
            Initialize-MachineTab
            Show-PcHealth
            Set-RefreshTimer
            $script:PollTimer.Start()
            Update-AllHealth
        })

    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir$(if ($script:IsAdmin) { ' (administrator)' })"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
} finally {
    try { $script:PollTimer.Stop(); $script:RefreshTimer.Stop() } catch { Write-Verbose 'Timers already gone.' }
    try { $script:Pool.Close(); $script:Pool.Dispose() } catch { Write-Verbose 'Pool already closed.' }
}
