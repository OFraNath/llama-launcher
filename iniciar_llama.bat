@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
title Llama Launcher

set "LLAMA_ROOT=%~dp0"
set "LLAMA_BAT=%~f0"

if not exist "%~dp0llama-server.exe" (
    echo [ERRO] llama-server.exe não encontrado em "%~dp0".
    echo.
    pause
    exit /b 1
)

set "LLAMA_PS1=%TEMP%\llama_launcher_%RANDOM%%RANDOM%.ps1"
set "LLAMA_NEW=%TEMP%\llama_launcher_new_%RANDOM%%RANDOM%.bat"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$b=$env:LLAMA_BAT; $t=$env:LLAMA_PS1; try { $l=Get-Content -LiteralPath $b -Encoding UTF8; $i=[Array]::IndexOf($l,'#===PS1==='); if($i -lt 0){exit 2}; $l[($i+1)..($l.Count-1)] | Set-Content -LiteralPath $t -Encoding UTF8; exit 0 } catch { exit 3 }"
if errorlevel 1 (
    echo [ERRO] Falha ao preparar o launcher.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LLAMA_PS1%" %*
set "LLAMA_RC=%ERRORLEVEL%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "[Console]::CursorVisible=$true" >nul 2>&1
del /f /q "%LLAMA_PS1%" >nul 2>&1
if "%LLAMA_RC%"=="10" (
    copy /y "%LLAMA_NEW%" "%LLAMA_BAT%" >nul 2>&1 && (
        del /f /q "%LLAMA_NEW%" >nul 2>&1
        set "LLAMA_UPDATED=1"
        call "%LLAMA_BAT%" %*
        exit /b
    )
    del /f /q "%LLAMA_NEW%" >nul 2>&1
    echo.
    echo [ERRO] Não foi possível aplicar a atualização.
    pause
    exit /b 1
)
if not "%LLAMA_RC%"=="0" (
    echo.
    echo O launcher terminou com erro ^(código %LLAMA_RC%^).
    pause
)
exit /b %LLAMA_RC%
#===PS1===
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:Root = $env:LLAMA_ROOT
if ([string]::IsNullOrWhiteSpace($script:Root)) { $script:Root = Split-Path -Parent $PSCommandPath }
$script:Root = $script:Root.TrimEnd('\')
$script:ServerExe = Join-Path $script:Root 'llama-server.exe'
$script:ModelsDir = Join-Path $script:Root 'Modelos'
$script:StatePath = Join-Path $script:Root 'llama_launcher.json'
$script:CachePath = Join-Path $script:Root 'llama_launcher_cache.json'
$script:LogDir = Join-Path $script:Root 'logs'
$script:Hit = @{}
$script:FootHit = @()
$script:MouseOk = $false
$script:LastClick = [datetime]::MinValue
$script:Bench = @{}
$script:BenchRunning = $false
$script:BenchText = ''
$script:UpdateUrl = 'https://raw.githubusercontent.com/OFraNath/llama-launcher/HEAD/iniciar_llama.bat'
$script:UpdateExitCode = 10
$script:UpdateAvailable = $false
$script:UpdateBytes = $null
$script:ExitCode = 0

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Get-UIWidth {
    $w = 98
    try { $w = [Console]::WindowWidth - 2 } catch { }
    if ($w -lt 50) { $w = 50 }
    if ($w -gt 110) { $w = 110 }
    return $w
}

function Cut-Text {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -le 1) { return $Text.Substring(0, $Width) }
    return $Text.Substring(0, $Width - 1) + [char]0x2026
}

function Fit-Text {
    param([string]$Text, [int]$Width)
    $t = Cut-Text $Text $Width
    if ($t.Length -lt $Width) { $t = $t.PadRight($Width) }
    return $t
}

function Clear-Screen {
    $script:Hit = @{}
    $script:FootHit = @()
    try { [Console]::Clear() } catch { Clear-Host }
}

function Register-Hit {
    param([int]$Id)
    try { $script:Hit[[int][Console]::CursorTop] = $Id } catch { }
}

function Show-Header {
    param([string]$Title = '')
    $w = Get-UIWidth
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
    Write-Host '  LLAMA LAUNCHER' -NoNewline -ForegroundColor Cyan
    if ($Title) { Write-Host ('  |  ' + $Title) -ForegroundColor White } else { Write-Host '' }
    $sys = 'GPU não detectada'
    if ($script:Gpu -and $script:Gpu.Ok) {
        $sys = ('{0}  |  {1:0.0} GB VRAM livre' -f $script:Gpu.Name, ($script:Gpu.FreeMB / 1024.0))
    }
    if ($script:Mem) {
        $sys += ('  |  {0:0.0} GB RAM livre' -f ($script:Mem.FreeMB / 1024.0))
    }
    Write-Host ('  ' + (Cut-Text $sys ($w - 3))) -ForegroundColor DarkGray
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
}

function Write-Row {
    param([string]$Text, [bool]$Selected, [string]$Color = 'Gray')
    $w = Get-UIWidth
    $line = Fit-Text $Text $w
    if ($Selected) {
        Write-Host $line -ForegroundColor White -BackgroundColor DarkCyan
    } else {
        Write-Host $line -ForegroundColor $Color
    }
}

function Write-Footer {
    param([string]$Text)
    $parts = (Cut-Text $Text ((Get-UIWidth) - 1)) -split '   '
    $map = @{ 'Enter' = 'Enter'; 'Esc' = 'Escape'; '←→' = 'RightArrow'; 'L' = 'L'; 'E' = 'E'; 'R' = 'R'; 'A' = 'A'; 'Q' = 'Q' }
    $y = [int][Console]::CursorTop
    $x = 0
    $hits = @()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { Write-Host '   ' -NoNewline -ForegroundColor DarkGray; $x += 3 }
        if ($parts[$i] -match '^(\s*)(\S+)(.*)$') {
            $lead = $Matches[1]; $tok = $Matches[2]; $rest = $Matches[3]
            Write-Host $lead -NoNewline -ForegroundColor DarkGray
            $x += $lead.Length
            if ($map.ContainsKey($tok)) {
                $btn = ' ' + $tok + ' '
                $x1 = $x
                Write-Host $btn -NoNewline -ForegroundColor Black -BackgroundColor Cyan
                $x += $btn.Length
                Write-Host $rest -NoNewline -ForegroundColor Gray
                $x += $rest.Length
                $hits += [pscustomobject]@{ Y = $y; X1 = $x1; X2 = ($x - 1); Key = [string]$map[$tok] }
            } else {
                Write-Host $tok -NoNewline -ForegroundColor Cyan
                Write-Host $rest -NoNewline -ForegroundColor DarkGray
                $x += $tok.Length + $rest.Length
            }
        } else {
            Write-Host $parts[$i] -NoNewline -ForegroundColor DarkGray
            $x += $parts[$i].Length
        }
    }
    Write-Host ''
    $script:FootHit = $hits
}

# ---------------------------------------------------------------------------
# Mouse (Win32 console input)
# ---------------------------------------------------------------------------
function Initialize-Mouse {
    $src = @'
using System;
using System.Runtime.InteropServices;
public class LlamaEvt { public int Kind; public string Key; public char Ch; public int X; public int Y; }
public static class LlamaConsole {
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD {
        [FieldOffset(0)]  public ushort EventType;
        [FieldOffset(4)]  public int    bKeyDown;
        [FieldOffset(8)]  public ushort wRepeatCount;
        [FieldOffset(10)] public ushort wVirtualKeyCode;
        [FieldOffset(12)] public ushort wVirtualScanCode;
        [FieldOffset(14)] public ushort UnicodeChar;
        [FieldOffset(16)] public uint   dwControlKeyState;
        [FieldOffset(4)]  public short  MouseX;
        [FieldOffset(6)]  public short  MouseY;
        [FieldOffset(8)]  public uint   ButtonState;
        [FieldOffset(12)] public uint   MouseCtrlState;
        [FieldOffset(16)] public uint   EventFlags;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll", EntryPoint = "ReadConsoleInputW", SetLastError = true)]
    static extern bool ReadConsoleInput(IntPtr h, out INPUT_RECORD r, uint len, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);

    static IntPtr hIn = GetStdHandle(-10);
    static uint origMode;
    static bool haveOrig = false;
    static uint prevButtons = 0;

    public static bool Enable() {
        uint m;
        if (!GetConsoleMode(hIn, out m)) return false;
        if (!haveOrig) { origMode = m; haveOrig = true; }
        // ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS, sem QUICK_EDIT
        uint n = (m | 0x0010u | 0x0080u) & ~0x0040u;
        return SetConsoleMode(hIn, n);
    }
    public static void Disable() {
        if (haveOrig) SetConsoleMode(hIn, origMode);
    }
    static LlamaEvt Conv(INPUT_RECORD r) {
        if (r.EventType == 1) {
            if (r.bKeyDown == 0) return null;
            ushort vk = r.wVirtualKeyCode;
            if (vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x14 || vk == 0x90 || vk == 0x91) return null;
            LlamaEvt e = new LlamaEvt();
            e.Kind = 1; e.Key = ((ConsoleKey)vk).ToString(); e.Ch = (char)r.UnicodeChar;
            return e;
        }
        if (r.EventType == 2) {
            uint flags = r.EventFlags; uint b = r.ButtonState;
            if ((flags & 4) != 0) {
                short delta = unchecked((short)(b >> 16));
                LlamaEvt w = new LlamaEvt();
                w.Kind = (delta > 0) ? 4 : 5;
                return w;
            }
            uint pressed = b & ~prevButtons;
            prevButtons = b;
            if ((flags & (1u | 2u | 8u)) != 0) return null;
            LlamaEvt c = null;
            if ((pressed & 1u) != 0) { c = new LlamaEvt(); c.Kind = 2; }
            else if ((pressed & 2u) != 0) { c = new LlamaEvt(); c.Kind = 3; }
            if (c != null) { c.X = r.MouseX; c.Y = r.MouseY; return c; }
        }
        return null;
    }
    public static LlamaEvt Read() {
        while (true) {
            INPUT_RECORD r; uint n;
            if (!ReadConsoleInput(hIn, out r, 1, out n) || n == 0) return null;
            LlamaEvt e = Conv(r);
            if (e != null) return e;
        }
    }
    public static LlamaEvt TryRead() {
        uint cnt;
        while (GetNumberOfConsoleInputEvents(hIn, out cnt) && cnt > 0) {
            INPUT_RECORD r; uint n;
            if (!ReadConsoleInput(hIn, out r, 1, out n) || n == 0) return null;
            LlamaEvt e = Conv(r);
            if (e != null) return e;
        }
        return null;
    }
}
'@
    try {
        if (-not ('LlamaConsole' -as [type])) {
            Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        }
        $script:MouseOk = [bool][LlamaConsole]::Enable()
    } catch { $script:MouseOk = $false }
}

function Enable-Mouse  { if ($script:MouseOk) { try { [void][LlamaConsole]::Enable() } catch { } } }
function Disable-Mouse { if ($script:MouseOk) { try { [LlamaConsole]::Disable() } catch { } } }

function New-KeyObj {
    param([string]$Key, [char]$Ch = [char]0, [int]$Index = -1)
    return [pscustomobject]@{ Key = $Key; KeyChar = $Ch; Index = $Index }
}

function Read-Key {
    if (-not $script:MouseOk) {
        $k = [Console]::ReadKey($true)
        return (New-KeyObj ([string]$k.Key) $k.KeyChar)
    }
    while ($true) {
        $e = $null
        try { $e = [LlamaConsole]::Read() } catch { $e = $null }
        if ($null -eq $e) {
            Disable-Mouse
            $script:MouseOk = $false
            $k = [Console]::ReadKey($true)
            return (New-KeyObj ([string]$k.Key) $k.KeyChar)
        }
        if ($e.Kind -eq 1) { return (New-KeyObj $e.Key $e.Ch) }
        if ($e.Kind -eq 4) { return (New-KeyObj 'UpArrow') }
        if ($e.Kind -eq 5) { return (New-KeyObj 'DownArrow') }
        if ($e.Kind -eq 2 -or $e.Kind -eq 3) {
            $now = [datetime]::UtcNow
            if (($now - $script:LastClick).TotalMilliseconds -lt 300) { continue }
            $script:LastClick = $now
            if ($e.Kind -eq 2) {
                foreach ($b in @($script:FootHit)) {
                    if ([int]$e.Y -eq $b.Y -and [int]$e.X -ge $b.X1 -and [int]$e.X -le $b.X2) {
                        return (New-KeyObj $b.Key)
                    }
                }
            }
            $idx = -1
            if ($script:Hit.ContainsKey([int]$e.Y)) { $idx = [int]$script:Hit[[int]$e.Y] }
            if ($e.Kind -eq 2) { return (New-KeyObj 'MouseLeft' ([char]0) $idx) }
            return (New-KeyObj 'MouseRight' ([char]0) $idx)
        }
    }
}

function Initialize-Console {
    $wantW = 100
    $wantH = 46
    try {
        $raw = $Host.UI.RawUI
        $ws = $raw.WindowSize
        $max = $raw.MaxWindowSize
        $nw = [Math]::Min($max.Width, [Math]::Max($ws.Width, $wantW))
        $nh = [Math]::Min($max.Height, [Math]::Max($ws.Height, $wantH))
        if ($nw -ne $ws.Width -or $nh -ne $ws.Height) {
            try {
                $bs = $raw.BufferSize
                if ($bs.Width -lt $nw -or $bs.Height -lt $nh) {
                    $raw.BufferSize = New-Object System.Management.Automation.Host.Size -ArgumentList ([Math]::Max($bs.Width, $nw)), ([Math]::Max($bs.Height, $nh))
                }
            } catch { }
            $raw.WindowSize = New-Object System.Management.Automation.Host.Size -ArgumentList $nw, $nh
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Hardware / environment
# ---------------------------------------------------------------------------
function Get-GpuInfo {
    $r = [ordered]@{ Name = 'GPU não detectada'; TotalMB = 0; FreeMB = 0; Ok = $false }
    try {
        $out = & nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $line = @($out)[0]
            $p = $line -split ','
            if ($p.Count -ge 3) {
                $r.Name = $p[0].Trim()
                $r.TotalMB = [int]([double]$p[1].Trim())
                $r.FreeMB = [int]([double]$p[2].Trim())
                $r.Ok = $true
            }
        }
    } catch { }
    return [pscustomobject]$r
}

function Get-MemInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        return [pscustomobject]@{
            TotalMB = [int]($os.TotalVisibleMemorySize / 1024)
            FreeMB  = [int]($os.FreePhysicalMemory / 1024)
        }
    } catch {
        return [pscustomobject]@{ TotalMB = 0; FreeMB = 0 }
    }
}

function Update-Hardware {
    $script:Gpu = Get-GpuInfo
    $script:Mem = Get-MemInfo
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Network detection
# ---------------------------------------------------------------------------
$script:LanIPv4Cache = $null
$script:TailscaleIPv4Cache = $null
$script:LanIPv4Try = [datetime]::MinValue
$script:TailscaleIPv4Try = [datetime]::MinValue

function Test-LanIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -eq '0.0.0.0' -or $Ip -eq '255.255.255.255') { return $false }
    if ($Ip -match '^(127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)') { return $false }
    return $true
}

function Get-LanIPv4 {
    if ($script:LanIPv4Cache) { return [string]$script:LanIPv4Cache }
    if (((Get-Date) - $script:LanIPv4Try).TotalSeconds -lt 5) { return '' }
    $script:LanIPv4Try = Get-Date

    $sock = $null
    try {
        $sock = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        $sock.Connect('8.8.8.8', 65530)
        $ip = $sock.LocalEndPoint.Address.IPAddressToString
        if (Test-LanIPv4 $ip) {
            $script:LanIPv4Cache = $ip
            return $ip
        }
    } catch { } finally {
        if ($sock) { try { $sock.Close() } catch { } }
    }

    try {
        $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' -and
            $_.InterfaceAlias -notmatch '(?i)tailscale|loopback|hyper-v|wsl|docker|virtualbox|vmware|vbox'
        })
        if ($addrs.Count -gt 0) {
            $pick = $addrs | Sort-Object @{ Expression = {
                if ($_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)') { 0 } else { 1 }
            } }, InterfaceIndex | Select-Object -First 1
            if ($pick) { $script:LanIPv4Cache = [string]$pick.IPAddress }
        }
    } catch { }
    return [string]$script:LanIPv4Cache
}

function Get-TailscaleIPv4 {
    if ($script:TailscaleIPv4Cache) { return [string]$script:TailscaleIPv4Cache }
    if (((Get-Date) - $script:TailscaleIPv4Try).TotalSeconds -lt 5) { return '' }
    $script:TailscaleIPv4Try = Get-Date

    try {
        $addr = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.InterfaceAlias -eq 'Tailscale' -and $_.IPAddress -match '^100\.'
        }) | Select-Object -First 1
        if ($addr) {
            $script:TailscaleIPv4Cache = [string]$addr.IPAddress
            return [string]$script:TailscaleIPv4Cache
        }
    } catch { }

    try {
        $exe = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exe) {
            $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
            if (Test-Path -LiteralPath $candidate) {
                $exe = [pscustomobject]@{ Source = $candidate }
            }
        }
        if ($exe) {
            $out = @(& $exe.Source ip -4 2>$null)
            foreach ($line in $out) {
                $ip = ([string]$line).Trim()
                if ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') {
                    $script:TailscaleIPv4Cache = $ip
                    break
                }
            }
        }
    } catch { }
    return [string]$script:TailscaleIPv4Cache
}

function Get-BindHost {
    param([string]$HostValue)
    if ($HostValue -eq 'tailscale') { return '0.0.0.0' }
    return $HostValue
}

function Get-ServerAccessUrl {
    param([string]$HostValue, [int]$Port)
    if ($HostValue -eq 'tailscale') {
        $ip = Get-TailscaleIPv4
        if ($ip) { return ('http://{0}:{1}' -f $ip, $Port) }
        return ''
    }
    if ($HostValue -eq '0.0.0.0') {
        $ip = Get-LanIPv4
        if ($ip) { return ('http://{0}:{1}' -f $ip, $Port) }
        return ''
    }
    return ('http://127.0.0.1:{0}' -f $Port)
}

# ---------------------------------------------------------------------------
# GGUF metadata reader
# ---------------------------------------------------------------------------
function Read-GGUFString {
    param($Reader)
    $len = $Reader.ReadUInt64()
    if ($len -gt 16777216) { throw "String GGUF muito grande: $len bytes" }
    $bytes = $Reader.ReadBytes([int]$len)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-GGUFTypeSize {
    param([uint32]$Type)
    switch ($Type) {
        0 { return 1 }
        1 { return 1 }
        2 { return 2 }
        3 { return 2 }
        4 { return 4 }
        5 { return 4 }
        6 { return 4 }
        7 { return 1 }
        10 { return 8 }
        11 { return 8 }
        12 { return 8 }
        default { return 0 }
    }
}

function Skip-GGUFValue {
    param($Reader, [uint32]$Type)
    switch ($Type) {
        0 { [void]$Reader.ReadByte() }
        1 { [void]$Reader.ReadSByte() }
        2 { [void]$Reader.ReadUInt16() }
        3 { [void]$Reader.ReadInt16() }
        4 { [void]$Reader.ReadUInt32() }
        5 { [void]$Reader.ReadInt32() }
        6 { [void]$Reader.ReadSingle() }
        7 { [void]$Reader.ReadBoolean() }
        8 {
            $len = $Reader.ReadUInt64()
            [void]$Reader.BaseStream.Seek([int64]$len, [System.IO.SeekOrigin]::Current)
        }
        9 {
            $etype = $Reader.ReadUInt32()
            $count = $Reader.ReadUInt64()
            $size = Get-GGUFTypeSize $etype
            if ($size -gt 0) {
                [void]$Reader.BaseStream.Seek(([int64]$size * [int64]$count), [System.IO.SeekOrigin]::Current)
            } else {
                $n = [int64]$count
                for ($i = 0; $i -lt $n; $i++) { Skip-GGUFValue $Reader $etype }
            }
        }
        10 { [void]$Reader.ReadUInt64() }
        11 { [void]$Reader.ReadInt64() }
        12 { [void]$Reader.ReadDouble() }
        default { throw "Tipo GGUF desconhecido: $Type" }
    }
}

function Read-GGUFValue {
    param($Reader, [uint32]$Type)
    switch ($Type) {
        0 { return [uint32]($Reader.ReadByte()) }
        1 { return [int32]($Reader.ReadSByte()) }
        2 { return [uint32]($Reader.ReadUInt16()) }
        3 { return [int32]($Reader.ReadInt16()) }
        4 { return [uint32]($Reader.ReadUInt32()) }
        5 { return [int32]($Reader.ReadInt32()) }
        6 { return [single]($Reader.ReadSingle()) }
        7 { return [bool]($Reader.ReadBoolean()) }
        8 { return (Read-GGUFString $Reader) }
        9 {
            $etype = $Reader.ReadUInt32()
            $count = $Reader.ReadUInt64()
            $arr = New-Object System.Collections.ArrayList
            $n = [int64]$count
            for ($i = 0; $i -lt $n; $i++) {
                [void]$arr.Add((Read-GGUFValue $Reader $etype))
            }
            return ,$arr.ToArray()
        }
        10 { return [uint64]($Reader.ReadUInt64()) }
        11 { return [int64]($Reader.ReadInt64()) }
        12 { return [double]($Reader.ReadDouble()) }
        default { throw "Tipo GGUF desconhecido: $Type" }
    }
}

function Read-GGUF-Meta {
    param([string]$Path)
    $info = [ordered]@{
        Arch        = ''
        Name        = ''
        Layers      = 0
        HeadCount   = 0
        KvHeads     = @()
        HeadDimK    = 0
        HeadDimV    = 0
        Experts     = 0
        ExpertsUsed = 0
        MaxCtx      = 0
        HasThinking = $false
        ParseOk     = $false
        ParseError  = ''
    }
    $fs = $null
    $br = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)
        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'GGUF') { throw 'Arquivo não é GGUF.' }
        $ver = $br.ReadUInt32()
        if ($ver -lt 1 -or $ver -gt 4) { throw "Versão GGUF não suportada: $ver" }
        [void]$br.ReadUInt64()
        $kvCount = [int64]$br.ReadUInt64()

        $arch = ''
        $name = ''
        $tpl = ''
        $fields = @{}
        $limit = $kvCount
        if ($limit -gt 600) { $limit = 600 }

        for ($i = 0; $i -lt $limit; $i++) {
            $key = Read-GGUFString $br
            $type = $br.ReadUInt32()
            if ($key -eq 'tokenizer.ggml.tokens') { break }

            $isTarget = ($key -eq 'general.architecture' -or $key -eq 'general.name' -or
                         $key -eq 'tokenizer.chat_template' -or $key -eq 'tokenizer.chat_templates' -or
                         $key -match '\.(block_count|attention\.head_count|attention\.head_count_kv|embedding_length|attention\.key_length|attention\.value_length|expert_count|expert_used_count|context_length)$')

            if ($isTarget) {
                $val = Read-GGUFValue $br $type
                if ($key -eq 'general.architecture') {
                    $arch = [string]$val
                } elseif ($key -eq 'general.name') {
                    $name = [string]$val
                } elseif ($key -eq 'tokenizer.chat_template') {
                    $tpl = [string]$val
                } elseif ($key -eq 'tokenizer.chat_templates') {
                    if ($val -is [System.Array]) { $tpl = ($val -join "`n") } else { $tpl = [string]$val }
                } else {
                    $fields[$key] = $val
                }
            } else {
                Skip-GGUFValue $br $type
            }
        }

        $info.Arch = $arch
        $info.Name = $name
        if ($arch) {
            $k = "$arch.block_count"
            if ($fields.ContainsKey($k)) { $info.Layers = [int]$fields[$k] }

            $k = "$arch.attention.head_count"
            if ($fields.ContainsKey($k)) { $info.HeadCount = [int]$fields[$k] }

            $k = "$arch.embedding_length"
            $embd = 0
            if ($fields.ContainsKey($k)) { $embd = [int]$fields[$k] }

            $k = "$arch.attention.head_count_kv"
            if ($fields.ContainsKey($k)) {
                $kv = $fields[$k]
                if ($kv -is [System.Array]) {
                    $info.KvHeads = @($kv | ForEach-Object { [int]$_ })
                } else {
                    $info.KvHeads = @([int]$kv)
                }
            }

            $k = "$arch.attention.key_length"
            if ($fields.ContainsKey($k)) { $info.HeadDimK = [int]$fields[$k] }
            elseif ($info.HeadCount -gt 0 -and $embd -gt 0) { $info.HeadDimK = [int]($embd / $info.HeadCount) }

            $k = "$arch.attention.value_length"
            if ($fields.ContainsKey($k)) { $info.HeadDimV = [int]$fields[$k] }
            elseif ($info.HeadDimK -gt 0) { $info.HeadDimV = $info.HeadDimK }

            $k = "$arch.expert_count"
            if ($fields.ContainsKey($k)) { $info.Experts = [int]$fields[$k] }

            $k = "$arch.expert_used_count"
            if ($fields.ContainsKey($k)) { $info.ExpertsUsed = [int]$fields[$k] }

            $k = "$arch.context_length"
            if ($fields.ContainsKey($k)) { $info.MaxCtx = [int]$fields[$k] }
        }
        $info.HasThinking = [bool]($tpl -match '(?i)enable_thinking|thinking|reasoning')
        $info.ParseOk = $true
    } catch {
        $info.ParseError = $_.Exception.Message
    } finally {
        if ($br) { try { $br.Dispose() } catch { } }
        if ($fs) { try { $fs.Dispose() } catch { } }
    }
    return [pscustomobject]$info
}

# ---------------------------------------------------------------------------
# Model discovery / cache
# ---------------------------------------------------------------------------
function Get-ModelQuant {
    param([string]$Name)
    if ($Name -match '(?i)(IQ\d+_[A-Z0-9_]+|Q\d+_[A-Z0-9_]+|Q\d+_\d+|BF16|F16|F32)') {
        return $Matches[1].ToUpperInvariant()
    }
    return ''
}

function Get-Models {
    $cache = Read-JsonFile $script:CachePath
    $cacheMap = @{}
    if ($cache -and $cache.models) {
        foreach ($e in @($cache.models)) {
            if ($e.path) { $cacheMap[[string]$e.path] = $e }
        }
    }

    if (-not (Test-Path -LiteralPath $script:ModelsDir)) { return @() }
    $all = @(Get-ChildItem -LiteralPath $script:ModelsDir -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue)
    $mmAll = @($all | Where-Object { $_.Name -match '(?i)^mmproj' })
    $mains = @($all | Where-Object {
        $_.Name -notmatch '(?i)^mmproj' -and
        ($_.Name -notmatch '(?i)-\d{5}-of-\d{5}\.gguf$' -or $_.Name -match '(?i)-00001-of-\d{5}\.gguf$')
    })

    $dirCounts = @{}
    foreach ($f in $mains) {
        if ($dirCounts.ContainsKey($f.DirectoryName)) {
            $dirCounts[$f.DirectoryName] = [int]$dirCounts[$f.DirectoryName] + 1
        } else {
            $dirCounts[$f.DirectoryName] = 1
        }
    }

    $newCache = New-Object System.Collections.ArrayList
    $models = New-Object System.Collections.ArrayList

    foreach ($f in $mains) {
        $entry = $cacheMap[$f.FullName]
        $mtime = $f.LastWriteTimeUtc.Ticks
        $meta = $null
        if ($entry -and $entry.meta -and [int64]$entry.length -eq $f.Length -and [int64]$entry.mtime -eq $mtime) {
            $meta = $entry.meta
        } else {
            $meta = Read-GGUF-Meta $f.FullName
        }

        $mm = @($mmAll | Where-Object { $_.DirectoryName -eq $f.DirectoryName } | Sort-Object Length -Descending)
        $mmproj = $null
        if ($mm.Count -gt 0) { $mmproj = $mm[0] }

        if (-not $meta.HasThinking -and ($meta.Arch -match '(?i)^qwen3' -or $f.Name -match '(?i)think|reason')) {
            $meta.HasThinking = $true
        }

        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $display = $base
        if ([int]$dirCounts[$f.DirectoryName] -le 1) {
            $display = Split-Path -Parent $f.FullName | Split-Path -Leaf
        }

        $quant = Get-ModelQuant $f.Name
        if (-not $quant) { $quant = Get-ModelQuant $display }

        [void]$models.Add([pscustomobject]@{
            Path      = $f.FullName
            Folder    = (Split-Path -Parent $f.FullName | Split-Path -Leaf)
            FileName  = $f.Name
            Display   = $display
            Size      = [int64]$f.Length
            Quant     = $quant
            Meta      = $meta
            Mmproj    = $mmproj
            HasVision = ($null -ne $mmproj)
        })

        [void]$newCache.Add([pscustomobject]@{
            path   = $f.FullName
            length = [int64]$f.Length
            mtime  = [int64]$mtime
            meta   = $meta
        })
    }

    try {
        [pscustomobject]@{ models = @($newCache) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:CachePath -Encoding UTF8
    } catch { }

    return @($models | Sort-Object Display, Path)
}

function Get-ModelTypeLabel {
    param($Model)
    if ($Model.Meta -and [int]$Model.Meta.Experts -gt 0) {
        if ([int]$Model.Meta.ExpertsUsed -gt 0) {
            return ('MoE {0}/{1}' -f [int]$Model.Meta.ExpertsUsed, [int]$Model.Meta.Experts)
        }
        return 'MoE'
    }
    return 'denso'
}

function Format-Tokens {
    param([int]$N)
    if ($N -ge 1024) { return ('{0:0.#}K' -f ($N / 1024.0)) }
    return [string]$N
}

function Format-GB {
    param([double]$Bytes)
    return ('{0:0.0} GB' -f ($Bytes / 1GB))
}

# ---------------------------------------------------------------------------
# KV cache / memory estimates
# ---------------------------------------------------------------------------
function Get-BytesPerElement {
    param([string]$Type)
    if (-not $Type) { return 2.0 }
    switch ($Type.ToLowerInvariant()) {
        'f32'   { return 4.0 }
        'f16'   { return 2.0 }
        'bf16'  { return 2.0 }
        'q8_0'  { return (34.0 / 32.0) }
        'q4_0'  { return (18.0 / 32.0) }
        'q4_1'  { return (20.0 / 32.0) }
        'iq4_nl'{ return (18.0 / 32.0) }
        'q5_0'  { return (22.0 / 32.0) }
        'q5_1'  { return (24.0 / 32.0) }
        default { return 2.0 }
    }
}

function Get-KvBytesPerToken {
    param($Meta, [string]$Ctk, [string]$Ctv)
    $layers = 40
    $headDimK = 128
    $headDimV = 128
    $headCount = 8
    $heads = @()
    if ($Meta) {
        if ([int]$Meta.Layers -gt 0) { $layers = [int]$Meta.Layers }
        if ([int]$Meta.HeadDimK -gt 0) { $headDimK = [int]$Meta.HeadDimK }
        if ([int]$Meta.HeadDimV -gt 0) { $headDimV = [int]$Meta.HeadDimV } else { $headDimV = $headDimK }
        if ([int]$Meta.HeadCount -gt 0) { $headCount = [int]$Meta.HeadCount }
        $heads = @($Meta.KvHeads)
    }
    $sumK = 0.0
    $sumV = 0.0
    for ($i = 0; $i -lt $layers; $i++) {
        $h = 0
        if ($heads.Count -gt 0) {
            if ($i -lt $heads.Count) { $h = [int]$heads[$i] } else { $h = [int]$heads[$heads.Count - 1] }
        }
        if ($h -le 0) { $h = $headCount }
        if ($h -le 0) { $h = 8 }
        $sumK += $h * $headDimK
        $sumV += $h * $headDimV
    }
    $bytes = ($sumK * (Get-BytesPerElement $Ctk)) + ($sumV * (Get-BytesPerElement $Ctv))
    return ($bytes * 1.03)
}

function Get-KvGB {
    param($Meta, [int]$Ctx, [string]$Ctk, [string]$Ctv)
    if ($Ctx -le 0) { return 0.0 }
    return ((Get-KvBytesPerToken $Meta $Ctk $Ctv) * $Ctx) / 1GB
}

function Get-MaxCtx {
    param($Model)
    if ($Model -and $Model.Meta -and [int]$Model.Meta.MaxCtx -gt 0) { return [int]$Model.Meta.MaxCtx }
    return 32768
}

function Get-MemoryEstimate {
    param($Cfg)
    $m = $Cfg.Model
    $weights = $m.Size / 1GB
    $kv = Get-KvGB $m.Meta $Cfg.Ctx $Cfg.Ctk $Cfg.Ctv
    $mmVram = 0.0
    $mmRam = 0.0
    if ($Cfg.Vision -eq 'gpu' -and $m.Mmproj) { $mmVram = $m.Mmproj.Length / 1GB }
    if ($Cfg.Vision -eq 'cpu' -and $m.Mmproj) { $mmRam = $m.Mmproj.Length / 1GB }

    $freeV = 0.0
    if ($script:Gpu -and $script:Gpu.Ok) { $freeV = $script:Gpu.FreeMB / 1024.0 }
    $freeR = 0.0
    if ($script:Mem) { $freeR = $script:Mem.FreeMB / 1024.0 }

    $needV = $weights + $kv + $mmVram + 0.75
    $needR = $weights + $kv + $mmRam + 1.0

    $level = 'bad'
    $text = 'Memória desconhecida'
    if (-not $script:Gpu -or -not $script:Gpu.Ok) {
        $level = 'bad'
        $text = 'GPU não detectada'
    } elseif ($Cfg.Ngl -eq '0') {
        $level = 'dim'
        $text = 'Somente CPU'
    } elseif ($Cfg.Ngl -eq 'all') {
        if ($needV -le ($freeV - 0.50)) {
            $level = 'good'
            $text = 'Cabe inteiro na GPU'
        } else {
            $level = 'bad'
            $text = 'VRAM insuficiente para todas as camadas'
        }
    } elseif ($Cfg.Ngl -match '^\d+$') {
        $nTotal = Get-NglMax $m
        $nGpu = [Math]::Min([int]$Cfg.Ngl, $nTotal)
        $frac = $nGpu / [double]$nTotal
        $partV = (($weights + $kv) * $frac) + $mmVram + 0.75
        $partR = (($weights + $kv) * (1.0 - $frac)) + $mmRam + 1.0
        if ($partV -gt ($freeV - 0.50)) {
            $level = 'bad'
            $text = ('VRAM insuficiente para {0} camadas' -f $nGpu)
        } elseif ($partR -gt ($freeR - 1.5)) {
            $level = 'bad'
            $text = 'RAM apertada'
        } else {
            if ($nGpu -ge $nTotal) {
                $level = 'good'
                $text = 'Todas as camadas na GPU'
            } else {
                $level = 'warn'
                $text = ('{0}/{1} camadas na GPU + resto na CPU/RAM' -f $nGpu, $nTotal)
            }
        }
    } else {
        if ($needV -le ($freeV - 0.75)) {
            $level = 'good'
            $text = 'Cabe inteiro na GPU'
        } elseif ($needR -le ($freeR - 1.5)) {
            $level = 'warn'
            $text = 'Offload parcial automático'
        } else {
            $level = 'bad'
            $text = 'RAM apertada'
        }
    }

    return [pscustomobject]@{
        WeightsGB = $weights
        KvGB      = $kv
        MmprojGB  = ($mmVram + $mmRam)
        NeedVram  = $needV
        NeedRam   = $needR
        FreeVram  = $freeV
        FreeRam   = $freeR
        Level     = $level
        Text      = $text
    }
}

function Get-ModelStatusShort {
    param($Model)
    $ctx = 8192
    $max = Get-MaxCtx $Model
    if ($max -lt $ctx) { $ctx = $max }
    $cfg = [pscustomobject]@{ Model = $Model; Ctx = $ctx; Ctk = 'q8_0'; Ctv = 'q8_0'; Ngl = 'auto'; Vision = 'off' }
    $e = Get-MemoryEstimate $cfg
    switch ($e.Level) {
        'good' { return 'cabe na GPU' }
        'warn' { return 'offload parcial' }
        'dim'  { return 'CPU' }
        default {
            if (-not $script:Gpu -or -not $script:Gpu.Ok) { return 'GPU?' }
            return 'RAM apertada'
        }
    }
}

# ---------------------------------------------------------------------------
# Settings / presets
# ---------------------------------------------------------------------------
$script:KvOptions = @(
    [pscustomobject]@{ Ctk = 'f16';  Ctv = 'f16';  Label = 'f16 / f16  (máx. qualidade)' },
    [pscustomobject]@{ Ctk = 'q8_0'; Ctv = 'q8_0'; Label = 'q8_0 / q8_0  (recomendado)' },
    [pscustomobject]@{ Ctk = 'q8_0'; Ctv = 'q4_0'; Label = 'q8_0 K / q4_0 V  (equilibrado)' },
    [pscustomobject]@{ Ctk = 'q4_0'; Ctv = 'q4_0'; Label = 'q4_0 / q4_0  (máx. economia)' }
)

function Get-CtxOptions {
    param($Model)
    $max = Get-MaxCtx $Model
    $base = @(1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576)
    $opts = @($base | Where-Object { $_ -le $max })
    if ($max -gt 0 -and $opts -notcontains $max) { $opts = @($opts + $max | Sort-Object) }
    if ($opts.Count -eq 0) { $opts = @([Math]::Max(512, $max)) }
    return $opts
}

function Get-AutoBatch {
    param($Model, [int]$Ctx, [string]$Ctk, [string]$Ctv, [string]$Ngl, [double]$MinHeadroom)
    if (-not $script:Gpu -or -not $script:Gpu.Ok -or $Ngl -eq '0') { return 'auto' }
    $freeV = $script:Gpu.FreeMB / 1024.0
    $need = ($Model.Size / 1GB) + (Get-KvGB $Model.Meta $Ctx $Ctk $Ctv) + 0.75
    if (($freeV - $need) -ge $MinHeadroom) { return '1024' }
    return 'auto'
}

function Get-PhysicalCores {
    if ($null -ne $script:PhysCores) { return [int]$script:PhysCores }
    $n = 0
    try {
        $sum = (@(Get-CimInstance Win32_Processor -ErrorAction Stop) | Measure-Object -Property NumberOfCores -Sum).Sum
        if ($sum) { $n = [int]$sum }
    } catch { }
    $script:PhysCores = $n
    return $n
}

function Get-RecommendedCfg {
    param($Model)
    $maxCtx = Get-MaxCtx $Model
    $ctx = 8192
    if ($maxCtx -lt $ctx) { $ctx = $maxCtx }
    if ($ctx -lt 512) { $ctx = $maxCtx }

    $freeV = 0.0
    if ($script:Gpu -and $script:Gpu.Ok) { $freeV = $script:Gpu.FreeMB / 1024.0 }
    $weights = $Model.Size / 1GB
    if ($maxCtx -ge 16384 -and $freeV -gt 0) {
        $kv16 = Get-KvGB $Model.Meta 16384 'q8_0' 'q8_0'
        if (($weights + $kv16 + 0.75) -le ($freeV - 0.75)) { $ctx = 16384 }
    }

    return [pscustomobject]@{
        Model      = $Model
        Preset     = 'recomendado'
        Ctx        = [int]$ctx
        Ctk        = 'q8_0'
        Ctv        = 'q8_0'
        NPredict   = -1
        Ngl        = 'auto'
        Vision     = 'off'
        Reasoning  = 'auto'
        Template   = 'auto'
        Threads    = 'auto'
        CacheRam   = 'auto'
        Batch      = (Get-AutoBatch $Model $ctx 'q8_0' 'q8_0' 'auto' 3.0)
        Port       = [int]$script:Global.Port
        Host       = [string]$script:Global.Host
        Browser    = [string]$script:Global.Browser
        Agent      = [string]$script:Global.Agent
        Research   = [string]$script:Global.Research
        Image      = [string]$script:Global.Image
        ImagePath  = [string]$script:Global.ImagePath
    }
}

function Apply-Preset {
    param($Cfg, [string]$Name)
    $maxCtx = Get-MaxCtx $Cfg.Model
    switch ($Name) {
        'recomendado' {
            $r = Get-RecommendedCfg $Cfg.Model
            $Cfg.Ctx = $r.Ctx
            $Cfg.Ctk = $r.Ctk
            $Cfg.Ctv = $r.Ctv
            $Cfg.Ngl = $r.Ngl
            $Cfg.NPredict = $r.NPredict
            $Cfg.Threads = 'auto'
            $Cfg.CacheRam = 'auto'
            $Cfg.Batch = $r.Batch
        }
        'qualidade' {
            $Cfg.Ctx = [Math]::Min(8192, $maxCtx)
            $Cfg.Ctk = 'f16'
            $Cfg.Ctv = 'f16'
            $Cfg.Ngl = 'auto'
            $Cfg.NPredict = -1
            $Cfg.Threads = 'auto'
            $Cfg.CacheRam = 'auto'
            $Cfg.Batch = 'auto'
        }
        'longo' {
            $Cfg.Ctx = [Math]::Min(32768, $maxCtx)
            $Cfg.Ctk = 'q4_0'
            $Cfg.Ctv = 'q4_0'
            $Cfg.Ngl = 'auto'
            $Cfg.NPredict = -1
            $Cfg.Threads = 'auto'
            $Cfg.CacheRam = 'auto'
            $Cfg.Batch = (Get-AutoBatch $Cfg.Model $Cfg.Ctx $Cfg.Ctk $Cfg.Ctv $Cfg.Ngl 1.5)
        }
        'cpu' {
            $Cfg.Ctx = [Math]::Min(8192, $maxCtx)
            $Cfg.Ctk = 'q8_0'
            $Cfg.Ctv = 'q8_0'
            $Cfg.Ngl = '0'
            $Cfg.NPredict = -1
            $Cfg.Threads = 'auto'
            $phys = Get-PhysicalCores
            if ($phys -ge 1) { $Cfg.Threads = [string]$phys }
            $Cfg.CacheRam = 'auto'
            $Cfg.Batch = 'auto'
        }
    }
    $Cfg.Preset = $Name
    Normalize-Cfg $Cfg
}

function Normalize-Cfg {
    param($Cfg)
    $maxCtx = Get-MaxCtx $Cfg.Model
    if ($Cfg.Ctx -le 0) { $Cfg.Ctx = 8192 }
    if ($Cfg.Ctx -gt $maxCtx) { $Cfg.Ctx = $maxCtx }
    if ($Cfg.Ctx -lt 1) { $Cfg.Ctx = 1 }

    $validKv = @('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')
    if ($validKv -notcontains [string]$Cfg.Ctk) { $Cfg.Ctk = 'q8_0' }
    if ($validKv -notcontains [string]$Cfg.Ctv) { $Cfg.Ctv = 'q8_0' }
    $nglStr = ([string]$Cfg.Ngl).Trim()
    if (@('auto', '0', 'all') -contains $nglStr) {
        $Cfg.Ngl = $nglStr
    } elseif ($nglStr -match '^\d{1,4}$') {
        $nglN = [int]$nglStr
        $nglMax = Get-NglMax $Cfg.Model
        if ($nglN -gt $nglMax) { $nglN = $nglMax }
        $Cfg.Ngl = [string]$nglN
    } else {
        $Cfg.Ngl = 'auto'
    }
    if (@('off', 'gpu', 'cpu') -notcontains [string]$Cfg.Vision) { $Cfg.Vision = 'off' }
    if (-not $Cfg.Model.Mmproj) { $Cfg.Vision = 'off' }
    if (@('auto', 'on', 'off') -notcontains [string]$Cfg.Reasoning) { $Cfg.Reasoning = 'auto' }
    if (-not $Cfg.Model.Meta.HasThinking) { $Cfg.Reasoning = 'auto' }
    if (@('auto', 'chatml') -notcontains [string]$Cfg.Template) { $Cfg.Template = 'auto' }
    $thrStr = ([string]$Cfg.Threads).Trim()
    if ($thrStr -match '^\d{1,3}$' -and [int]$thrStr -ge 1) {
        $thrN = [int]$thrStr
        $thrMax = Get-ThreadsMax
        if ($thrN -gt $thrMax) { $thrN = $thrMax }
        $Cfg.Threads = [string]$thrN
    } else {
        $Cfg.Threads = 'auto'
    }
    if (@('auto', 'off') -notcontains [string]$Cfg.CacheRam) { $Cfg.CacheRam = 'auto' }
    $batStr = ([string]$Cfg.Batch).Trim()
    if ($batStr -match '^\d{1,4}$' -and [int]$batStr -ge 1) {
        $batN = [int]$batStr
        if ($batN -gt 8192) { $batN = 8192 }
        $Cfg.Batch = [string]$batN
    } else {
        $Cfg.Batch = 'auto'
    }
    if (@('recomendado', 'qualidade', 'longo', 'cpu', 'personalizado') -notcontains [string]$Cfg.Preset) { $Cfg.Preset = 'personalizado' }
    if ([int]$Cfg.Port -lt 1 -or [int]$Cfg.Port -gt 65535) { $Cfg.Port = 5001 }
    if (@('127.0.0.1', '0.0.0.0', 'tailscale') -notcontains [string]$Cfg.Host) { $Cfg.Host = '127.0.0.1' }
    if (@('llamacpp', 'openwebui', 'none') -notcontains [string]$Cfg.Browser) { $Cfg.Browser = 'llamacpp' }
    if (@('off', 'on') -notcontains [string]$Cfg.Agent) { $Cfg.Agent = 'off' }
    if (@('off', 'on') -notcontains [string]$Cfg.Research) { $Cfg.Research = 'off' }
    $Cfg.ImagePath = ConvertTo-ImagePath ([string]$Cfg.ImagePath)
    if (@('off', 'on') -notcontains [string]$Cfg.Image) { $Cfg.Image = 'off' }
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) {
        $Cfg.ImagePath = ''
        $Cfg.Image = 'off'
    }
    if ([int]$Cfg.NPredict -lt -1) { $Cfg.NPredict = -1 }
    if ([int]$Cfg.NPredict -gt 32768) { $Cfg.NPredict = 32768 }
}

# ---------------------------------------------------------------------------
# Persistent state
# ---------------------------------------------------------------------------
$script:Global = [pscustomobject]@{ port = 5001; host = '127.0.0.1'; browser = 'llamacpp'; agent = 'off'; research = 'off'; image = 'off'; imagePath = '' }
$script:StateModels = @{}
$script:LastModelPath = ''
$script:LastCfg = $null
$script:SessionCfg = @{}
$script:Models = @()
$script:Research = $null
$script:Image = $null

function Get-PropValue {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Initialize-State {
    $raw = Read-JsonFile $script:StatePath
    if ($raw) {
        $g = Get-PropValue $raw 'global' $null
        if ($g) {
            $port = Get-PropValue $g 'port' 5001
            if ([int]$port -ge 1 -and [int]$port -le 65535) { $script:Global.Port = [int]$port }
            $hostValue = [string](Get-PropValue $g 'host' '127.0.0.1')
            if (@('127.0.0.1', '0.0.0.0', 'tailscale') -contains $hostValue) { $script:Global.Host = $hostValue }
            $browser = [string](Get-PropValue $g 'browser' 'llamacpp')
            if (@('llamacpp', 'openwebui', 'none') -contains $browser) { $script:Global.Browser = $browser }
            $agent = [string](Get-PropValue $g 'agent' 'off')
            if (@('off', 'on') -contains $agent) { $script:Global.Agent = $agent }
            $research = [string](Get-PropValue $g 'research' 'off')
            if (@('off', 'on') -contains $research) { $script:Global.Research = $research }
            $image = [string](Get-PropValue $g 'image' 'off')
            if (@('off', 'on') -contains $image) { $script:Global.Image = $image }
            $imagePath = [string](Get-PropValue $g 'imagePath' '')
            if (-not [string]::IsNullOrWhiteSpace($imagePath)) { $script:Global.ImagePath = $imagePath }
        }
        $models = Get-PropValue $raw 'models' $null
        if ($models) {
            foreach ($p in $models.PSObject.Properties) {
                $script:StateModels[$p.Name] = $p.Value
            }
        }
        $lm = Get-PropValue $raw 'lastModel' ''
        if ($lm) { $script:LastModelPath = [string]$lm }
    }
}

function New-CfgForModel {
    param($Model, [bool]$UseSession = $true)
    if ($UseSession -and $script:SessionCfg.ContainsKey($Model.Path)) {
        return $script:SessionCfg[$Model.Path]
    }

    $cfg = Get-RecommendedCfg $Model
    $saved = $script:StateModels[$Model.Path]
    if ($saved) {
        $v = Get-PropValue $saved 'preset' ''
        if ($v) { $cfg.Preset = [string]$v }
        $v = Get-PropValue $saved 'ctx' $null
        if ($null -ne $v) { $cfg.Ctx = [int]$v }
        $v = Get-PropValue $saved 'ctk' $null
        if ($v) { $cfg.Ctk = [string]$v }
        $v = Get-PropValue $saved 'ctv' $null
        if ($v) { $cfg.Ctv = [string]$v }
        $v = Get-PropValue $saved 'npredict' $null
        if ($null -ne $v) { $cfg.NPredict = [int]$v }
        $v = Get-PropValue $saved 'ngl' $null
        if ($v) { $cfg.Ngl = [string]$v }
        $v = Get-PropValue $saved 'vision' $null
        if ($v) { $cfg.Vision = [string]$v }
        $v = Get-PropValue $saved 'reasoning' $null
        if ($v) { $cfg.Reasoning = [string]$v }
        $v = Get-PropValue $saved 'template' $null
        if ($v) { $cfg.Template = [string]$v }
        $v = Get-PropValue $saved 'threads' $null
        if ($v) { $cfg.Threads = [string]$v }
        $v = Get-PropValue $saved 'cacheram' $null
        if ($v) { $cfg.CacheRam = [string]$v }
        $v = Get-PropValue $saved 'batch' $null
        if ($v) { $cfg.Batch = [string]$v }
    }

    $cfg.Port = [int]$script:Global.Port
    $cfg.Host = [string]$script:Global.Host
    $cfg.Browser = [string]$script:Global.Browser
    $cfg.Agent = [string]$script:Global.Agent
    $cfg.Research = [string]$script:Global.Research
    $cfg.Image = [string]$script:Global.Image
    $cfg.ImagePath = [string]$script:Global.ImagePath
    Normalize-Cfg $cfg
    if ($UseSession) { $script:SessionCfg[$Model.Path] = $cfg }
    return $cfg
}

function Get-CfgSnap {
    param($Cfg)
    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}' -f $Cfg.Preset, $Cfg.Ctx, $Cfg.Ctk, $Cfg.Ctv, $Cfg.NPredict, $Cfg.Ngl, $Cfg.Vision, $Cfg.Reasoning, $Cfg.Template, $Cfg.Threads, $Cfg.CacheRam, $Cfg.Batch)
}

function Set-StateModel {
    param($Cfg)
    $script:StateModels[$Cfg.Model.Path] = [pscustomobject]@{
        preset    = [string]$Cfg.Preset
        ctx       = [int]$Cfg.Ctx
        ctk       = [string]$Cfg.Ctk
        ctv       = [string]$Cfg.Ctv
        npredict  = [int]$Cfg.NPredict
        ngl       = [string]$Cfg.Ngl
        vision    = [string]$Cfg.Vision
        reasoning = [string]$Cfg.Reasoning
        template  = [string]$Cfg.Template
        threads   = [string]$Cfg.Threads
        cacheram  = [string]$Cfg.CacheRam
        batch     = [string]$Cfg.Batch
    }
}

function Write-State {
    $obj = [pscustomobject]@{
        lastModel = $script:LastModelPath
        global    = $script:Global
        models    = $script:StateModels
    }
    try {
        $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    } catch { }
}

function Sync-GlobalFromCfg {
    param($Cfg)
    $script:Global = [pscustomobject]@{
        port      = [int]$Cfg.Port
        host      = [string]$Cfg.Host
        browser   = [string]$Cfg.Browser
        agent     = [string]$Cfg.Agent
        research  = [string]$Cfg.Research
        image     = [string]$Cfg.Image
        imagePath = [string]$Cfg.ImagePath
    }
}

function Save-Cfg {
    param($Cfg)
    Set-StateModel $Cfg
    $script:LastModelPath = $Cfg.Model.Path
    Sync-GlobalFromCfg $Cfg
    $script:LastCfg = $Cfg
    Write-State
}

function Save-ModelCfg {
    param($Cfg, [string]$Snap)
    if ((Get-CfgSnap $Cfg) -ne $Snap) { Set-StateModel $Cfg }
    Sync-GlobalFromCfg $Cfg
    Write-State
}

function Refresh-Models {
    $script:Models = @(Get-Models)
    $script:LastCfg = $null
    if (-not $script:LastModelPath) { return }
    $m = $script:Models | Where-Object { $_.Path -eq $script:LastModelPath } | Select-Object -First 1
    if (-not $m) {
        $script:LastModelPath = ''
        return
    }
    $script:LastCfg = New-CfgForModel $m $false
}

# ---------------------------------------------------------------------------
# List cycling / labels
# ---------------------------------------------------------------------------
function Cycle-List {
    param($List, $Current, [int]$Direction)
    $arr = @($List)
    if ($arr.Count -eq 0) { return $Current }
    $idx = -1
    for ($i = 0; $i -lt $arr.Count; $i++) {
        if ([string]$arr[$i] -eq [string]$Current) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        if ($Direction -lt 0) { $idx = 0 } else { $idx = 0 }
    } else {
        $idx = ($idx + $Direction + $arr.Count) % $arr.Count
    }
    return $arr[$idx]
}

function Find-KvOption {
    param($Cfg)
    foreach ($o in $script:KvOptions) {
        if ($o.Ctk -eq $Cfg.Ctk -and $o.Ctv -eq $Cfg.Ctv) { return $o }
    }
    return [pscustomobject]@{ Ctk = $Cfg.Ctk; Ctv = $Cfg.Ctv; Label = ("{0} / {1}" -f $Cfg.Ctk, $Cfg.Ctv) }
}

function Cycle-KvOption {
    param($Cfg, [int]$Direction)
    $cur = Find-KvOption $Cfg
    $idx = [Array]::IndexOf($script:KvOptions, $cur)
    if ($idx -lt 0) { $idx = 0 } else { $idx = ($idx + $Direction + $script:KvOptions.Count) % $script:KvOptions.Count }
    $o = $script:KvOptions[$idx]
    $Cfg.Ctk = $o.Ctk
    $Cfg.Ctv = $o.Ctv
}

function Get-PresetLabel {
    param([string]$Name)
    switch ($Name) {
        'recomendado'   { return 'Recomendado' }
        'qualidade'     { return 'Qualidade máxima' }
        'longo'         { return 'Contexto longo' }
        'cpu'           { return 'Somente CPU' }
        'personalizado' { return 'Personalizado' }
        default         { return $Name }
    }
}

function Get-PresetCycle {
    param([string]$Current)
    $list = @('recomendado', 'qualidade', 'longo', 'cpu')
    if ($Current -eq 'personalizado') { return $list }
    return $list
}

function Get-NglMax {
    param($Model)
    if ($Model -and $Model.Meta -and [int]$Model.Meta.Layers -gt 0) { return [int]$Model.Meta.Layers }
    return 80
}

function Get-NglLabel {
    param([string]$Ngl, $Model = $null)
    switch ($Ngl) {
        'auto' { return 'automático (--fit)' }
        '0'    { return 'CPU (0 camadas)' }
        'all'  { return 'todas (all)' }
        default {
            if ($Ngl -match '^\d+$') {
                if ($Model -and [int]$Ngl -ge (Get-NglMax $Model)) { return ('{0} camadas na GPU (todas)' -f $Ngl) }
                return ('{0} camadas na GPU (resto na CPU)' -f $Ngl)
            }
            return $Ngl
        }
    }
}

function Get-BatchLabel {
    param([string]$Batch)
    if ($Batch -match '^\d+$') { return ('{0} tokens' -f $Batch) }
    return 'automático'
}

function Get-ThreadsMax {
    $n = 0
    try { $n = [int][Environment]::ProcessorCount } catch { }
    if ($n -lt 1) { $n = 4 }
    return $n
}

function Get-ThreadsLabel {
    param([string]$Threads)
    if ($Threads -match '^\d+$') { return ('{0} de {1}' -f $Threads, (Get-ThreadsMax)) }
    return 'automático'
}

function Get-AutoCacheRamMiB {
    param($Cfg)
    if (-not $script:Mem -or [int]$script:Mem.FreeMB -le 0) { return -1 }
    $m = $Cfg.Model
    $weights = $m.Size / 1GB
    $kv = Get-KvGB $m.Meta $Cfg.Ctx $Cfg.Ctk $Cfg.Ctv
    $freeR = $script:Mem.FreeMB / 1024.0
    $freeV = 0.0
    $gpuOk = ($script:Gpu -and $script:Gpu.Ok)
    if ($gpuOk) { $freeV = $script:Gpu.FreeMB / 1024.0 }
    $total = $weights + $kv
    if ($Cfg.Ngl -eq '0' -or -not $gpuOk) {
        $inRam = $total + 1.0
    } elseif ($Cfg.Ngl -match '^\d+$') {
        $nTotal = Get-NglMax $m
        $frac = [Math]::Min([int]$Cfg.Ngl, $nTotal) / [double]$nTotal
        $inRam = ($total * (1.0 - $frac)) + 1.0
    } else {
        $inRam = [Math]::Max(1.0, ($total + 1.0) - [Math]::Max(0.0, $freeV - 0.75))
    }
    if ($Cfg.Vision -eq 'cpu' -and $m.Mmproj) { $inRam += ($m.Mmproj.Length / 1GB) }
    $budget = $freeR - $inRam - 2.5
    $gb = [Math]::Min([Math]::Max(1.0, $kv * 4.0), [Math]::Min($budget * 0.5, 8.0))
    if ($gb -lt 0.5) { return 0 }
    return ([int][Math]::Floor($gb * 4.0) * 256)
}

function Get-CacheRamLabel {
    param($Cfg)
    if ($Cfg.CacheRam -eq 'off') { return 'desligado' }
    $mib = Get-AutoCacheRamMiB $Cfg
    if ($mib -lt 0) { return 'automático' }
    if ($mib -eq 0) { return 'automático · desligado' }
    return ('automático · {0:0.##} GB' -f ($mib / 1024.0))
}

function Get-TemplateLabel {
    param([string]$Template)
    if ($Template -eq 'chatml') { return 'ChatML' }
    return 'Padrão'
}

function Get-VisionLabel {
    param($Cfg)
    switch ($Cfg.Vision) {
        'gpu' { return 'ligada (GPU)' }
        'cpu' { return 'ligada (CPU)' }
        default { return 'desligada' }
    }
}

function Get-BrowserLabel {
    param([string]$Browser)
    switch ($Browser) {
        'llamacpp'  { return 'llama.cpp (embutida)' }
        'openwebui' { return 'Open WebUI (8080)' }
        'none'      { return 'nenhum' }
        default     { return $Browser }
    }
}

function Get-AgentLabel {
    param([string]$Agent)
    if ($Agent -eq 'on') { return 'ligado (arquivos + comandos)' }
    return 'desligado'
}

function Get-ResearchLabel {
    param([string]$Research)
    if ($Research -eq 'on') { return 'ligada (buscar e ler páginas da web)' }
    return 'desligada'
}

function ConvertTo-ImagePath {
    param([string]$Path)
    $p = ([string]$Path).Trim()
    if ($p.Length -ge 2) {
        if (($p.StartsWith('"') -and $p.EndsWith('"')) -or ($p.StartsWith("'") -and $p.EndsWith("'"))) {
            $p = $p.Substring(1, $p.Length - 2).Trim()
        }
    }
    return ($p -replace '/', '\')
}

function Get-ImageLabel {
    param($Cfg)
    $path = [string]$Cfg.ImagePath
    if ([string]::IsNullOrWhiteSpace($path)) { return 'desligada · digite o caminho do launch-windows.bat' }
    if ([string]$Cfg.Image -eq 'on') { return ('ligada · ' + $path) }
    return ('desligada · ' + $path)
}

function Get-HostLabel {
    param([string]$HostValue)
    if ($HostValue -eq 'tailscale') {
        $ip = Get-TailscaleIPv4
        if ($ip) { return ('Tailscale ({0})' -f $ip) }
        return 'Tailscale (não detectado)'
    }
    if ($HostValue -eq '0.0.0.0') {
        $ip = Get-LanIPv4
        if ($ip) { return ('LAN ({0})' -f $ip) }
        return 'LAN (todas as interfaces)'
    }
    return 'local (127.0.0.1)'
}

# ---------------------------------------------------------------------------
# Command builder
# ---------------------------------------------------------------------------
function Get-LoadFlagStyle {
    if ($script:LoadFlagStyle) { return $script:LoadFlagStyle }
    $style = 'none'
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $helpText = (& $script:ServerExe --help 2>&1 | Out-String)
        if ($helpText -match '--load-mode') { $style = 'loadmode' }
        elseif ($helpText -match '--no-mmap') { $style = 'legacy' }
    } catch {
        $style = 'none'
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $script:LoadFlagStyle = $style
    return $style
}

function Test-AgentSupported {
    if ($null -ne $script:AgentSupported) { return [bool]$script:AgentSupported }
    $ok = $false
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $helpText = (& $script:ServerExe --help 2>&1 | Out-String)
        if ($helpText -match '--agent\b') { $ok = $true }
    } catch {
        $ok = $false
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $script:AgentSupported = $ok
    return $ok
}

function Build-ServerArgs {
    param($Cfg, [string]$LogPath, [string]$UiConfigPath = '')
    $m = $Cfg.Model
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('-m'); $a.Add([string]$m.Path)
    $a.Add('--ctx-size'); $a.Add([string]$Cfg.Ctx)
    if ([int]$Cfg.NPredict -ge 0) { $a.Add('--n-predict'); $a.Add([string]$Cfg.NPredict) }
    $a.Add('--cache-type-k'); $a.Add([string]$Cfg.Ctk)
    $a.Add('--cache-type-v'); $a.Add([string]$Cfg.Ctv)

    $quant = ($Cfg.Ctk -notin @('f16', 'f32', 'bf16')) -or ($Cfg.Ctv -notin @('f16', 'f32', 'bf16'))
    $a.Add('--flash-attn'); $a.Add($(if ($quant) { 'on' } else { 'auto' }))

    if ([string]$Cfg.Template -eq 'chatml') { $a.Add('--chat-template'); $a.Add('chatml') }
    if ($Cfg.Threads -match '^\d+$') { $a.Add('--threads'); $a.Add([string]$Cfg.Threads) }
    if ($Cfg.Batch -match '^\d+$') {
        $a.Add('--ubatch-size'); $a.Add([string]$Cfg.Batch)
        if ([int]$Cfg.Batch -gt 2048) { $a.Add('--batch-size'); $a.Add([string]$Cfg.Batch) }
    }
    if ($Cfg.CacheRam -eq 'off') {
        $a.Add('--cache-ram'); $a.Add('0')
    } else {
        $cr = Get-AutoCacheRamMiB $Cfg
        if ($cr -ge 0) { $a.Add('--cache-ram'); $a.Add([string]$cr) }
    }

    $a.Add('--fit'); $a.Add('on')
    if ($Cfg.Ngl -ne 'auto') { $a.Add('--n-gpu-layers'); $a.Add([string]$Cfg.Ngl) }

    if ($Cfg.Vision -ne 'off' -and $m.Mmproj) {
        $a.Add('--mmproj'); $a.Add([string]$m.Mmproj.FullName)
        if ($Cfg.Vision -eq 'cpu') { $a.Add('--no-mmproj-offload') }
    }
    if ($Cfg.Reasoning -ne 'auto' -and $m.Meta.HasThinking) {
        $a.Add('--reasoning'); $a.Add([string]$Cfg.Reasoning)
    }

    $a.Add('--jinja')
    switch (Get-LoadFlagStyle) {
        'loadmode' { $a.Add('--load-mode'); $a.Add('none') }
        'legacy'   { $a.Add('--mlock') }
    }
    $a.Add('--parallel'); $a.Add('1')
    if ([string]$Cfg.Agent -eq 'on' -and (Test-AgentSupported)) { $a.Add('--agent') }
    if ($UiConfigPath) {
        $a.Add('--ui-mcp-proxy')
        $a.Add('--ui-config-file'); $a.Add($UiConfigPath)
    }
    $a.Add('--host'); $a.Add((Get-BindHost ([string]$Cfg.Host)))
    $a.Add('--port'); $a.Add([string]$Cfg.Port)
    if ($LogPath) {
        $a.Add('--log-file'); $a.Add($LogPath)
    }
    return $a.ToArray()
}

function Get-UvPath {
    $c = Get-Command uv.exe -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command uv -ErrorAction SilentlyContinue }
    if ($c) { return [string]$c.Source }
    return ''
}

function Test-ResearchSupported {
    if ($null -ne $script:ResearchSupported) { return [bool]$script:ResearchSupported }
    $ok = $false
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $helpText = (& $script:ServerExe --help 2>&1 | Out-String)
        if ($helpText -match '--ui-mcp-proxy' -and $helpText -match '--ui-config-file') { $ok = $true }
    } catch {
        $ok = $false
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $script:ResearchSupported = $ok
    return $ok
}

function Test-ResearchWanted {
    param($Cfg)
    if ([string]$Cfg.Research -ne 'on') { return $false }
    if ([string]$Cfg.Agent -eq 'on' -and (Test-AgentSupported)) { return $false }
    return (Test-ResearchSupported)
}

function Test-ImageSupported {
    return (Test-ResearchSupported)
}

function Get-ImageIssue {
    param($Cfg)
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) { return 'sem caminho definido' }
    if (-not (Test-Path -LiteralPath ([string]$Cfg.ImagePath) -PathType Leaf)) { return ('arquivo não encontrado: ' + [string]$Cfg.ImagePath) }
    if (-not (Test-ImageSupported)) { return 'llama-server.exe antigo, sem --ui-mcp-proxy' }
    if (-not (Get-UvPath)) { return 'uv não encontrado no PATH' }
    return ''
}

function Test-ImageWanted {
    param($Cfg)
    if ([string]$Cfg.Image -ne 'on') { return $false }
    return ((Get-ImageIssue $Cfg) -eq '')
}

function Get-ResearchServerSource {
    return @'
import sys
import os
import re
import json
import math
import time
import socket
import ssl
import ipaddress
import threading
import unicodedata
import html as htmllib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, urljoin, urlencode, quote, parse_qs
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED

import trafilatura

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
PARENT_PID = int(sys.argv[2]) if len(sys.argv) > 2 else 0
CTX = int(sys.argv[3]) if len(sys.argv) > 3 else 16384
SEARXNG = os.environ.get("SEARXNG_URL", "").strip().rstrip("/")
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
MAX_BYTES = 2500000
MAX_REDIRECTS = 5
READ_DEADLINE = 25


class FetchError(Exception):
    pass


def check_ip(addr):
    ip = ipaddress.ip_address(addr.split("%")[0])
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    if (not ip.is_global) or ip.is_multicast:
        raise FetchError("blocked address (private, local or reserved network)")
    return str(ip)


def open_conn(scheme, host, port, trusted):
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror:
        raise FetchError("host not found")
    addrs = []
    for info in infos:
        raw = info[4][0]
        addrs.append(raw.split("%")[0] if trusted else check_ip(raw))
    sock = None
    last = None
    for a in addrs:
        try:
            sock = socket.create_connection((a, port), timeout=12)
            break
        except OSError as e:
            last = e
    if sock is None:
        raise FetchError("connection failed: %s" % last)
    if scheme == "https":
        ctx = ssl.create_default_context()
        try:
            sock = ctx.wrap_socket(sock, server_hostname=host)
        except (ssl.SSLError, OSError) as e:
            sock.close()
            raise FetchError("TLS failed: %s" % e)
        conn = http.client.HTTPSConnection(host, port, timeout=15, context=ctx)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=15)
    conn.sock = sock
    return conn


def http_get(url, accept="text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", trusted=False):
    cur = url
    for _ in range(MAX_REDIRECTS + 1):
        parts = urlsplit(cur)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise FetchError("only http and https URLs are allowed")
        port = parts.port or (443 if parts.scheme == "https" else 80)
        path = quote(parts.path or "/", safe="/%:@!$&'()*+,;=-._~")
        if parts.query:
            path += "?" + quote(parts.query, safe="/%:@!$&'()*+,;=-._~?")
        conn = open_conn(parts.scheme, parts.hostname, port, trusted)
        try:
            conn.request("GET", path, headers={
                "User-Agent": UA,
                "Accept": accept,
                "Accept-Language": "en-US,en;q=0.8,pt-BR;q=0.7",
                "Accept-Encoding": "identity",
                "Connection": "close",
            })
            resp = conn.getresponse()
            if resp.status in (301, 302, 303, 307, 308):
                loc = resp.getheader("Location")
                if not loc:
                    raise FetchError("redirect without Location")
                cur = urljoin(cur, loc)
                continue
            if resp.status >= 400:
                raise FetchError("HTTP %d" % resp.status)
            ctype = (resp.getheader("Content-Type") or "").lower()
            chunks = []
            total = 0
            deadline = time.time() + READ_DEADLINE
            while total < MAX_BYTES and time.time() < deadline:
                data = resp.read(65536)
                if not data:
                    break
                chunks.append(data)
                total += len(data)
            return cur, ctype, b"".join(chunks)
        except (http.client.HTTPException, OSError) as e:
            raise FetchError("request failed: %s" % e)
        finally:
            try:
                conn.close()
            except Exception:
                pass
    raise FetchError("too many redirects")


def decode_body(body, ctype):
    m = re.search(r"charset=([\w\-]+)", ctype or "")
    for enc in ([m.group(1)] if m else []) + ["utf-8"]:
        try:
            return body.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return body.decode("utf-8", "replace")


def strip_tags(s):
    s = re.sub(r"(?is)<(script|style|noscript|svg).*?</\1>", " ", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = htmllib.unescape(s)
    return re.sub(r"[ \t\r\f\v]+", " ", re.sub(r"\n\s*\n+", "\n\n", s)).strip()


SKIP_EXT = re.compile(r"\.(png|jpe?g|gif|svg|webp|ico|css|js|json|xml|pdf|zip|gz|mp4|mp3|woff2?|ttf)$", re.I)
LINK_HINTS = ("about", "sobre", "faq", "help", "ajuda", "terms", "termos", "privacy", "privacidade", "pricing", "precos", "blog", "docs", "contact", "contato", "features", "how", "como", "news", "press", "team", "story", "quem")
NOISE_TOKENS = {"http", "https", "www", "com", "org", "net", "html"}
BAD_TLDS = {"js", "py", "md", "rs", "sh", "ts", "cs", "rb", "pm", "gz", "so", "exe", "dll", "txt", "pdf", "png", "jpg", "doc", "docx", "html", "css", "json", "xml"}
DOMAIN_RE = re.compile(r"(?i)\b((?:https?://)?(?:[a-z0-9][a-z0-9-]*\.)+([a-z]{2,24}))(/[^\s\"']*)?")


def bare_host(host):
    host = (host or "").lower()
    return host[4:] if host.startswith("www.") else host


def url_key(url):
    p = urlsplit(url)
    return bare_host(p.hostname) + p.path.rstrip("/")


def find_domains(text):
    out = []
    for m in DOMAIN_RE.finditer(text):
        if m.group(2).lower() in BAD_TLDS:
            continue
        url = m.group(1) if m.group(1).lower().startswith("http") else "https://" + m.group(1)
        url += (m.group(3) or "/").rstrip(".,;:!?)]}") or "/"
        if url not in out:
            out.append(url)
    return out[:2]


def meta_values(raw):
    out = {}
    for tag in re.findall(r"(?is)<meta\s[^>]*>", raw[:200000]):
        attrs = {}
        for k, v in re.findall(r"""([\w:-]+)\s*=\s*("[^"]*"|'[^']*')""", tag):
            attrs[k.lower()] = v[1:-1]
        key = (attrs.get("name") or attrs.get("property") or "").lower()
        if key and attrs.get("content") and key not in out:
            out[key] = htmllib.unescape(attrs["content"]).strip()
    return out


def page_links(raw, base):
    host = bare_host(urlsplit(base).hostname)
    seen = []
    for href in re.findall(r"""(?is)<a\s[^>]*?href\s*=\s*("[^"]*"|'[^']*')""", raw[:600000]):
        u = urljoin(base, htmllib.unescape(href[1:-1]).strip()).split("#")[0]
        p = urlsplit(u)
        if p.scheme not in ("http", "https") or not p.hostname:
            continue
        if bare_host(p.hostname) != host or SKIP_EXT.search(p.path):
            continue
        if u.rstrip("/") == base.rstrip("/") or u in seen:
            continue
        seen.append(u)
    return seen


def rank_links(links):
    def score(item):
        idx, u = item
        path = urlsplit(u).path.lower()
        hits = sum(1 for h in LINK_HINTS if h in path)
        return (-hits, path.count("/"), idx)
    return [u for _, u in sorted(enumerate(links), key=score)]


def load_page(url):
    final, ctype, body = http_get(url)
    page = {"url": final, "title": "", "text": "", "desc": "", "date": "", "links": [], "thin": False}
    if "html" in ctype or "xml" in ctype or not ctype:
        raw = decode_body(body, ctype)
        meta = meta_values(raw)
        page["desc"] = clean(meta.get("og:description") or meta.get("description") or meta.get("twitter:description") or "")
        tm = re.search(r"(?is)<title[^>]*>(.*?)</title>", raw)
        page["title"] = clean(meta.get("og:title") or (tm.group(1) if tm else ""))
        page["links"] = rank_links(page_links(raw, final))
        text = None
        try:
            text = trafilatura.extract(body, url=final, include_comments=False, include_tables=True, favor_recall=True)
        except Exception:
            text = None
        try:
            tmeta = trafilatura.extract_metadata(body)
            if tmeta is not None:
                if tmeta.title and not page["title"]:
                    page["title"] = clean(tmeta.title)
                if tmeta.date:
                    page["date"] = str(tmeta.date)
        except Exception:
            pass
        if not text:
            text = strip_tags(raw)
        if len(text) < 300:
            page["thin"] = True
            parts = []
            for x in (page["title"], page["desc"], text):
                if x and x not in parts:
                    parts.append(x)
            text = "\n".join(parts)
        page["text"] = text.strip()
        if not page["text"]:
            raise FetchError("no readable text (page may require JavaScript)")
        return page
    if ctype.startswith("text/") or "json" in ctype:
        page["text"] = decode_body(body, ctype).strip()
        page["title"] = final
        if not page["text"]:
            raise FetchError("empty page")
        return page
    raise FetchError("unsupported content type: %s" % (ctype.split(";")[0] or "unknown"))


def clean(s):
    return re.sub(r"\s+", " ", strip_tags(s or "")).strip()


def search_ddgs(query, n):
    from ddgs import DDGS
    items = DDGS().text(query, max_results=n)
    out = []
    for r in items or []:
        if r.get("href"):
            out.append({"title": clean(r.get("title")), "url": r["href"], "snippet": clean(r.get("body"))})
    return out


def search_html(query, n):
    _, ctype, body = http_get("https://html.duckduckgo.com/html/?" + urlencode({"q": query}))
    page = decode_body(body, ctype)
    out = []
    pat = re.compile(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>(.*?)(?=class="result__a"|$)', re.S)
    for m in pat.finditer(page):
        href = htmllib.unescape(m.group(1))
        if href.startswith("//"):
            href = "https:" + href
        q = parse_qs(urlsplit(href).query)
        if "uddg" in q:
            href = q["uddg"][0]
        if not href.startswith("http"):
            continue
        sm = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', m.group(3), re.S)
        out.append({"title": clean(m.group(2)), "url": href, "snippet": clean(sm.group(1)) if sm else ""})
        if len(out) >= n:
            break
    return out


def search_searx(query, n):
    _, ctype, body = http_get(SEARXNG + "/search?" + urlencode({"q": query, "format": "json"}), "application/json", True)
    data = json.loads(decode_body(body, ctype))
    out = []
    for r in data.get("results", [])[:n]:
        if r.get("url"):
            out.append({"title": clean(r.get("title")), "url": r["url"], "snippet": clean(r.get("content"))})
    return out


def do_search(query, n):
    engines = []
    if SEARXNG:
        engines.append(("searxng", search_searx))
    engines.append(("ddgs", search_ddgs))
    engines.append(("duckduckgo-html", search_html))
    errors = []
    for name, fn in engines:
        try:
            res = fn(query, n)
            if res:
                return res
            errors.append("%s: no results" % name)
        except Exception as e:
            errors.append("%s: %s" % (name, e))
    raise RuntimeError("search failed (" + "; ".join(errors) + ")")


def hard_budget():
    return max(4000, (CTX - 3500) * 3)


def default_budget():
    return max(4000, min(int(CTX * 1.5), 120000, hard_budget()))


def clamp(v, lo, hi, default):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, v))


def norm_tokens(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.findall(r"\w+", s)


def bm25(query_tokens, docs_tokens):
    n = len(docs_tokens)
    if n == 0:
        return []
    avg = (sum(len(t) for t in docs_tokens) / n) or 1.0
    df = {}
    for toks in docs_tokens:
        for w in set(toks):
            df[w] = df.get(w, 0) + 1
    scores = []
    for toks in docs_tokens:
        tf = {}
        for w in toks:
            tf[w] = tf.get(w, 0) + 1
        s = 0.0
        for q in set(query_tokens):
            f = tf.get(q, 0)
            if not f:
                continue
            idf = math.log(1 + (n - df[q] + 0.5) / (df[q] + 0.5))
            s += idf * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * len(toks) / avg))
        scores.append(s)
    return scores


def split_chunks(text, size=900, limit=60):
    chunks = []
    cur = ""
    for para in re.split(r"\n+", text):
        para = para.strip()
        if not para:
            continue
        while len(para) > size * 1.5:
            cut = para.rfind(" ", 0, size)
            if cut < size // 2:
                cut = size
            if cur:
                chunks.append(cur)
                cur = ""
            chunks.append(para[:cut].strip())
            para = para[cut:].strip()
        if cur and len(cur) + len(para) + 1 > size:
            chunks.append(cur)
            cur = para
        else:
            cur = (cur + "\n" + para) if cur else para
    if cur:
        chunks.append(cur)
    return chunks[:limit]


QUOTE_PAIRS = {"\u201c": "\u201d", "\u2018": "\u2019"}


def clean_str(value):
    if not isinstance(value, str):
        return value
    s = value.strip()
    for _ in range(5):
        prev = s
        if len(s) >= 4 and s.startswith('\\"') and s.endswith('\\"'):
            s = s[2:-2].strip()
        elif len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            try:
                dec = json.loads(s)
            except ValueError:
                dec = None
            if isinstance(dec, str):
                s = dec.strip()
            elif '"' not in s[1:-1].replace('\\"', ''):
                s = s[1:-1].replace('\\"', '"').strip()
        elif len(s) >= 2 and s[0] in "'`" and s[-1] == s[0] and s[0] not in s[1:-1]:
            s = s[1:-1].strip()
        elif len(s) >= 2 and QUOTE_PAIRS.get(s[0]) == s[-1]:
            s = s[1:-1].strip()
        s = re.sub(r'^\\+(?![()\[\]{}])', '', s)
        s = re.sub(r'\\+$', '', s).strip()
        if s == prev:
            break
    return s


def _walk(obj):
    if isinstance(obj, dict):
        return {clean_str(k) if isinstance(k, str) else k: _walk(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_walk(v) for v in obj]
    if isinstance(obj, str):
        return clean_str(obj)
    return obj


def sanitize_args(obj):
    if obj is None:
        return {}
    if isinstance(obj, str):
        try:
            obj = json.loads(clean_str(obj))
        except ValueError:
            return {}
    if not isinstance(obj, dict):
        return {}
    return _walk(obj)


def tool_search_links(args):
    query = str(args.get("query", "")).strip()
    if not query:
        raise ValueError("query is required")
    n = clamp(args.get("max_results"), 1, 15, 8)
    res = do_search(query, n)
    lines = []
    for i, r in enumerate(res, 1):
        lines.append("%d. %s\n   %s\n   %s" % (i, r["title"] or r["url"], r["url"], r["snippet"]))
    lines.append("\nSnippets only, not the page content. To read a page call fetch_url(url); for the actual content of several pages call web_search.")
    return "\n".join(lines)


def tool_fetch_url(args):
    url = str(args.get("url", "")).strip()
    if not url:
        raise ValueError("url is required")
    if not re.match(r"(?i)^https?://", url):
        url = "https://" + url
    limit = clamp(args.get("max_chars"), 1000, hard_budget(), default_budget())
    offset = clamp(args.get("offset"), 0, 10000000, 0)
    page = load_page(url)
    text = page["text"]
    head = "%s\n%s" % (page["title"] or page["url"], page["url"])
    if page["date"]:
        head += "\nDate: " + page["date"]
    if page["thin"]:
        head += "\n[note: very little text could be read; the page probably needs JavaScript]"
    part = text[offset:offset + limit]
    if not part:
        return "%s\n\n[no more content: the page has %d characters]" % (head, len(text))
    out = "%s\n\n%s" % (head, part)
    rest = len(text) - (offset + len(part))
    if rest > 0:
        out += "\n\n[truncated: %d more characters. Call fetch_url again with offset=%d to continue]" % (rest, offset + len(part))
    if offset == 0 and page["links"]:
        out += "\n\nLinks on this site (use fetch_url to read them):\n" + "\n".join(page["links"][:12])
    return out


def multi_search(queries, per):
    scores = {}
    items = {}
    errors = []
    for q in queries:
        try:
            res = do_search(q, per)
        except Exception as e:
            errors.append(str(e))
            continue
        for rank, r in enumerate(res):
            key = url_key(r["url"])
            scores[key] = scores.get(key, 0.0) + 1.0 / (60 + rank)
            if key not in items:
                items[key] = r
    if not items:
        raise RuntimeError(errors[0] if errors else "no results")
    return [items[k] for k in sorted(items, key=lambda k: -scores[k])]


QUICK_CHARS = 4000
BATCH = 3
CONF = 0.6
GRACE = 2.0
STAGE_TIMEOUT = 20.0
REL_CUT = 0.4
STOP = set("a o as os um uma uns umas de do da dos das em no na nos nas por para pra com sem e ou que qual quais como onde esta estao ta sao eh foi ser ter tem tinha quanto quanta quantos quantas the an of in on at to for and or is are was were be what which how much many does do did me my you your it its this that".split())
NUM_WORDS = set("quanto quanta quantos quantas cotacao preco valor price cost rate much many when quando".split())


def core_tokens(queries):
    toks = [w for w in norm_tokens(" ".join(queries)) if w not in NOISE_TOKENS]
    core = [w for w in toks if w not in STOP and (len(w) > 1 or w.isdigit())]
    wants = any(w in NUM_WORDS for w in toks)
    return (core or toks), wants


def rank_candidates(results, core):
    if len(results) < 2 or not core:
        return results
    sc = bm25(core, [norm_tokens((r.get("title") or "") + " " + (r.get("snippet") or "")) for r in results])
    mx = max(sc) if sc else 0.0

    def key(i):
        rel = (sc[i] / mx) if mx > 0 else 0.0
        return (-(0.5 / (1 + i) + 0.5 * rel), i)
    return [results[i] for i in sorted(range(len(results)), key=key)]


def doc_confident(d, core, wants):
    if not core or not d["text"]:
        return False
    cs = set(core)
    for c, t in zip(d["chunks"], d["ctoks"]):
        if len(cs & set(t)) / float(len(cs)) >= CONF and (not wants or re.search(r"\d", c)):
            return True
    return False


def meta_hit(d, core):
    if not core or not d["text"]:
        return False
    host = set(norm_tokens(bare_host(urlsplit(d["url"]).hostname)))
    cs = set(core)
    if any(len(w) >= 3 and w in host for w in cs):
        return True
    return len(cs & set(norm_tokens(d.get("meta", "")))) * 2 >= len(cs)


def load_doc(r):
    base = {"url": r["url"], "title": r.get("title") or r["url"], "text": "", "date": "", "thin": False, "links": [], "error": "", "snippet": r.get("snippet", ""), "linked": r.get("linked", False), "seed": r.get("seed", False), "chunks": [], "ctoks": [], "meta": ""}
    try:
        p = load_page(r["url"])
        base.update({"url": p["url"], "title": r.get("title") or p["title"] or p["url"], "text": p["text"], "date": p["date"], "thin": p["thin"], "links": p["links"]})
        base["meta"] = " ".join([base["title"], p.get("desc") or ""])
        base["chunks"] = split_chunks(p["text"], 900, 200)
        base["ctoks"] = [norm_tokens(c) for c in base["chunks"]]
    except Exception as e:
        base["error"] = str(e)
    return base


def load_batch(batch, core, wants, early):
    pool = ThreadPoolExecutor(max_workers=max(1, len(batch)))
    pending = set()
    for i, r in enumerate(batch):
        f = pool.submit(load_doc, r)
        f.ord = i
        pending.add(f)
    got = []
    start = time.time()
    grace = None
    while pending:
        done, pending = wait(pending, timeout=0.25, return_when=FIRST_COMPLETED)
        for f in done:
            d = f.result()
            d["ord"] = f.ord
            got.append(d)
            if early and grace is None and doc_confident(d, core, wants):
                grace = time.time() + GRACE
        now = time.time()
        if (grace is not None and now >= grace) or now - start > STAGE_TIMEOUT:
            break
    try:
        pool.shutdown(wait=False, cancel_futures=True)
    except TypeError:
        pool.shutdown(wait=False)
    got.sort(key=lambda d: d["ord"])
    return got


def as_list(v):
    if v is None:
        return []
    if isinstance(v, str):
        s = v.strip()
        if s.startswith("["):
            try:
                v = json.loads(s)
            except Exception:
                v = re.split(r"[,\n]", s.strip("[]"))
        else:
            v = re.split(r"[,\n]", s)
    if not isinstance(v, (list, tuple)):
        v = [v]
    return [str(x).strip().strip("\"'") for x in v if str(x).strip()]


def tool_web_search(args):
    args = dict(args)
    query = str(args.get("query") or args.get("q") or "").strip()
    extra = as_list(args.get("queries")) + as_list(args.get("urls")) + as_list(args.get("url"))
    if not query and extra:
        query, extra = extra[0], extra[1:]
    if not query:
        raise ValueError("pass query (string) or queries (list of strings)")
    args["queries"] = extra
    deep = str(args.get("depth", "")).lower() == "deep"
    n = clamp(args.get("sources"), 1, 10, 10 if deep else 6)
    budget = clamp(args.get("max_chars"), 1500, hard_budget(), default_budget())
    quick_cap = budget if args.get("max_chars") is not None else min(budget, QUICK_CHARS)
    extra_q = args.get("queries")
    queries = [query]
    if isinstance(extra_q, list):
        for x in extra_q:
            x = str(x).strip()
            if x and x not in queries and len(queries) < 4:
                queries.append(x)

    seeds = []
    variants = []

    def addv(v):
        if v and v not in variants:
            variants.append(v)

    for q in queries:
        addv(q)
        doms = find_domains(q)
        for d in doms:
            if d not in seeds:
                seeds.append(d)
            addv('"%s"' % bare_host(urlsplit(d).hostname))
        if not doms and len(q.split()) <= 4 and '"' not in q:
            addv('"%s"' % q)
    variants = variants[:6]

    try:
        results = multi_search(variants, 8)
    except Exception:
        if not seeds:
            raise
        results = []

    core, wants = core_tokens(queries)
    results = rank_candidates(results, core)

    cands = []
    seen_keys = set()
    per_host = {}

    def add(r):
        key = url_key(r["url"])
        host = bare_host(urlsplit(r["url"]).hostname)
        if key in seen_keys or per_host.get(host, 0) >= 2:
            return
        seen_keys.add(key)
        per_host[host] = per_host.get(host, 0) + 1
        cands.append(r)

    for d in seeds:
        add({"url": d, "title": "", "snippet": "", "seed": True})
    for r in results:
        if len(cands) >= n:
            break
        add(r)

    docs = []
    start = 0
    while start < len(cands):
        size = len(cands) if deep else BATCH
        batch = cands[start:start + size]
        start += len(batch)
        docs += load_batch(batch, core, wants, not deep)
        if deep or any(doc_confident(d, core, wants) for d in docs):
            break

    more = []
    for d in docs:
        if d["url"] in seeds or any(d["url"].rstrip("/") == s.rstrip("/") for s in seeds):
            for link in d["links"]:
                key = url_key(link)
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                more.append({"url": link, "title": "", "snippet": "", "linked": True})
                if len(more) >= 3:
                    break
    if more:
        docs += load_batch(more, core, wants, False)

    chunks = []
    ctoks = []
    first_idx = {}
    for di, d in enumerate(docs):
        for p, c in enumerate(d["chunks"]):
            if p == 0:
                first_idx[di] = len(chunks)
            chunks.append((di, p, c))
            ctoks.append(d["ctoks"][p])
    scores = bm25(core, ctoks)
    by_doc = {}
    for i, c in enumerate(chunks):
        by_doc.setdefault(c[0], []).append(scores[i])

    def tier(di):
        if docs[di]["seed"]:
            return 0
        return 1 if docs[di]["linked"] else 2

    def relevance(di):
        rel = sum(sorted(by_doc.get(di, [0.0]), reverse=True)[:3])
        if rel <= 0 and meta_hit(docs[di], core):
            return 0.001
        return rel

    shown = {}
    extra = []
    per_doc = {}
    if deep:
        ranked = sorted([di for di in range(len(docs)) if docs[di]["text"]], key=lambda di: (tier(di), -relevance(di), di))
        keep = [di for di in ranked if tier(di) < 2 or relevance(di) > 0]
        ranked = keep or ranked[:2]
        remaining = budget
        cap = max(3000, int(budget * 0.6))
        for di in ranked:
            if remaining < 1200:
                break
            text = docs[di]["text"]
            room = min(remaining, cap)
            part = text
            if len(text) > room:
                part = text[:room]
                cut = part.rfind("\n")
                if cut > room * 0.6:
                    part = part[:cut]
            shown[di] = part
            remaining -= len(part)
        for i in sorted([i for i in range(len(chunks)) if chunks[i][0] not in shown and scores[i] > 0], key=lambda i: -scores[i]):
            di = chunks[i][0]
            if per_doc.get(di, 0) >= 2 or len(chunks[i][2]) > remaining:
                continue
            extra.append(i)
            per_doc[di] = per_doc.get(di, 0) + 1
            remaining -= len(chunks[i][2])
    else:
        order = sorted([i for i in range(len(chunks)) if scores[i] > 0], key=lambda i: -scores[i])
        best = scores[order[0]] if order else 0.0
        used = 0
        for i in order:
            di = chunks[i][0]
            if len(extra) >= 3 and scores[i] < best * REL_CUT:
                break
            if per_doc.get(di, 0) >= 3:
                continue
            if extra and used + len(chunks[i][2]) > quick_cap:
                break
            extra.append(i)
            per_doc[di] = per_doc.get(di, 0) + 1
            used += len(chunks[i][2])
        nothing = not extra
        metas = 0
        for di, d in enumerate(docs):
            if per_doc.get(di) or di not in first_idx:
                continue
            on_topic = metas < 2 and meta_hit(d, core)
            if d["seed"] or on_topic or (nothing and len(per_doc) < 2):
                extra.append(first_idx[di])
                per_doc[di] = 1
                if on_topic and not d["seed"]:
                    metas += 1
    extra.sort(key=lambda i: (chunks[i][0], chunks[i][1]))

    readable = sum(1 for d in docs if d["text"])
    thin = sum(1 for d in docs if d["thin"])
    out = ["Query: " + " | ".join(queries), "", "Sources (%d read, %d total):" % (readable, len(docs))]
    for di, d in enumerate(docs):
        line = "[%d] %s - %s" % (di + 1, d["title"] or d["url"], d["url"])
        if d["date"]:
            line += " (%s)" % d["date"]
        if d["linked"]:
            line += " (internal page of the site)"
        if d["error"]:
            line += " (could not be read: %s)" % d["error"]
            if d["snippet"]:
                line += "\n    search snippet: " + d["snippet"][:300]
        elif di in shown:
            if len(shown[di]) >= len(d["text"]):
                line += " - full text, %d characters" % len(d["text"])
            else:
                line += " - first %d of %d characters; call fetch_url with offset=%d for the rest" % (len(shown[di]), len(d["text"]), len(shown[di]))
        elif per_doc.get(di):
            line += " - excerpts only; call fetch_url to read it fully"
        elif d["text"]:
            if tier(di) == 2 and relevance(di) <= 0:
                why = "no match with the query"
            elif deep:
                why = "no room left"
            else:
                why = "less relevant than the excerpts shown"
            line += " - not included (%s); call fetch_url to read it" % why
        out.append(line)
    for di in sorted(shown):
        out.append("")
        out.append("=== [%d] %s ===" % (di + 1, docs[di]["title"] or docs[di]["url"]))
        out.append(shown[di])
    if extra:
        out.append("")
        out.append("=== Relevant excerpts ===" if not deep else "=== Other relevant excerpts ===")
        for i in extra:
            out.append("")
            out.append("[%d] %s" % (chunks[i][0] + 1, chunks[i][2]))
    if not shown and not extra:
        out.append("")
        out.append("(nothing readable was found)")
    out.append("")
    if thin:
        out.append("Note: %d page(s) have little text (probably JavaScript-rendered); only their title and description could be read." % thin)
    if deep:
        out.append("Instructions: answer only from these sources. At the end of your answer, add a line Sources: (translated to the language of the user) followed by a bullet list with only the URLs you actually used, like: - https://example.com. Never list a source you did not use. If they do not cover the question, say so, then call web_search again with different queries or fetch_url on a promising URL. Never tell the user to search by themselves.")
    else:
        out.append("Instructions: answer only from these excerpts. At the end of your answer, add a line Sources: (translated to the language of the user) followed by a bullet list with only the URLs you actually used, like: - https://example.com. Never list a source you did not use. If they do not cover the question, say so, then call web_search again with depth=deep, or fetch_url on a promising URL to read the full page. Never tell the user to search by themselves.")
    return "\n".join(out)


TOOLS = [
    {
        "name": "search_links",
        "description": "Only finds website addresses. Returns links with titles, never page content. Use it when the user wants the address of a site. To get content for an answer, use web_search.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "max_results": {"type": "integer", "description": "Number of results, 1 to 15 (default 8)"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "fetch_url",
        "description": "Reads one web page and returns its text. Use it when the user gives a link, or to read a page from the search results in full. Use offset to continue a cut page. The link must come from the user or from a tool result. Never make one up.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "Full http or https URL"},
                "max_chars": {"type": "integer", "description": "Maximum characters to return (default is sized to the context window)"},
                "offset": {"type": "integer", "description": "Character offset to start from (default 0)"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "web_search",
        "description": "Searches the web, reads the best pages and returns excerpts with numbered sources. Use it for questions about news, facts, people, companies, products and prices. Use depth=deep for broad questions. For broad topics, put several angles in queries. If the query has a domain or URL, that site is read.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "2 to 6 short keywords, not a full sentence"},
                "queries": {"type": "array", "items": {"type": "string"}, "description": "Different search angles or URLs, up to 4. Can be used instead of query"},
                "depth": {"type": "string", "enum": ["quick", "deep"], "description": "quick (default): short answer from the best excerpts of the most promising pages, reading more only if needed; deep: full text of up to 10 pages"},
                "sources": {"type": "integer", "description": "Maximum number of pages to read, 1 to 10"},
                "max_chars": {"type": "integer", "description": "Maximum characters of page text to return (quick is capped at about 4000 unless you set this; deep is sized to the context window)"},
            },
            "required": [],
        },
    },
]

HANDLERS = {"search_links": tool_search_links, "fetch_url": tool_fetch_url, "web_search": tool_web_search}


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle_rpc(msg):
    if not isinstance(msg, dict):
        return rpc_error(None, -32600, "invalid request")
    if "id" not in msg:
        return None
    rid = msg["id"]
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        ver = params.get("protocolVersion") or "2025-03-26"
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "llama-research", "version": "1.0"},
        }}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        fn = HANDLERS.get(params.get("name"))
        if fn is None:
            return rpc_error(rid, -32602, "unknown tool: %s" % params.get("name"))
        try:
            text = fn(sanitize_args(params.get("arguments")))
            err = False
        except Exception as e:
            text = "Error: %s" % e
            err = True
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}], "isError": err}}
    return rpc_error(rid, -32601, "method not found: %s" % method)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def host_ok(self):
        host = (self.headers.get("Host") or "").lower()
        name = host.rsplit(":", 1)[0] if not host.startswith("[") else host.split("]")[0] + "]"
        return name in ("127.0.0.1", "localhost", "[::1]")

    def send_body(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if not self.host_ok():
            return self.send_body(403)
        if self.path == "/health":
            return self.send_body(200, b"ok", "text/plain")
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self.send_body(200 if self.host_ok() else 403)

    def do_POST(self):
        if not self.host_ok():
            return self.send_body(403)
        if self.path.split("?")[0] != "/mcp":
            return self.send_body(404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self.send_body(400, json.dumps(rpc_error(None, -32700, "parse error")).encode("utf-8"))
        if isinstance(payload, list):
            replies = [r for r in (handle_rpc(m) for m in payload) if r is not None]
            reply = replies or None
        else:
            reply = handle_rpc(payload)
        if reply is None:
            return self.send_body(202)
        self.send_body(200, json.dumps(reply, ensure_ascii=False).encode("utf-8"))


def watch_parent(pid):
    try:
        import ctypes
        k32 = ctypes.windll.kernel32
        handle = k32.OpenProcess(0x00100000, False, pid)
        if handle:
            k32.WaitForSingleObject(handle, 0xFFFFFFFF)
            os._exit(0)
    except Exception:
        pass


def main():
    if PARENT_PID:
        threading.Thread(target=watch_parent, args=(PARENT_PID,), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


if __name__ == "__main__":
    main()
'@
}

function Get-ImageServerSource {
    return @'
import sys
import os
import re
import json
import time
import base64
import socket
import threading
import subprocess
import urllib.request
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
PARENT_PID = int(sys.argv[2]) if len(sys.argv) > 2 else 0
SWARM = (sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:7801").rstrip("/")
SWARM_PID = int(sys.argv[4]) if len(sys.argv) > 4 else 0
LLAMA_PORT = int(sys.argv[5]) if len(sys.argv) > 5 else 0
IMAGE_DIR = (sys.argv[6] if len(sys.argv) > 6 else "").strip()
VISION = (sys.argv[7] if len(sys.argv) > 7 else "0").strip() == "1"

IMG_MAX = 40
DEFAULT_NEGATIVE = "(worst quality, low quality, normal quality:1.3), lowres, jpeg artifacts, blurry, (bad anatomy, bad proportions:1.2), extra limbs, missing limbs, fused fingers, (bad hands:1.3), extra fingers, fewer fingers, missing fingers, mutated hands, (bad feet, extra digits:1.1), (asymmetrical eyes:1.2), cross-eyed, mismatched pupils, empty eyes, (asymmetrical face:1.2), deformed face, distorted mouth, (messy hair, hair through clothes:1.1), floating hair strands, (cluttered clothing, excessive frills, over-detailed outfit:1.3), asymmetrical clothing, ribbons everywhere, random straps, fabric errors, wrinkled fabric artifacts, cropped, out of frame, worst crop, text, signature, watermark, logo, artist name, username"
IMG_STORE = {}
IMG_ORDER = []
IMG_META = {}
CURRENT_MODEL = {"name": ""}
IMG_LOCK = threading.Lock()
IMG_NAME_RE = re.compile(r"^[A-Za-z0-9]{8,64}\.(png|jpg|webp|gif)$")
IMG_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"}
IMG_MIME = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"}

DEFAULTS = {
    "steps": 18,
    "cfgscale": 3.5,
    "width": 800,
    "height": 800,
    "sampler": "euler_ancestral",
    "scheduler": "normal",
}
PARAMS_CACHE = {"data": None, "at": 0.0}
PARAMS_TTL = 600


def swarm_call(path, payload, timeout=900):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(SWARM + path, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        msg = ""
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
            if isinstance(obj, dict):
                msg = obj.get("error") or obj.get("error_id") or ""
        except Exception:
            msg = ""
        raise RuntimeError("SwarmUI error: %s" % (msg or ("HTTP %s" % e.code)))
    except (urllib.error.URLError, TimeoutError, socket.timeout) as e:
        raise RuntimeError("SwarmUI is not reachable at %s: %s" % (SWARM, getattr(e, "reason", e)))
    try:
        obj = json.loads(raw.decode("utf-8"))
    except Exception:
        raise RuntimeError("SwarmUI returned invalid JSON")
    if isinstance(obj, dict) and obj.get("error"):
        raise RuntimeError("SwarmUI error: %s" % obj["error"])
    return obj


def new_session():
    obj = swarm_call("/API/GetNewSession", {}, timeout=120)
    sid = obj.get("session_id")
    if not sid:
        raise RuntimeError("SwarmUI did not create a session (is authorization required?)")
    return sid


def tool_list_models(args):
    want_details = bool((args or {}).get("details"))
    sid = new_session()
    obj = swarm_call("/API/ListModels", {
        "session_id": sid,
        "path": "",
        "depth": 20,
        "subtype": "Stable-Diffusion",
        "sortBy": "Name",
        "allowRemote": False,
        "dataImages": False,
    }, timeout=180)
    files = obj.get("files") or []
    lines = ["Image models:"]
    count = 0
    for item in files:
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        count += 1
        if not want_details:
            lines.append("- " + re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", name.replace("\\", "/").rsplit("/", 1)[-1]))
            continue
        bits = []
        title = str(item.get("title") or "").strip()
        if title and title != name:
            bits.append(title)
        arch = str(item.get("architecture") or "").strip()
        if arch:
            bits.append("arch=" + arch)
        res = str(item.get("resolution") or "").strip()
        if res:
            bits.append(res)
        if item.get("loaded"):
            bits.append("loaded")
        suffix = ("  (" + ", ".join(bits) + ")") if bits else ""
        lines.append("- " + name + suffix)
    if count == 0:
        return "No image models were found in SwarmUI. Add one in the SwarmUI Models tab first."
    lines.append("")
    if want_details:
        lines.append("NOW: answer the user's question using the details above, then ask which model to use. Stop. Do not generate an image.")
    else:
        lines.append("NOW: list only the model names above, one per line. Ask which model to use and stop. Do not generate an image.")
    return "\n".join(lines)


def tool_list_params(args):
    data = PARAMS_CACHE["data"]
    if data is None or (time.time() - PARAMS_CACHE["at"]) > PARAMS_TTL:
        sid = new_session()
        obj = swarm_call("/API/ListT2IParams", {"session_id": sid}, timeout=180)
        groups = {}
        for g in obj.get("groups") or []:
            gid = g.get("id")
            if gid:
                groups[gid] = g.get("name") or gid
        params = []
        for p in obj.get("list") or []:
            gid = p.get("group")
            params.append({
                "id": p.get("id"),
                "name": p.get("name"),
                "group": groups.get(gid, gid),
                "type": p.get("type"),
                "description": p.get("description"),
                "default": p.get("default"),
                "min": p.get("min"),
                "max": p.get("max"),
                "step": p.get("step"),
                "values": p.get("values"),
                "value_names": p.get("value_names"),
                "visible": p.get("visible"),
                "advanced": p.get("advanced"),
            })
        data = params
        PARAMS_CACHE["data"] = data
        PARAMS_CACHE["at"] = time.time()
    ids = args.get("ids")
    if isinstance(ids, str):
        ids = [x for x in re.split(r"[,\s\[\]\"']+", ids) if x]
    if ids:
        wanted = set(str(x).strip().lower() for x in ids if str(x).strip())
        data = [p for p in data if str(p.get("id") or "").lower() in wanted]
    group = str(args.get("group") or "").strip().lower()
    if group:
        data = [p for p in data if str(p.get("group") or "").lower() == group]
    return json.dumps({"count": len(data), "parameters": data}, ensure_ascii=False, separators=(",", ":"))


QUOTE_PAIRS = {"\u201c": "\u201d", "\u2018": "\u2019"}


def clean_str(value):
    if not isinstance(value, str):
        return value
    s = value.strip()
    for _ in range(5):
        prev = s
        if len(s) >= 4 and s.startswith('\\"') and s.endswith('\\"'):
            s = s[2:-2].strip()
        elif len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            try:
                dec = json.loads(s)
            except ValueError:
                dec = None
            if isinstance(dec, str):
                s = dec.strip()
            elif '"' not in s[1:-1].replace('\\"', ''):
                s = s[1:-1].replace('\\"', '"').strip()
        elif len(s) >= 2 and s[0] in "'`" and s[-1] == s[0] and s[0] not in s[1:-1]:
            s = s[1:-1].strip()
        elif len(s) >= 2 and QUOTE_PAIRS.get(s[0]) == s[-1]:
            s = s[1:-1].strip()
        s = re.sub(r'^\\+(?![()\[\]{}])', '', s)
        s = re.sub(r'\\+$', '', s).strip()
        if s == prev:
            break
    return s


def _walk(obj):
    if isinstance(obj, dict):
        return {clean_str(k) if isinstance(k, str) else k: _walk(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_walk(v) for v in obj]
    if isinstance(obj, str):
        return clean_str(obj)
    return obj


def sanitize_args(obj):
    if obj is None:
        return {}
    if isinstance(obj, str):
        try:
            obj = json.loads(clean_str(obj))
        except ValueError:
            return {}
    if not isinstance(obj, dict):
        return {}
    return _walk(obj)


def fetch_model_names():
    sid = new_session()
    obj = swarm_call("/API/ListModels", {
        "session_id": sid, "path": "", "depth": 20, "subtype": "Stable-Diffusion",
        "sortBy": "Name", "allowRemote": False, "dataImages": False,
    }, timeout=180)
    return [str(i.get("name")).strip() for i in (obj.get("files") or []) if i.get("name")]


def _norm_model(s):
    s = clean_str(str(s)).replace("\\", "/").lower()
    s = re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", s)
    return re.sub(r"[\s_\-]+", "", s)


def resolve_model(name):
    import difflib
    try:
        names = fetch_model_names()
    except Exception:
        return name
    if not names or name in names:
        return name
    target = _norm_model(name)
    norm = {}
    for n in names:
        norm.setdefault(_norm_model(n), n)
        norm.setdefault(_norm_model(n.rsplit("/", 1)[-1]), n)
    if target in norm:
        return norm[target]
    subs = sorted(set(v for k, v in norm.items() if len(target) >= 4 and (target in k or k in target)))
    if len(subs) == 1:
        return subs[0]
    close = difflib.get_close_matches(target, list(norm.keys()), n=2, cutoff=0.8)
    if len(close) == 1 or (len(close) == 2 and norm[close[0]] == norm[close[1]]):
        return norm[close[0]]
    shown = [re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", n) for n in names[:40]]
    raise ValueError("Model not found: %s. Available image models: %s. Ask the user to choose one and stop. Do not generate an image." % (name, "; ".join(shown)))


def _number(args, key, default, low, high, integer=False, warnings=None):
    if key not in args or args[key] is None or args[key] == "":
        return default
    try:
        val = float(args[key])
    except (TypeError, ValueError):
        raise ValueError("%s must be a number" % key)
    if integer:
        val = int(round(val))
    if val < low:
        val = low
        if warnings is not None:
            warnings.append("%s adjusted to the minimum %s" % (key, low))
    if val > high:
        val = high
        if warnings is not None:
            warnings.append("%s adjusted to the maximum %s" % (key, high))
    return int(val) if integer else float(val)


def sniff_type(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8"):
        return "image/jpeg"
    if data.startswith(b"GIF8"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return "image/png"


def load_image(url):
    s = str(url)
    if s.startswith("data:"):
        head, _, payload = s.partition(",")
        if ";base64" in head.lower():
            data = base64.b64decode(payload)
        else:
            data = urllib.parse.unquote_to_bytes(payload)
        mime = head[5:].split(";")[0].strip() or sniff_type(data)
        return data, mime
    full = s if s.lower().startswith(("http://", "https://")) else SWARM + "/" + s.lstrip("/")
    req = urllib.request.Request(full, headers={"User-Agent": "llama-image"})
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = resp.read()
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
    except Exception as e:
        raise RuntimeError("could not download the generated image: %s" % e)
    if not ctype.lower().startswith("image/"):
        ctype = sniff_type(data)
    return data, ctype


def store_image(raw, mime):
    ext = IMG_EXT.get(str(mime).lower()) or IMG_EXT.get(sniff_type(raw), "png")
    name = os.urandom(8).hex() + "." + ext
    with IMG_LOCK:
        IMG_STORE[name] = raw
        IMG_ORDER.append(name)
        while len(IMG_ORDER) > IMG_MAX:
            old = IMG_ORDER.pop(0)
            IMG_STORE.pop(old, None)
            IMG_META.pop(old, None)
    if IMAGE_DIR:
        try:
            os.makedirs(IMAGE_DIR, exist_ok=True)
            with open(os.path.join(IMAGE_DIR, name), "wb") as fh:
                fh.write(raw)
        except Exception as e:
            sys.stderr.write("could not save image to disk: %s\n" % e)
            sys.stderr.flush()
    return name


def get_stored_image(name):
    if not IMG_NAME_RE.match(name):
        return None
    with IMG_LOCK:
        raw = IMG_STORE.get(name)
    if raw is None and IMAGE_DIR:
        try:
            with open(os.path.join(IMAGE_DIR, name), "rb") as fh:
                raw = fh.read()
        except Exception:
            raw = None
    return raw


VISION_RULES = (
    "Describe only what is visible in the image. Do not guess or use the prompt as visual evidence. "
    "Say 'unclear' when a detail cannot be seen. Left and right mean the viewer's left and right. "
    "Count visible subjects before describing them. Be brief."
)
VISION_PROMPT = "Request for comparison only; it is not evidence of what appears in the image:\n%s\n\n"
VISION_REVIEW = (
    VISION_PROMPT +
    "Inspect the pixels first. Then compare them with the request. Answer in English with exactly these sections:\n"
    "SCENE: visible setting, composition, lighting, colors, style and text.\n"
    "SUBJECTS: actual number of people and other main subjects. Describe each person separately: position, pose, "
    "facing direction only if clear, hair, clothing and accessories. Say when subjects appear duplicated.\n"
    "MATCH: list every missing, extra, duplicated, wrong or unclear requested detail. Check the requested subject count. "
    "Do not say 'all present' unless you checked every detail.\n"
    "DEFECTS: check duplication, anatomy, merged parts, clothing or object glitches, artifacts, blur, cropping, "
    "unwanted text and watermarks. Write 'none seen' only after checking all of them."
)


def vision_ask(raw, mime, question, max_tokens=700):
    if LLAMA_PORT <= 0:
        return "", "llama-server port not provided"
    mime = str(mime or "").lower()
    if mime not in IMG_EXT:
        mime = IMG_MIME.get(IMG_EXT.get(sniff_type(raw), "png"), "image/png")
    url = "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode("ascii"))
    body = {
        "messages": [
            {"role": "user", "content": [
                {"type": "text", "text": VISION_RULES + "\n\n" + question},
                {"type": "image_url", "image_url": {"url": url}},
            ]},
        ],
        "max_tokens": max_tokens,
        "temperature": 0.2,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False, "reasoning_effort": "low"},
    }
    try:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request("http://127.0.0.1:%d/v1/chat/completions" % LLAMA_PORT, data=data,
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=240) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
        out = str(obj["choices"][0]["message"]["content"] or "")
        out = re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()
        out = re.sub(r"\n{3,}", "\n\n", out)
        if out:
            return out, ""
        return "", "empty reply from llama-server"
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", "replace")
        except Exception:
            detail = ""
        return "", ((("HTTP %s " % e.code) + " ".join(detail.split()))[:200])
    except Exception as e:
        return "", str(e)[:160]


TRANSLATE_SYSTEM = (
    "Translate the text below into English for an image model. Preserve every detail, count, action, relation, "
    "clothing item and requested style. Do not add, omit, soften or guess. Keep ambiguity when the original is unclear. "
    "Return only the translation."
)


PT_WORDS = re.compile(r"\b(um|uma|com|para|sem|dos|das|nos|nas|garota|garotas|mulher|mulheres|homem|vestido|fundo|cabelo|cabelos|olhos|nua|nu|seios|cidade|noite|branco|branca|preto|preta|azul|vermelho|vermelha)\b", re.I)


def needs_translation(text):
    if re.search(r"[À-ɏ]", text):
        return True
    return bool(PT_WORDS.search(text))


def translate_prompt(text):
    if LLAMA_PORT <= 0:
        return text, "llama-server port not provided"
    body = {
        "messages": [
            {"role": "user", "content": TRANSLATE_SYSTEM + "\n\nText to translate:\n" + text},
        ],
        "max_tokens": 512,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False, "reasoning_effort": "low"},
    }
    try:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request("http://127.0.0.1:%d/v1/chat/completions" % LLAMA_PORT, data=data,
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=45) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
        out = str(obj["choices"][0]["message"]["content"] or "")
        out = re.sub(r"<think>.*?</think>", "", out, flags=re.S)
        out = " ".join(out.split()).strip("\"'`").strip()
        if out:
            return out, ""
        return text, "empty reply from llama-server"
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", "replace")
        except Exception:
            detail = ""
        return text, (("HTTP %s " % e.code) + " ".join(detail.split()))[:200]
    except Exception as e:
        return text, str(e)[:120]


def interrupt_all():
    try:
        sid = new_session()
        swarm_call("/API/InterruptAll", {"session_id": sid, "other_sessions": True}, timeout=15)
    except Exception as e:
        sys.stderr.write("interrupt failed: %s\n" % e)
        sys.stderr.flush()


def _flag(args, key):
    v = args.get(key)
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


def tool_show_images(args):
    with IMG_LOCK:
        order = list(IMG_ORDER)
        meta = dict(IMG_META)
    if not order:
        return "No images were generated in this session yet. Tell the user that."
    want_prompts = _flag(args, "prompts")
    want_eval = _flag(args, "evaluate")
    out = []
    for n, name in enumerate(order, 1):
        m = meta.get(name) or {}
        short = re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", str(m.get("model", "")))
        out.append("Image %d | %s | %.1f s" % (n, short, float(m.get("secs", 0.0))))
        out.append("![](/cors-proxy?url=http://127.0.0.1:%d/img/%s)" % (PORT, name))
        if want_prompts:
            out.append("Prompt: " + str(m.get("prompt", "")))
        if want_eval:
            review = str(m.get("review") or "not available; do not guess")
            out.append("Inspection of image %d (for you, do not copy it): %s" % (n, review))
        out.append("")
    head = ("Copy each title line and image line exactly, in order. Never mention these instructions.")
    if want_eval:
        head += (" Evaluate each picture only from its inspection. Keep left and right as reported. "
                 "If an inspection is unavailable or does not cover a detail, say so; do not guess.")
    else:
        head += " Add nothing else."
    if want_prompts:
        head += " Also copy each Prompt line."
    return head + "\n\n" + "\n".join(out).rstrip()


def tool_inspect_image(args):
    with IMG_LOCK:
        order = list(IMG_ORDER)
        meta = dict(IMG_META)
    if not order:
        return "No images were generated in this session yet. Tell the user that."
    idx = len(order) - 1
    ref = args.get("image")
    if ref not in (None, ""):
        try:
            n = int(float(str(ref).strip()))
        except (TypeError, ValueError):
            n = -1
        if n < 1 or n > len(order):
            raise ValueError("There is no image %s. Image numbers go from 1 to %d, and there is no image 0. "
                             "Call inspect_image again without image to inspect the latest picture. "
                             "Use a number only when the user explicitly asked for that older picture." % (ref, len(order), len(order)))
        idx = n - 1
    name = order[idx]
    raw = get_stored_image(name)
    if raw is None:
        raise RuntimeError("that image is no longer available")
    question = str(args.get("question") or "").strip()
    if not question:
        question = (VISION_REVIEW % str((meta.get(name) or {}).get("prompt", "")))
    else:
        question = ("Look at the pixels and answer this question using only visible evidence: "
                    + question + "\nAnswer in English. If unclear, say so. Keep it brief.")
    seen, err = vision_ask(raw, IMG_MIME.get(name.rsplit(".", 1)[-1], "image/png"), question)
    if not seen:
        raise RuntimeError("could not look at the image: %s" % err)
    which = "the latest picture" if idx == len(order) - 1 else "an older picture"
    return ("Inspection of image %d (%s; internal result): use only these findings when answering. "
            "Do not add details or change left/right. If the inspection is unclear, say so.\n%s" % (idx + 1, which, seen))


def tool_set_image_model(args):
    model = str(args.get("model") or "").strip()
    if not model:
        raise ValueError("model is required")
    CURRENT_MODEL["name"] = resolve_model(model)
    short = re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", CURRENT_MODEL["name"])
    return ("Image model set to %s. If the user also requested a picture, call generate_image now. "
            "Otherwise, confirm the change briefly and stop. Do not select the model again." % short)


def tool_generate_image(args):
    prompt = str(args.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("prompt is required")
    model = CURRENT_MODEL["name"]
    if not model:
        raise ValueError("No image model chosen yet. Call list_models, ask the user which one to use, then call set_image_model.")
    interrupt_all()
    translate_err = ""
    if needs_translation(prompt):
        prompt, translate_err = translate_prompt(prompt)
    warnings = []
    width = _number(args, "width", DEFAULTS["width"], 64, 2048, True, warnings)
    height = _number(args, "height", DEFAULTS["height"], 64, 2048, True, warnings)
    width = max(64, min(2048, int(round(width / 8.0)) * 8))
    height = max(64, min(2048, int(round(height / 8.0)) * 8))
    req = dict(DEFAULTS)
    req.update({
        "prompt": prompt,
        "model": model,
        "images": 1,
        "steps": _number(args, "steps", DEFAULTS["steps"], 1, 150, True, warnings),
        "cfgscale": _number(args, "cfgscale", DEFAULTS["cfgscale"], 0, 30, False, warnings),
        "width": width,
        "height": height,
        "sampler": str(args.get("sampler") or DEFAULTS["sampler"]).strip(),
        "scheduler": str(args.get("scheduler") or DEFAULTS["scheduler"]).strip(),
        "donotsave": True,
        "donotsaveintermediates": True,
    })
    negative = args.get("negativeprompt")
    if negative is None:
        negative = args.get("negative_prompt")
    if negative is not None and str(negative).strip():
        req["negativeprompt"] = str(negative).strip()
    else:
        req["negativeprompt"] = DEFAULT_NEGATIVE
    seed = args.get("seed")
    if seed is not None and str(seed).strip() != "":
        try:
            seedv = int(float(seed))
        except (TypeError, ValueError):
            raise ValueError("seed must be an integer")
        req["seed"] = max(-1, seedv)
    if req.get("seed", -1) < 0:
        import random
        req["seed"] = random.randint(0, 2147483647)
    refine = args.get("refine")
    if refine is None or refine == "":
        refine = any(args.get(k) not in (None, "") for k in ("refinercontrolpercentage", "refinerupscale", "refinerupscalemethod"))
    elif isinstance(refine, str):
        refine = refine.strip().lower() in ("1", "true", "yes", "on")
    else:
        refine = bool(refine)
    if refine:
        req["refinercontrolpercentage"] = _number(args, "refinercontrolpercentage", 0.2, 0, 1, False, warnings)
        req["refinermethod"] = "PostApply"
        if args.get("refinerupscale") is not None and args.get("refinerupscale") != "":
            req["refinerupscale"] = _number(args, "refinerupscale", 1.0, 0.25, 8, False, warnings)
        method = str(args.get("refinerupscalemethod") or "").strip()
        if not method and req.get("refinerupscale", 1.0) != 1.0:
            method = "pixel-lanczos"
        if method:
            req["refinerupscalemethod"] = method
        tiling = args.get("refinerdotiling")
        if tiling is not None:
            if isinstance(tiling, str):
                req["refinerdotiling"] = tiling.strip().lower() in ("1", "true", "yes", "on")
            else:
                req["refinerdotiling"] = bool(tiling)
    sid = new_session()
    req["session_id"] = sid
    t0 = time.time()
    retried = False
    for attempt in range(2):
        obj = swarm_call("/API/GenerateText2Image", req, timeout=900)
        urls = obj.get("images") or []
        if not urls:
            raise RuntimeError("SwarmUI returned no image")
        first = load_image(urls[0])
        if attempt == 1 or len(first[0]) >= 10000 or width * height < 262144:
            break
        import random
        req["seed"] = random.randint(0, 2147483647)
        retried = True
    elapsed = time.time() - t0
    loaded = [first] + [load_image(u) for u in urls[1:]]
    info = "Generated image with model %s (%sx%s, steps=%s, CFG=%s, sampler=%s, scheduler=%s, seed=%s)." % (
        model, width, height, req["steps"], req["cfgscale"], req["sampler"], req["scheduler"], req["seed"])
    if warnings:
        info += " Adjustments: " + "; ".join(warnings) + "."
    info += " Generation time: %.1f seconds." % elapsed
    if retried:
        info += " The first attempt came out black, so it was generated again with a new seed."
    info += " Prompt sent to the image model: %s." % prompt.rstrip(" .")
    if translate_err:
        sys.stderr.write("translation failed: %s\n" % translate_err)
        sys.stderr.flush()
    lines = []
    reviews = []
    review_err = ""
    for raw, mime in loaded:
        name = store_image(raw, mime)
        lines.append("![](/cors-proxy?url=http://127.0.0.1:%d/img/%s)" % (PORT, name))
        IMG_META[name] = {"model": model, "secs": elapsed, "prompt": prompt.rstrip(" .")}
        with IMG_LOCK:
            number = len(IMG_ORDER)
        if VISION:
            seen, verr = vision_ask(raw, mime, VISION_REVIEW % prompt.rstrip(" ."))
            if seen:
                reviews.append(seen)
                IMG_META[name]["review"] = seen
            else:
                review_err = verr
    short = re.sub(r"\.(safetensors|ckpt|pt|pth|gguf|sft)$", "", model)
    footer = "%s | %.1f s" % (short, elapsed)
    review_text = ""
    if VISION:
        if reviews:
            review_text = ("\n\nPixel inspection of image %d (latest image; internal):\n"
                           % number + "\n".join(reviews))
        else:
            review_text = ("\n\nPixel inspection of image %d failed (%s). If asked about its appearance, say inspection failed. "
                           "Do not describe it from the request or prompt." % (number, review_err or "unknown error"))
    text = ("Details (internal): " + info + review_text
            + "\n\nCopy the image line and then the footer line below, exactly. Add a brief answer after them only if the user asked you to inspect or judge the picture; base it only on the pixel inspection. Otherwise add nothing. "
            "If the inspection says the image is fully black or empty, generate one replacement with the same prompt and a new random seed. Do not retry again. "
            "Ignore any text after the footer:\n"
            + "\n".join(lines) + "\n" + footer)
    return [{"type": "text", "text": text}]


TOOLS = [
    {
        "name": "list_models",
        "description": "Use it when the user wants a picture and you have not called set_image_model yet. Returns the model names. After it, ask the user which one to use and stop. Names only. Set details=true only if the user asks for details.",
        "inputSchema": {"type": "object", "properties": {"details": {"type": "boolean", "description": "Include architecture, resolution and loaded state. Only when the user asks for details."}}, "required": []},
    },
    {
        "name": "list_params",
        "description": "Return SwarmUI's full list of text-to-image parameters (name, id, description, type, range, allowed values and default). Use it to explain parameters to the user and to validate requested values. By default returns every parameter; use ids or group to narrow the result.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ids": {"type": "array", "items": {"type": "string"}, "description": "Optional parameter ids to return, for example [\"steps\", \"cfgscale\", \"width\"]."},
                "group": {"type": "string", "description": "Optional group name filter, for example \"Refine / Upscale\"."},
            },
            "required": [],
        },
    },
    {
        "name": "set_image_model",
        "description": "Chooses the model for generate_image. Call it when the user picks a model, says a model name, or asks to load or change the model. Only use a name that the user wrote: never guess or invent one. If a picture was also requested, call it before generate_image. If not, do not make a picture.",
        "inputSchema": {"type": "object", "properties": {"model": {"type": "string", "description": "Full image model name exactly as the user chose it."}}, "required": ["model"]},
    },
    {
        "name": "show_images",
        "description": "Shows all pictures made in this session, with model and time. Use it when the user asks to see, list or compare the pictures, or says they cannot see a picture. Set evaluate=true when the user also wants your opinion about them, and prompts=true only when the user wants the prompts.",
        "inputSchema": {"type": "object", "properties": {
            "evaluate": {"type": "boolean", "description": "True when the user also wants your evaluation of the pictures. Adds the stored visual inspection of each one."},
            "prompts": {"type": "boolean", "description": "True only when the user asks for the prompts used."},
        }, "required": []},
    },
    {
        "name": "generate_image",
        "description": "Makes one picture from an English prompt, with the model chosen by set_image_model. Call it only when the user asks for a picture and a model is chosen. Several people or objects can be in the same picture: describe all of them in one prompt. Write no text before the call.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "Positive prompt in English: what the user described, without inventing elements, style, quality tags or negative prompt."},
                "negative_prompt": {"type": "string", "description": "Negative prompt. A good default is already applied. Omit unless the user asks for a specific one, which then replaces the default."},
                "steps": {"type": "integer", "description": "Sampling steps (default 18, 1 to 150)."},
                "cfgscale": {"type": "number", "description": "CFG scale (default 3.5, 0 to 30)."},
                "width": {"type": "integer", "description": "Image width in pixels (default 800, 64 to 2048, multiple of 8)."},
                "height": {"type": "integer", "description": "Image height in pixels (default 800, 64 to 2048, multiple of 8)."},
                "sampler": {"type": "string", "description": "Sampler id (default euler_ancestral). Use values from list_params."},
                "scheduler": {"type": "string", "description": "Scheduler id (default normal). Use values from list_params."},
                "seed": {"type": "integer", "description": "Seed; -1 for random (default). To repeat a previous image (for example the same image with refine on), reuse the seed reported in that result together with the same prompt, model, size, steps, CFG, sampler and scheduler."},
                "refine": {"type": "boolean", "description": "Enable the refiner stage. Enabled automatically when any refiner* control is given. Off by default; only enable when the user asks."},
                "refinercontrolpercentage": {"type": "number", "description": "Refiner control percentage (default 0.2, 0 to 1)."},
                "refinerupscale": {"type": "number", "description": "Refiner upscale factor (0.25 to 8; 1 means no upscale). Omit unless asked."},
                "refinerupscalemethod": {"type": "string", "description": "Refiner upscale method id (default pixel-lanczos). Omit unless asked; values come from list_params."},
                "refinerdotiling": {"type": "boolean", "description": "Whether the refiner should use tiling. Omit unless asked."},
            },
            "required": ["prompt"],
        },
    },
]

HANDLERS = {"list_models": tool_list_models, "list_params": tool_list_params, "generate_image": tool_generate_image, "show_images": tool_show_images, "set_image_model": tool_set_image_model}
if VISION:
    TOOLS.append({
        "name": "inspect_image",
        "description": "Inspects the real pixels of a generated image. Omit image to inspect the latest picture. Set image only when the user explicitly asks about an older picture, using its number from show_images. Use it for a detail not covered by the existing inspection, or for a requested older picture.",
        "inputSchema": {"type": "object", "properties": {
            "question": {"type": "string", "description": "Specific question in English. Omit for a full review."},
            "image": {"type": "integer", "description": "Omit to inspect the latest picture. Set only for an older picture explicitly requested by the user, using its show_images number. Numbers start at 1. Image 0 does not exist."},
        }, "required": []},
    })
    HANDLERS["inspect_image"] = tool_inspect_image


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle_rpc(msg):
    if not isinstance(msg, dict):
        return rpc_error(None, -32600, "invalid request")
    if "id" not in msg:
        return None
    rid = msg["id"]
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        ver = params.get("protocolVersion") or "2025-03-26"
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "llama-image", "version": "1.0"},
        }}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        fn = HANDLERS.get(name)
        if fn is None:
            return rpc_error(rid, -32602, "unknown tool: %s" % name)
        try:
            value = fn(sanitize_args(params.get("arguments")))
            content = value if isinstance(value, list) else [{"type": "text", "text": str(value)}]
            err = False
        except Exception as e:
            sys.stderr.write("tool %s error: %s\n" % (name, e))
            sys.stderr.flush()
            content = [{"type": "text", "text": "Error: %s" % e}]
            err = True
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": content, "isError": err}}
    return rpc_error(rid, -32601, "method not found: %s" % method)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def host_ok(self):
        host = (self.headers.get("Host") or "").lower()
        name = host.rsplit(":", 1)[0] if not host.startswith("[") else host.split("]")[0] + "]"
        return name in ("127.0.0.1", "localhost", "[::1]")

    def send_body(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if not self.host_ok():
            return self.send_body(403)
        route = self.path.split("?")[0]
        if route == "/health":
            return self.send_body(200, b"ok", "text/plain")
        if route.startswith("/img/"):
            name = route[5:]
            raw = get_stored_image(name)
            if raw is None:
                return self.send_body(404, b"not found", "text/plain")
            ctype = IMG_MIME.get(name.rsplit(".", 1)[-1], "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(raw)
            return
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self.send_body(200 if self.host_ok() else 403)

    def do_POST(self):
        if not self.host_ok():
            return self.send_body(403)
        if self.path.split("?")[0] != "/mcp":
            return self.send_body(404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self.send_body(400, json.dumps(rpc_error(None, -32700, "parse error")).encode("utf-8"))
        if isinstance(payload, list):
            replies = [r for r in (handle_rpc(m) for m in payload) if r is not None]
            reply = replies or None
        else:
            reply = handle_rpc(payload)
        if reply is None:
            return self.send_body(202)
        self.send_body(200, json.dumps(reply, ensure_ascii=False).encode("utf-8"))


def watch_parent(pid):
    try:
        import ctypes
        k32 = ctypes.windll.kernel32
        handle = k32.OpenProcess(0x00100000, False, pid)
        if handle:
            k32.WaitForSingleObject(handle, 0xFFFFFFFF)
            if SWARM_PID:
                try:
                    subprocess.run(["taskkill", "/PID", str(SWARM_PID), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                except Exception:
                    pass
            os._exit(0)
    except Exception:
        pass


def main():
    if PARENT_PID:
        threading.Thread(target=watch_parent, args=(PARENT_PID,), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


if __name__ == "__main__":
    main()
'@
}
function Write-UiConfig {
    param([int]$ResearchPort = 0, [int]$ImagePort = 0, [bool]$ImageVision = $false)
    $date = (Get-Date).ToString('yyyy-MM-dd (dddd)', [System.Globalization.CultureInfo]::InvariantCulture)
    $servers = @()
    if ($ResearchPort -gt 0) {
        $servers += [ordered]@{ enabled = $true; id = 'c0a8e5d2-3f1b-4c7a-9b6e-2d4f8a1e7c30'; url = ('http://127.0.0.1:{0}/mcp' -f $ResearchPort); useProxy = $true }
    }
    if ($ImagePort -gt 0) {
        $servers += [ordered]@{ enabled = $true; id = '6f2d7a91-4c3e-4b85-8a10-9e5c2d7b4f61'; url = ('http://127.0.0.1:{0}/mcp' -f $ImagePort); useProxy = $true }
    }
    if ($servers.Count -eq 0) { return '' }

    $parts = @()
    $parts += ('Current date: {0}. Your training data is older than this date, so your memory is outdated and may be wrong. Reply in the language of the user.' -f $date)

    $parts += 'You have tools. When you need one, call it right away: write no text before the call, never write the call as text or code, and never say that you are about to call a tool. When the result comes back, do what the result tells you to do. Do not repeat the same call on your own.'

    if ($ResearchPort -gt 0) {
        $researchSearch = @(
            'If the user asks you to search something, always do it.',
            'Unless the answer is extremely obvious (greetings, simple math, code you can write directly, writing or translating text the user gave you), call web_search before answering, and never answer factual questions from memory. This includes news, people, companies, products, prices, dates, places, and anything you are not 100% sure about.',
            'The query is 2 to 6 short keywords. For broad requests, give web_search several different angles in queries, or use depth=deep.',
            'If the user gives a link or a site, call fetch_url with it. Never make up a link.'
        ) -join ' '
        $researchAnswer = @(
            'Answer only from the results.',
            'At the end of your answer, add a line Sources: (translated to the language of the user) followed by a bullet list with only the URLs you actually used, like: - https://example.com. Never list a source you did not use. If you did not search, write no Sources.'
        ) -join ' '
        $researchFail = @(
            'If the results do not answer the question, do not give up yet: try depth=deep, and use fetch_url on a page the results mention but did not include in full.',
            'After three failed tries, say plainly what you found and what you could not find. Never tell the user to search by themselves.'
        ) -join ' '
        $parts += @($researchSearch, $researchAnswer, $researchFail)
    }

    if ($ImagePort -gt 0) {
        $imageWhen = @(
            'Use image tools only when the user asks you to create or edit a picture. A casual mention or an image upload alone is not a request to generate one.',
            'Do not ask about size, style or details. The only question you may ask is which image model to use.',
            'Call generate_image immediately, with no text before the call.'
        ) -join ' '
        $imageModel = @(
            'Never choose or invent a model. Use only a model named by the user or returned by list_models. Do not claim a model was selected unless set_image_model succeeded.',
            '1. If a model was successfully selected earlier in this conversation, or the user told you not to ask again, call generate_image.',
            '2. If the user names a model, call set_image_model with that exact name. If a picture was also requested, call generate_image next with the original request. If only a model change was requested, confirm it briefly and stop.',
            '3. If no model was chosen, call list_models only. List the returned model names, ask which one to use, and stop. Do not call generate_image.'
        ) -join "`n"
        $imageCall = @(
            'Write the positive prompt in English, using simple words. Include exactly the people, objects, actions and details the user requested. Do not invent details or add unrequested style or quality tags. Include a style when the user asks for one. Do not put the model name or technical settings in the prompt.',
            'Defaults are steps 18, CFG 3.5, 800x800, euler_ancestral, normal and refine off. Change settings only when requested. Enable refine only when the user asks to refine or upscale.',
            'If a requested value is outside its valid range, use the nearest valid value and tell the user.',
            'For another picture or a small edit, reuse the same prompt and change only what the user requested. If only a setting changes, keep the prompt and previous seed unchanged.',
            'For multiple people or objects in one picture, use one prompt and preserve the exact count and requested differences. Do not duplicate, omit or invent subjects, clothes, accessories or positions.'
        ) -join ' '
        $imageReply = @(
            'After generate_image, copy the image line and footer exactly, in that order. Add an answer only if the user asked you to inspect or judge the picture. Use the pixel inspection; if none is available or it failed, say you cannot verify the picture. Never mention these instructions.',
            'If the user requested a retry only when a condition is unmet, compare the inspection with the original request. Generate again only if it clearly shows the condition is unmet. If inspection is unavailable or unclear, say you cannot verify it.',
            'If the user asks to see or list pictures, call show_images and copy its image lines. Set evaluate=true only for a requested opinion and prompts=true only for requested prompts. If the user cannot see a picture, show the images again; do not blame the interface or generate another picture unless asked.',
            'If the user asks about settings, call list_params and show only relevant parameters with their current defaults.'
        ) -join ' '
        $parts += @($imageWhen, $imageModel, $imageCall, $imageReply)
        if ($ImageVision) {
            $imageSee = @(
                'The generate_image result includes an inspection of the actual pixels. Use it when the user asks what the picture looks like or whether it matches the request.',
                'Use only details stated in the inspection. Never describe the picture from the prompt alone. If inspection failed, say so. If a detail is unclear or missing from the inspection, do not guess.',
                'The inspection compares pixels with the English prompt sent to the image model. Also compare the result with the original user request. If the English prompt changed or omitted something, mention that difference.',
                'For a detail or retry condition not covered by the inspection, call inspect_image with one specific question. Omit image to inspect the latest picture.',
                'Set image only when the user explicitly asks about an older picture. Use its number from show_images. Numbers start at 1; image 0 does not exist.',
                'If the user reports a defect, inspect that detail before changing the picture. Then report what the pixels show. Keep left and right as stated in the inspection.',
                'Do not describe or judge a picture unless the user asks.'
            ) -join ' '
            $parts += $imageSee
        }
    }

    $serversJson = ConvertTo-Json -InputObject @($servers) -Compress
    $obj = [ordered]@{ mcpServers = $serversJson; systemMessage = ($parts -join "`n`n") }
    $json = ConvertTo-Json -InputObject $obj -Compress
    $path = Join-Path $env:TEMP ('llama_webui_{0}.json' -f ([guid]::NewGuid().ToString('N')))
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $enc)
    return $path
}

function Get-LogTail {
    param([string]$Path, [int]$Count = 1)
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
        $lines = @(($txt -split "`r?`n") | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { return '' }
        return (($lines | Select-Object -Last $Count) -join ' | ')
    } catch {
        return ''
    }
}

function Start-ResearchServer {
    param([string]$LogPath, [int]$Ctx = 16384)
    $uv = Get-UvPath
    if (-not $uv) { return [pscustomobject]@{ Ok = $false; Error = 'uv não encontrado no PATH'; Port = 0; Proc = $null; Files = @() } }
    $port = Get-NextFreePort 5000
    $files = New-Object System.Collections.Generic.List[string]
    $pyPath = Join-Path $env:TEMP ('llama_research_{0}.py' -f ([guid]::NewGuid().ToString('N')))
    $outPath = Join-Path $env:TEMP ('llama_research_{0}.out' -f ([guid]::NewGuid().ToString('N')))
    $files.Add($pyPath); $files.Add($outPath)
    if ($LogPath) {
        $errPath = ($LogPath -replace '\.log$', '') + '_pesquisa.log'
    } else {
        $errPath = Join-Path $env:TEMP ('llama_research_{0}.err' -f ([guid]::NewGuid().ToString('N')))
        $files.Add($errPath)
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $result = [pscustomobject]@{ Ok = $false; Error = ''; Port = $port; Proc = $null; Files = $files; UiConfig = ''; ErrLog = $errPath }
    try {
        [System.IO.File]::WriteAllText($pyPath, ((Get-ResearchServerSource) -replace "`r`n", "`n"), $enc)
        $uvArgs = @('run', '--no-project', '--with', 'ddgs', '--with', 'trafilatura', 'python', ('"' + $pyPath + '"'), [string]$port, [string]$PID, [string]$Ctx)
        $proc = Start-Process -FilePath $uv -ArgumentList $uvArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $result.Proc = $proc
        $started = Get-Date
        $deadline = $started.AddSeconds(120)
        $shown = $false
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) {
                $result.Error = ('o servidor de pesquisa encerrou (código {0}): {1}' -f $proc.ExitCode, (Get-LogTail $errPath 3))
                break
            }
            try {
                $r = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/health' -f $port) -UseBasicParsing -TimeoutSec 1
                if ([int]$r.StatusCode -eq 200) { $result.Ok = $true; break }
            } catch { }
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            $room = (Get-UIWidth) - 30
            $tail = Get-LogTail $errPath 1
            if ($tail.Length -gt $room) { $tail = $tail.Substring(0, [Math]::Max(0, $room)) }
            $line = ('  Aguardando a pesquisa... {0}s  {1}' -f $elapsed, $tail)
            Write-Host ("`r" + $line.PadRight((Get-UIWidth))) -NoNewline -ForegroundColor DarkGray
            $shown = $true
            Start-Sleep -Milliseconds 400
        }
        if ($shown) { Write-Host '' }
        if (-not $result.Ok -and -not $result.Error) {
            $result.Error = ('tempo esgotado (120s); último log: {0} | arquivo: {1}' -f (Get-LogTail $errPath 2), $errPath)
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    if (-not $result.Ok) { Stop-ResearchServer $result }
    return $result
}

function Stop-ResearchServer {
    param($Research)
    if (-not $Research) { return }
    if ($Research.Proc) {
        try {
            if (-not $Research.Proc.HasExited) {
                Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$Research.Proc.Id, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null
            }
        } catch { }
        $Research.Proc = $null
    }
    foreach ($f in @($Research.Files)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
    $Research.Files = @()
    if ($Research.Ok -and $Research.ErrLog) {
        try { Remove-Item -LiteralPath $Research.ErrLog -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-ProcessTree {
    param($Proc)
    if (-not $Proc) { return }
    try {
        if (-not $Proc.HasExited) {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$Proc.Id, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null
        }
    } catch { }
}

function Start-SwarmUI {
    param([string]$BatPath, [string]$LogPath)
    $port = Get-NextFreePort 7801
    $result = [pscustomobject]@{ Ok = $false; Error = ''; Port = $port; Url = ('http://127.0.0.1:{0}' -f $port); Proc = $null; Files = @(); ErrLog = '' }
    if (-not (Test-Path -LiteralPath $BatPath -PathType Leaf)) {
        $result.Error = ('arquivo não encontrado: ' + $BatPath)
        return $result
    }
    $files = New-Object System.Collections.Generic.List[string]
    $outPath = Join-Path $env:TEMP ('llama_swarm_{0}.out' -f ([guid]::NewGuid().ToString('N')))
    $files.Add($outPath)
    if ($LogPath) {
        $errPath = ($LogPath -replace '\.log$', '') + '_swarmui.log'
    } else {
        $errPath = Join-Path $env:TEMP ('llama_swarm_{0}.err' -f ([guid]::NewGuid().ToString('N')))
        $files.Add($errPath)
    }
    $result.Files = $files
    $result.ErrLog = $errPath
    try {
        $wd = Split-Path -Parent $BatPath
        $cmdArgs = ('"' + $BatPath + '" --launch_mode none --host 127.0.0.1 --port ' + [string]$port)
        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmdArgs) -WorkingDirectory $wd -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $result.Proc = $proc
        $started = Get-Date
        $deadline = $started.AddSeconds(600)
        $shown = $false
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) {
                $tail = Get-LogTail $errPath 3
                if (-not $tail) { $tail = Get-LogTail $outPath 3 }
                $result.Error = ('o SwarmUI encerrou (código {0}): {1}' -f $proc.ExitCode, $tail)
                break
            }
            try {
                $resp = Invoke-RestMethod -Uri ($result.Url + '/API/GetNewSession') -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 3
                if ($resp.session_id) { $result.Ok = $true; break }
            } catch { }
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            $room = (Get-UIWidth) - 30
            $tail = Get-LogTail $errPath 1
            if (-not $tail) { $tail = Get-LogTail $outPath 1 }
            if ($tail.Length -gt $room) { $tail = $tail.Substring(0, [Math]::Max(0, $room)) }
            $line = ('  Aguardando o SwarmUI... {0}s  {1}' -f $elapsed, $tail)
            Write-Host ("`r" + $line.PadRight((Get-UIWidth))) -NoNewline -ForegroundColor DarkGray
            $shown = $true
            Start-Sleep -Milliseconds 500
        }
        if ($shown) { Write-Host '' }
        if (-not $result.Ok -and -not $result.Error) {
            $result.Error = ('tempo esgotado (600s); último log: {0} | arquivo: {1}' -f (Get-LogTail $errPath 2), $errPath)
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Start-ImageServer {
    param([string]$LogPath, [string]$BatPath, [int]$LlamaPort = 0, [bool]$Vision = $false)
    $port = Get-NextFreePort 6000
    $result = [pscustomobject]@{ Ok = $false; Error = ''; Port = $port; Proc = $null; Files = @(); ErrLog = ''; Swarm = $null; Url = '' }
    $uv = Get-UvPath
    if (-not $uv) {
        $result.Error = 'uv não encontrado no PATH'
        return $result
    }

    $swarm = Start-SwarmUI $BatPath $LogPath
    $result.Swarm = $swarm
    if (-not $swarm.Ok) {
        $result.Error = ('SwarmUI: ' + [string]$swarm.Error)
        Stop-ImageServer $result
        return $result
    }

    $imageSaveDir = ''
    $files = New-Object System.Collections.Generic.List[string]
    $pyPath = Join-Path $env:TEMP ('llama_image_{0}.py' -f ([guid]::NewGuid().ToString('N')))
    $outPath = Join-Path $env:TEMP ('llama_image_{0}.out' -f ([guid]::NewGuid().ToString('N')))
    $files.Add($pyPath); $files.Add($outPath)
    if ($LogPath) {
        $errPath = ($LogPath -replace '\.log$', '') + '_imagem.log'
    } else {
        $errPath = Join-Path $env:TEMP ('llama_image_{0}.err' -f ([guid]::NewGuid().ToString('N')))
        $files.Add($errPath)
    }
    $result.Files = $files
    $result.ErrLog = $errPath
    $result.Url = $swarm.Url
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($pyPath, ((Get-ImageServerSource) -replace "`r`n", "`n"), $enc)
        $swarmPid = 0
        if ($swarm.Proc) { $swarmPid = [int]$swarm.Proc.Id }
        $uvArgs = @('run', '--no-project', 'python', ('"' + $pyPath + '"'), [string]$port, [string]$PID, [string]$swarm.Url, [string]$swarmPid, [string]$LlamaPort, ('"' + $imageSaveDir + '"'), [string]([int][bool]$Vision))
        $proc = Start-Process -FilePath $uv -ArgumentList $uvArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $result.Proc = $proc
        $started = Get-Date
        $deadline = $started.AddSeconds(120)
        $shown = $false
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) {
                $result.Error = ('o servidor de imagem encerrou (código {0}): {1}' -f $proc.ExitCode, (Get-LogTail $errPath 3))
                break
            }
            try {
                $r = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/health' -f $port) -UseBasicParsing -TimeoutSec 1
                if ([int]$r.StatusCode -eq 200) { $result.Ok = $true; break }
            } catch { }
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            $room = (Get-UIWidth) - 30
            $tail = Get-LogTail $errPath 1
            if ($tail.Length -gt $room) { $tail = $tail.Substring(0, [Math]::Max(0, $room)) }
            $line = ('  Aguardando a geração de imagem... {0}s  {1}' -f $elapsed, $tail)
            Write-Host ("`r" + $line.PadRight((Get-UIWidth))) -NoNewline -ForegroundColor DarkGray
            $shown = $true
            Start-Sleep -Milliseconds 400
        }
        if ($shown) { Write-Host '' }
        if (-not $result.Ok -and -not $result.Error) {
            $result.Error = ('tempo esgotado (120s); último log: {0} | arquivo: {1}' -f (Get-LogTail $errPath 2), $errPath)
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    if (-not $result.Ok) { Stop-ImageServer $result }
    return $result
}

function Stop-ImageServer {
    param($Image)
    if (-not $Image) { return }
    if ($Image.Proc) {
        Stop-ProcessTree $Image.Proc
        $Image.Proc = $null
    }
    if ($Image.Swarm) {
        if ($Image.Swarm.Proc) {
            Stop-ProcessTree $Image.Swarm.Proc
            $Image.Swarm.Proc = $null
        }
        foreach ($f in @($Image.Swarm.Files)) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
        }
        $Image.Swarm.Files = @()
    }
    foreach ($f in @($Image.Files)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
    $Image.Files = @()
    if ($Image.Ok -and $Image.ErrLog) {
        try { Remove-Item -LiteralPath $Image.ErrLog -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Format-Command {
    param([string]$Exe, [string[]]$ServerArgs)
    $parts = @()
    foreach ($x in $ServerArgs) {
        if ($x -match '[\s"]') {
            $parts += ('"' + ($x -replace '"', '\"') + '"')
        } else {
            $parts += $x
        }
    }
    return ('"' + $Exe + '" ' + ($parts -join ' '))
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
function Test-PortFree {
    param([int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Test-LlamaHealth {
    param([int]$Port)
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $Port) -UseBasicParsing -TimeoutSec 1
        return ([int]$r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Get-NextFreePort {
    param([int]$Start)
    for ($p = $Start; $p -lt ($Start + 30); $p++) {
        if ($p -gt 65535) { break }
        if (Test-PortFree $p) { return $p }
    }
    return $Start
}

function Stop-LlamaPort {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            Stop-Process -Id ([int]$conn.OwningProcess) -Force -ErrorAction Stop
            return $true
        }
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# Small choice menu
# ---------------------------------------------------------------------------
function Show-Choice {
    param(
        [string]$Title,
        [string]$Message,
        [string[]]$Options,
        [int]$Default = 0
    )
    $sel = $Default
    if ($sel -lt 0 -or $sel -ge $Options.Count) { $sel = 0 }
    while ($true) {
        Clear-Screen
        Show-Header $Title
        Write-Host ''
        if ($Message) {
            foreach ($line in ($Message -split "`n")) {
                Write-Host ('  ' + (Cut-Text $line ((Get-UIWidth) - 3))) -ForegroundColor Gray
            }
            Write-Host ''
        }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $txt = '   ' + $Options[$i]
            if ($i -eq $sel) { $txt = ' > ' + $Options[$i] }
            Register-Hit $i
            Write-Row $txt ($i -eq $sel)
        }
        Write-Host ''
        Write-Footer '  ↑↓ navegar   Enter confirmar   Esc cancelar'
        $key = Read-Key
        if ($key.Key -eq 'MouseLeft') {
            if ($key.Index -ge 0 -and $key.Index -lt $Options.Count) { return $key.Index }
            continue
        }
        if ($key.Key -eq 'MouseRight') { return -1 }
        switch ($key.Key) {
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt ($Options.Count - 1)) { $sel++ } }
            'Home'      { $sel = 0 }
            'End'       { $sel = $Options.Count - 1 }
            'Enter'     { return $sel }
            'Escape'    { return -1 }
        }
    }
}

# ---------------------------------------------------------------------------
# Auto update
# ---------------------------------------------------------------------------
function Get-ContentHash {
    param([byte[]]$Bytes)
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF).Replace("`r", '').TrimEnd()
    $data = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($data)) } finally { $sha.Dispose() }
}

function Get-RemoteLauncher {
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $req = [System.Net.HttpWebRequest]::Create($script:UpdateUrl)
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $req.UserAgent = 'llama-launcher-updater'
        $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy -ArgumentList ([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $resp = $req.GetResponse()
        try {
            $ms = New-Object System.IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $bytes = $ms.ToArray()
        } finally {
            $resp.Close()
        }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($text -notmatch '(?m)^#===PS1===\r?$') { return $null }
        if ($text -notmatch '^\uFEFF?@echo off') { return $null }
        return ,$bytes
    } catch {
        return $null
    }
}

function Test-UpdateAvailable {
    $script:UpdateAvailable = $false
    $script:UpdateBytes = $null
    if ($env:LLAMA_UPDATED -eq '1') { return $false }
    $self = $env:LLAMA_BAT
    if ([string]::IsNullOrWhiteSpace($self) -or -not (Test-Path -LiteralPath $self)) { return $false }
    Write-Host '  Verificando atualizações...' -ForegroundColor DarkGray
    $remote = Get-RemoteLauncher
    if ($null -eq $remote) { return $false }
    try { $local = [System.IO.File]::ReadAllBytes($self) } catch { return $false }
    if ((Get-ContentHash $remote) -eq (Get-ContentHash $local)) { return $false }
    $script:UpdateBytes = $remote
    $script:UpdateAvailable = $true
    return $true
}

function Save-UpdateFile {
    $target = $env:LLAMA_NEW
    if ([string]::IsNullOrWhiteSpace($target) -or $null -eq $script:UpdateBytes) { return $false }
    try {
        [System.IO.File]::WriteAllBytes($target, $script:UpdateBytes)
        return $true
    } catch {
        return $false
    }
}

function Get-UpdateFooter {
    if ($script:UpdateAvailable) { return '   A atualizar' }
    return ''
}

function Install-LauncherUpdate {
    if (Save-UpdateFile) { return $true }
    Clear-Screen
    Write-Host ''
    Write-Host '  Não foi possível preparar a atualização.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Pressione qualquer tecla para continuar.' -ForegroundColor DarkGray
    [void](Read-Key)
    return $false
}

function Show-UpdatePrompt {
    $message = 'Uma atualização do Llama Launcher está disponível.'
    $buttons = @(
        [pscustomobject]@{ Key = 'A'; Text = ' A  Atualizar ' },
        [pscustomobject]@{ Key = 'D'; Text = ' D  Dispensar ' }
    )
    $gap = 4
    $sel = 0
    while ($true) {
        Clear-Screen
        $w = Get-UIWidth
        $h = 24
        try { $h = [Console]::WindowHeight } catch { }
        $top = [Math]::Max(1, [int][Math]::Floor(($h - 4) / 2))
        for ($i = 0; $i -lt $top; $i++) { Write-Host '' }
        $pad = [Math]::Max(0, [int][Math]::Floor(($w - $message.Length) / 2))
        Write-Host ((' ' * $pad) + $message) -ForegroundColor White
        Write-Host ''

        $total = $gap * ($buttons.Count - 1)
        foreach ($b in $buttons) { $total += $b.Text.Length }
        $x = [Math]::Max(0, [int][Math]::Floor(($w - $total) / 2))
        $y = [int][Console]::CursorTop
        $hits = @()
        Write-Host (' ' * $x) -NoNewline
        for ($i = 0; $i -lt $buttons.Count; $i++) {
            $b = $buttons[$i]
            if ($i -gt 0) {
                Write-Host (' ' * $gap) -NoNewline
                $x += $gap
            }
            if ($i -eq $sel) {
                Write-Host $b.Text -NoNewline -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $b.Text -NoNewline -ForegroundColor Gray -BackgroundColor DarkGray
            }
            $hits += [pscustomobject]@{ Y = $y; X1 = $x; X2 = ($x + $b.Text.Length - 1); Key = $b.Key }
            $x += $b.Text.Length
        }
        Write-Host ''
        $script:FootHit = $hits

        $key = Read-Key
        switch ([string]$key.Key) {
            'A'          { return $true }
            'D'          { return $false }
            'Escape'     { return $false }
            'Enter'      { return ($sel -eq 0) }
            'LeftArrow'  { $sel = 0 }
            'RightArrow' { $sel = 1 }
            'Tab'        { $sel = 1 - $sel }
        }
    }
}

# ---------------------------------------------------------------------------
# Model picker
# ---------------------------------------------------------------------------
function Show-ModelPicker {
    param([string]$CurrentPath = '')

    $sel = 0
    $rebuild = $true
    $rows = @()

    while ($true) {
        if ($rebuild) {
            $rows = @()
            if ($script:LastCfg) {
                $rows += [pscustomobject]@{ Kind = 'last'; Model = $script:LastCfg.Model }
            }
            foreach ($m in $script:Models) {
                $rows += [pscustomobject]@{ Kind = 'model'; Model = $m }
            }

            $sel = 0
            if ($CurrentPath) {
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    if ($rows[$i].Kind -eq 'model' -and $rows[$i].Model.Path -eq $CurrentPath) { $sel = $i; break }
                }
            } elseif (-not $script:LastCfg) {
                $sel = 0
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    if ($rows[$i].Kind -eq 'model' -and (Get-ModelStatusShort $rows[$i].Model) -eq 'cabe na GPU') {
                        $sel = $i
                        break
                    }
                }
            }
            $rebuild = $false
        }

        Clear-Screen
        Show-Header 'Escolha o modelo'
        Write-Host ''

        if ($rows.Count -eq 0) {
            Write-Host '  Nenhum modelo .gguf encontrado.' -ForegroundColor Yellow
            Write-Host ('  Pasta: ' + $script:ModelsDir) -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  Coloque os arquivos .gguf em subpastas de Modelos e pressione R.' -ForegroundColor Gray
            Write-Host ''
            Write-Footer ('  R recarregar' + (Get-UpdateFooter) + '   Q sair')
            $key = Read-Key
            if ($key.Key -eq 'Q') { return [pscustomobject]@{ Action = 'exit' } }
            if ($key.Key -eq 'A' -and $script:UpdateAvailable) { return [pscustomobject]@{ Action = 'update' } }
            if ($key.Key -eq 'R' -or $key.Key -eq 'F5') { Update-Hardware; Refresh-Models; $rebuild = $true }
            continue
        }

        $w = Get-UIWidth
        $nameW = [Math]::Max(20, $w - 48)
        $typeW = 13
        $statusW = 17

        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $rows[$i]
            $isSel = ($i -eq $sel)
            $prefix = '   '
            if ($isSel) { $prefix = ' > ' }
            Register-Hit $i

            if ($row.Kind -eq 'last') {
                $lc = $script:LastCfg
                $label = ('Última config: {0}  |  {1} ctx  |  KV {2}/{3}  |  porta {4}' -f `
                    $lc.Model.Display, (Format-Tokens $lc.Ctx), $lc.Ctk, $lc.Ctv, $lc.Port)
                $txt = $prefix + '* ' + $label
                Write-Row $txt $isSel 'Cyan'
                Write-Host ''
            } else {
                $m = $row.Model
                $type = Get-ModelTypeLabel $m
                if ($m.HasVision) { $type += ' [V]' }
                $status = Get-ModelStatusShort $m
                $color = 'Red'
                if ($status -eq 'cabe na GPU') { $color = 'Green' }
                elseif ($status -eq 'offload parcial') { $color = 'Yellow' }
                elseif ($status -eq 'CPU' -or $status -eq 'GPU?') { $color = 'DarkGray' }

                $name = Fit-Text $m.Display $nameW
                $size = '{0,8}' -f (Format-GB $m.Size)
                $typ = Fit-Text $type $typeW
                $sta = Fit-Text $status $statusW
                $txt = $prefix + $name + ' ' + $size + '  ' + $typ + ' ' + $sta
                Write-Row $txt $isSel $color
            }
        }

        Write-Host ''
        $footer = '  ↑↓ navegar   Enter abrir   L última   E editar última   R recarregar' + (Get-UpdateFooter) + '   Q sair'
        Write-Footer $footer

        $key = Read-Key
        $kn = [string]$key.Key
        if ($kn -eq 'MouseLeft') {
            if ($key.Index -ge 0 -and $key.Index -lt $rows.Count) { $sel = $key.Index; $kn = 'Enter' } else { continue }
        } elseif ($kn -eq 'MouseRight') { continue }
        switch ($kn) {
            'UpArrow' {
                if ($sel -gt 0) { $sel-- }
            }
            'DownArrow' {
                if ($sel -lt ($rows.Count - 1)) { $sel++ }
            }
            'Home' { $sel = 0 }
            'End'  { $sel = $rows.Count - 1 }
            'PageUp' { $sel = [Math]::Max(0, $sel - 5) }
            'PageDown' { $sel = [Math]::Min($rows.Count - 1, $sel + 5) }
            { $_ -in 'R', 'F5' } {
                Update-Hardware
                Refresh-Models
                $rebuild = $true
            }
            'A' {
                if ($script:UpdateAvailable) { return [pscustomobject]@{ Action = 'update' } }
            }
            'L' {
                if ($script:LastCfg) { return [pscustomobject]@{ Action = 'last' } }
            }
            'E' {
                if ($script:LastCfg) { return [pscustomobject]@{ Action = 'editlast'; Model = $script:LastCfg.Model } }
            }
            'RightArrow' {
                if ($rows[$sel].Kind -eq 'last') {
                    return [pscustomobject]@{ Action = 'editlast'; Model = $script:LastCfg.Model }
                }
            }
            'Enter' {
                $row = $rows[$sel]
                if ($row.Kind -eq 'last') {
                    return [pscustomobject]@{ Action = 'last' }
                }
                return [pscustomobject]@{ Action = 'model'; Model = $row.Model }
            }
            'Q'      { return [pscustomobject]@{ Action = 'exit' } }
        }
    }
}

# ---------------------------------------------------------------------------
# Settings screen
# ---------------------------------------------------------------------------
function Get-SettingsRows {
    param($Cfg)
    $mi = Get-MemoryEstimate $Cfg
    $rows = @()
    $rows += [pscustomobject]@{ Key = 'model'; Label = 'Modelo'; Value = $Cfg.Model.Display; Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'preset'; Label = 'Preset'; Value = (Get-PresetLabel $Cfg.Preset); Color = 'Cyan' }
    $rows += [pscustomobject]@{ Key = 'ctx'; Label = 'Contexto'; Value = ('{0} tokens  (máx. {1})' -f (Format-Tokens $Cfg.Ctx), (Format-Tokens (Get-MaxCtx $Cfg.Model))); Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'batch'; Label = 'Batch'; Value = (Get-BatchLabel $Cfg.Batch); Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'kv'; Label = 'KV cache'; Value = ('{0}  ~{1:0.0} GB' -f (Find-KvOption $Cfg).Label, $mi.KvGB); Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'cacheram'; Label = 'Cache de prompt'; Value = (Get-CacheRamLabel $Cfg); Color = 'White' }
    if ([int]$Cfg.NPredict -lt 0) {
        $np = '-1 (ilimitado)'
    } else {
        $np = ('{0} tokens' -f $Cfg.NPredict)
    }
    $rows += [pscustomobject]@{ Key = 'npredict'; Label = 'Máx. resposta'; Value = $np; Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'ngl'; Label = 'GPU'; Value = (Get-NglLabel $Cfg.Ngl $Cfg.Model); Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'threads'; Label = 'Threads'; Value = (Get-ThreadsLabel $Cfg.Threads); Color = 'White' }
    if ($Cfg.Model.Mmproj) {
        $rows += [pscustomobject]@{ Key = 'vision'; Label = 'Visão'; Value = (Get-VisionLabel $Cfg); Color = 'White' }
    }
    $imageColor = 'White'
    if ($Cfg.Image -eq 'on') { $imageColor = 'Cyan' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath) -and -not (Test-Path -LiteralPath ([string]$Cfg.ImagePath) -PathType Leaf)) { $imageColor = 'Red' }
    $rows += [pscustomobject]@{ Key = 'image'; Label = 'Geração de Imagem'; Value = (Get-ImageLabel $Cfg); Color = $imageColor }
    $agentColor = 'White'
    if ($Cfg.Agent -eq 'on') { $agentColor = 'Yellow' }
    $rows += [pscustomobject]@{ Key = 'agent'; Label = 'Agente'; Value = (Get-AgentLabel $Cfg.Agent); Color = $agentColor }
    $researchColor = 'White'
    if ($Cfg.Research -eq 'on') { $researchColor = 'Cyan' }
    $rows += [pscustomobject]@{ Key = 'research'; Label = 'Pesquisa'; Value = (Get-ResearchLabel $Cfg.Research); Color = $researchColor }
    if ($Cfg.Model.Meta.HasThinking) {
        $reason = $Cfg.Reasoning
        if ($reason -eq 'on') { $reason = 'ligado' }
        elseif ($reason -eq 'off') { $reason = 'desligado' }
        $rows += [pscustomobject]@{ Key = 'reasoning'; Label = 'Raciocínio'; Value = $reason; Color = 'White' }
    }
    $rows += [pscustomobject]@{ Key = 'template'; Label = 'Template'; Value = (Get-TemplateLabel $Cfg.Template); Color = 'White' }
    $portColor = 'White'
    if (-not (Test-PortFree ([int]$Cfg.Port))) { $portColor = 'Red' }
    $rows += [pscustomobject]@{ Key = 'port'; Label = 'Porta'; Value = ([string]$Cfg.Port); Color = $portColor }
    $rows += [pscustomobject]@{ Key = 'host'; Label = 'Rede'; Value = (Get-HostLabel $Cfg.Host); Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'browser'; Label = 'Navegador'; Value = (Get-BrowserLabel $Cfg.Browser); Color = 'White' }
    $rows += (Get-BenchRow $Cfg)
    $rows += [pscustomobject]@{ Key = 'start'; Label = 'INICIAR SERVIDOR'; Value = ''; Color = 'Green' }
    return $rows
}

function Change-CfgSetting {
    param($Cfg, [string]$Key, [int]$Direction)
    switch ($Key) {
        'preset' {
            $list = @('recomendado', 'qualidade', 'longo', 'cpu')
            $idx = [Array]::IndexOf($list, $Cfg.Preset)
            if ($idx -lt 0) { $idx = 0 } else { $idx = ($idx + $Direction + $list.Count) % $list.Count }
            Apply-Preset $Cfg $list[$idx]
            return
        }
        'ctx' {
            $opts = Get-CtxOptions $Cfg.Model
            $Cfg.Ctx = [int](Cycle-List $opts $Cfg.Ctx $Direction)
        }
        'kv' {
            Cycle-KvOption $Cfg $Direction
        }
        'npredict' {
            $opts = @(-1, 256, 512, 1024, 2048, 4096)
            $Cfg.NPredict = [int](Cycle-List $opts $Cfg.NPredict $Direction)
        }
        'ngl' {
            $opts = @('auto', '0', 'all')
            $Cfg.Ngl = [string](Cycle-List $opts $Cfg.Ngl $Direction)
        }
        'vision' {
            $opts = @('off', 'gpu', 'cpu')
            $Cfg.Vision = [string](Cycle-List $opts $Cfg.Vision $Direction)
        }
        'reasoning' {
            $opts = @('auto', 'on', 'off')
            $Cfg.Reasoning = [string](Cycle-List $opts $Cfg.Reasoning $Direction)
        }
        'threads' {
            $Cfg.Threads = 'auto'
        }
        'batch' {
            $opts = @('auto', '256', '512', '1024', '2048', '4096')
            $Cfg.Batch = [string](Cycle-List $opts $Cfg.Batch $Direction)
        }
        'cacheram' {
            $opts = @('auto', 'off')
            $Cfg.CacheRam = [string](Cycle-List $opts $Cfg.CacheRam $Direction)
        }
        'template' {
            $opts = @('auto', 'chatml')
            $Cfg.Template = [string](Cycle-List $opts $Cfg.Template $Direction)
        }
        'port' {
            $opts = @(5001, 5002, 8081, 8082)
            $Cfg.Port = [int](Cycle-List $opts $Cfg.Port $Direction)
        }
        'host' {
            $opts = @('127.0.0.1', '0.0.0.0', 'tailscale')
            $Cfg.Host = [string](Cycle-List $opts $Cfg.Host $Direction)
        }
        'browser' {
            $opts = @('llamacpp', 'openwebui', 'none')
            $Cfg.Browser = [string](Cycle-List $opts $Cfg.Browser $Direction)
        }
        'agent' {
            $opts = @('off', 'on')
            $Cfg.Agent = [string](Cycle-List $opts $Cfg.Agent $Direction)
        }
        'research' {
            $opts = @('off', 'on')
            $Cfg.Research = [string](Cycle-List $opts $Cfg.Research $Direction)
        }
        'image' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) {
                if ($Cfg.Image -eq 'on') { $Cfg.Image = 'off' } else { $Cfg.Image = 'on' }
            }
        }
        default { return }
    }
    if (@('preset', 'port', 'host', 'browser', 'agent', 'research', 'image', 'template', 'threads', 'cacheram', 'batch') -notcontains $Key) {
        $Cfg.Preset = 'personalizado'
    }
    Normalize-Cfg $Cfg
}

function Write-SettingRow {
    param($Row, [bool]$Selected)
    $w = Get-UIWidth
    if ($Row.Key -eq 'start') {
        if ($Selected) { $txt = ' > INICIAR SERVIDOR' } else { $txt = '   INICIAR SERVIDOR' }
        Write-Row $txt $Selected 'Green'
        return
    }
    if ($Row.Key -eq 'bench') {
        $prefix = '   '
        if ($Selected) { $prefix = ' > ' }
        $txt = (Fit-Text ($prefix + $Row.Label) 17) + ' ' + (Cut-Text ([string]$Row.Value) ($w - 18))
        if ($Selected) {
            Write-Row $txt $true
        } else {
            Write-Host (Fit-Text $txt $w) -ForegroundColor $Row.Color
        }
        return
    }
    $label = Fit-Text ('  ' + $Row.Label) 17
    $value = Cut-Text ([string]$Row.Value) ($w - 18)
    $txt = $label + ' ' + $value
    if ($Selected) {
        Write-Row $txt $true
    } else {
        Write-Host (Fit-Text $txt $w) -ForegroundColor $Row.Color
    }
}

function Get-BenchRow {
    param($Cfg)
    $label = 'BENCHMARK'
    $value = ''
    $color = 'Cyan'
    if ($script:BenchRunning) {
        $label = 'CANCELAR'
        $value = [string]$script:BenchText
        $color = 'Yellow'
    } elseif ($script:Bench.ContainsKey([string]$Cfg.Model.Path)) {
        $value = [string]$script:Bench[[string]$Cfg.Model.Path]
        if ($value -eq 'falhou') { $color = 'Red' }
    }
    return [pscustomobject]@{ Key = 'bench'; Label = $label; Value = $value; Color = $color }
}

function Get-RowTop {
    param([int]$Index)
    foreach ($k in @($script:Hit.Keys)) {
        if ([int]$script:Hit[$k] -eq $Index) { return [int]$k }
    }
    return -1
}

function Update-BenchRow {
    param($Cfg, [int]$Top, [string]$Text)
    $script:BenchText = $Text
    if ($Top -lt 0) { return }
    try {
        $l = [Console]::CursorLeft
        $t = [Console]::CursorTop
        [Console]::SetCursorPosition(0, $Top)
        Write-SettingRow (Get-BenchRow $Cfg) $true
        [Console]::SetCursorPosition($l, $t)
    } catch { }
}

function Test-BenchCancel {
    param([int]$Top = -1)
    try {
        if ($script:MouseOk) {
            while ($true) {
                $e = [LlamaConsole]::TryRead()
                if ($null -eq $e) { break }
                if ($e.Kind -eq 1 -and ($e.Key -eq 'Escape' -or $e.Key -eq 'Enter')) { return $true }
                if ($e.Kind -eq 2 -and [int]$e.Y -eq $Top) { return $true }
            }
            return $false
        }
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape' -or $k.Key -eq 'Enter') { return $true }
        }
    } catch { }
    return $false
}

function Invoke-BenchRequest {
    param($Cfg, [int]$Top, [int]$Port, $Prompt, [int]$NPredict, [bool]$Report)
    $result = [pscustomobject]@{ Status = 'error'; Timings = $null }
    $req = $null
    $resp = $null
    $reader = $null
    try {
        if ($Prompt -is [string]) {
            $promptJson = ($Prompt | ConvertTo-Json -Compress)
        } else {
            $promptJson = '[' + (($Prompt) -join ',') + ']'
        }
        $extra = ''
        if ($Report) { $extra = ',"return_progress":true' }
        $body = '{"prompt":' + $promptJson + ',"n_predict":' + $NPredict + ',"temperature":0,"ignore_eos":true,"cache_prompt":false,"stream":true' + $extra + '}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/completion' -f $Port))
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Proxy = $null
        $req.Timeout = 7200000
        $req.ReadWriteTimeout = 7200000
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
        $respTask = $req.GetResponseAsync()
        while (-not $respTask.Wait(100)) {
            if (Test-BenchCancel $Top) { $result.Status = 'cancel'; return $result }
        }
        $resp = $respTask.Result
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $count = 0
        while ($true) {
            $lineTask = $reader.ReadLineAsync()
            while (-not $lineTask.Wait(100)) {
                if (Test-BenchCancel $Top) { $result.Status = 'cancel'; return $result }
            }
            $line = $lineTask.Result
            if ($null -eq $line) { break }
            if (-not $line.StartsWith('data:')) { continue }
            $json = $line.Substring(5).Trim()
            if ($json -eq '' -or $json -eq '[DONE]') { continue }
            $obj = $json | ConvertFrom-Json
            if ($obj.error) { break }
            if ($obj.prompt_progress) {
                if ($Report -and [double]$obj.prompt_progress.total -gt 0) {
                    $pp = [int][Math]::Min(100, [Math]::Floor(100.0 * [double]$obj.prompt_progress.processed / [double]$obj.prompt_progress.total))
                    Update-BenchRow $Cfg $Top ('Processando prompt {0}%' -f $pp)
                }
                continue
            }
            if ($obj.stop -eq $true) {
                if ($obj.timings) { $result.Timings = $obj.timings; $result.Status = 'ok' }
                break
            }
            $count++
            if ($Report -and $count -le $NPredict) {
                Update-BenchRow $Cfg $Top ('Escrevendo {0}/{1}' -f $count, $NPredict)
            }
        }
        if ($result.Status -eq 'ok' -and $Report) {
            Update-BenchRow $Cfg $Top ('Escrevendo {0}/{0}' -f $NPredict)
            Start-Sleep -Milliseconds 250
        }
    } catch {
        $result.Status = 'error'
    } finally {
        try { if ($reader) { $reader.Dispose() } } catch { }
        try { if ($resp) { $resp.Close() } } catch { }
        try { if ($req) { $req.Abort() } } catch { }
    }
    return $result
}

function Get-BenchPrompt {
    param([int]$Port, [string]$BaseText, [int]$Ctx)
    $nCtx = $Ctx
    try {
        $props = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/props' -f $Port) -TimeoutSec 10
        $v = [int]$props.default_generation_settings.n_ctx
        if ($v -gt 0) { $nCtx = $v }
    } catch { }
    $json = @{ content = $BaseText; add_special = $false } | ConvertTo-Json -Compress
    $tok = Invoke-RestMethod -Method Post -Uri ('http://127.0.0.1:{0}/tokenize' -f $Port) -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
    $base = @($tok.tokens | ForEach-Object { [int]$_ })
    if ($base.Count -eq 0) { throw 'tokenize' }
    $target = [Math]::Max(16, $nCtx - 116)
    $ids = New-Object 'System.Collections.Generic.List[int]'
    while ($ids.Count -lt $target) { $ids.AddRange([int[]]$base) }
    if ($ids.Count -gt $target) { $ids.RemoveRange($target, $ids.Count - $target) }
    return ,$ids.ToArray()
}

function Invoke-Benchmark {
    param($Cfg, [int]$Top)
    $path = [string]$Cfg.Model.Path
    $script:BenchRunning = $true
    $proc = $null
    $tag = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP ('llama_bench_' + $tag + '.out')
    $errFile = Join-Path $env:TEMP ('llama_bench_' + $tag + '.err')
    $status = 'error'
    $final = $null
    try {
        Update-BenchRow $Cfg $Top 'Iniciando...'
        if (-not (Test-Path -LiteralPath $script:ServerExe) -or -not (Test-Path -LiteralPath $path)) { throw 'arquivo' }
        $port = Get-NextFreePort ([int]$Cfg.Port + 1)
        $c = $Cfg | Select-Object *
        $c.Host = '127.0.0.1'
        $c.Port = $port
        $c.Agent = 'off'
        $srvArgs = @(Build-ServerArgs $c '' '')
        $argLine = (@($srvArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
        $proc = Start-Process -FilePath $script:ServerExe -ArgumentList $argLine -WorkingDirectory $script:Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $total = [double]$Cfg.Model.Size
        if ($total -le 0) { $total = 1 }
        $ready = $false
        $cancel = $false
        $deadline = [datetime]::UtcNow.AddMinutes(20)
        while ([datetime]::UtcNow -lt $deadline) {
            if (Test-BenchCancel $Top) { $cancel = $true; break }
            if ($proc.HasExited) { break }
            if (Test-LlamaHealth $port) { $ready = $true; break }
            $pct = 0
            try {
                $p = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $proc.Id)
                if ($p) { $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * [double]$p.ReadTransferCount / $total)) }
            } catch { }
            Update-BenchRow $Cfg $Top ('Carregando modelo... {0}%' -f $pct)
            Start-Sleep -Milliseconds 300
        }

        if ($cancel) {
            $status = 'cancel'
        } elseif ($ready) {
            $baseText = 'Escreva um texto longo e detalhado sobre a história da computação, dos primeiros ábacos aos modelos de linguagem atuais. '
            Update-BenchRow $Cfg $Top 'Aquecendo...'
            $warm = Invoke-BenchRequest $Cfg $Top $port ($baseText * 4) 4 $false
            if ($warm.Status -eq 'cancel') {
                $status = 'cancel'
            } elseif ($warm.Status -eq 'ok') {
                Update-BenchRow $Cfg $Top 'Preparando prompt...'
                $fullPrompt = Get-BenchPrompt $port $baseText ([int]$Cfg.Ctx)
                Update-BenchRow $Cfg $Top 'Processando prompt...'
                $run = Invoke-BenchRequest $Cfg $Top $port $fullPrompt 100 $true
                if ($run.Status -eq 'ok') {
                    $final = $run.Timings
                    $status = 'ok'
                } elseif ($run.Status -eq 'cancel') {
                    $status = 'cancel'
                }
            }
        }
    } catch {
        $status = 'error'
    } finally {
        Stop-ProcessTree $proc
        if ($proc) {
            try { [void]$proc.WaitForExit(5000) } catch { }
            try { $proc.Dispose() } catch { }
        }
        foreach ($f in @($outFile, $errFile)) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
        Enable-Mouse
        $script:BenchRunning = $false
    }

    if ($status -eq 'ok') {
        $script:Bench[$path] = ('Proc. {0:N0} t/s  ·  Escrita {1:N1} t/s' -f [double]$final.prompt_per_second, [double]$final.predicted_per_second)
    } elseif ($status -eq 'error') {
        $script:Bench[$path] = 'falhou'
    }
    Update-Hardware
}

function Show-Settings {
    param($Cfg)
    $sel = -1
    $nglBuf = ''
    $snap0 = Get-CfgSnap $Cfg
    $autoBench = $false

    while ($true) {
        $rows = @(Get-SettingsRows $Cfg)
        if ($sel -lt 0 -or $sel -ge $rows.Count) {
            $sel = 0
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ($rows[$i].Key -eq 'start') { $sel = $i; break }
            }
        }

        $w = Get-UIWidth
        Clear-Screen
        Show-Header 'Configuração do servidor'
        Write-Host ''
        Write-Host ('  ' + $Cfg.Model.Display) -ForegroundColor White
        $meta = @()
        if ($Cfg.Model.Quant) { $meta += $Cfg.Model.Quant }
        $meta += (Get-ModelTypeLabel $Cfg.Model)
        $meta += ('ctx nativo ' + (Format-Tokens (Get-MaxCtx $Cfg.Model)))
        $meta += (Format-GB $Cfg.Model.Size)
        if ($Cfg.Model.HasVision) { $meta += 'visão disponível' }
        Write-Host ('  ' + (Cut-Text ($meta -join '  ·  ') ($w - 3))) -ForegroundColor DarkGray
        Write-Host ''

        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Key -eq 'bench') {
                Write-Host ('  ' + ('-' * [Math]::Max(10, $w - 4))) -ForegroundColor DarkGray
            }
            Register-Hit $i
            Write-SettingRow $rows[$i] ($i -eq $sel)
        }

        $mi = Get-MemoryEstimate $Cfg
        Write-Host ''

        $tag = '!'
        $color = 'Red'
        if ($mi.Level -eq 'good') { $tag = 'OK'; $color = 'Green' }
        elseif ($mi.Level -eq 'warn') { $tag = '~'; $color = 'Yellow' }
        elseif ($mi.Level -eq 'dim') { $tag = 'CPU'; $color = 'DarkGray' }
        Write-Host ('  [' + $tag + '] ' + $mi.Text) -ForegroundColor $color
        if ($mi.Level -eq 'bad') {
            $hint = 'Reduza o contexto/KV ou use GPU automática.'
            if ($Cfg.Ngl -eq 'auto') { $hint = 'Reduza o contexto/KV.' }
            Write-Host ('      ' + $hint) -ForegroundColor DarkYellow
        }
        $wGB = $Cfg.Model.Size / 1GB
        if ($wGB -gt ($mi.FreeRam - 2.0)) {
            Write-Host '      Fixar na RAM pode travar o Windows.' -ForegroundColor Yellow
        }
        if (-not (Test-PortFree ([int]$Cfg.Port))) {
            Write-Host ('      Porta {0} em uso.' -f $Cfg.Port) -ForegroundColor Yellow
        }
        $accessUrl = Get-ServerAccessUrl $Cfg.Host ([int]$Cfg.Port)
        if ($Cfg.Host -eq 'tailscale' -and -not $accessUrl) {
            Write-Host '      Tailscale não detectado.' -ForegroundColor Yellow
        } elseif ($accessUrl) {
            Write-Host ('      Acesso: {0}' -f $accessUrl) -ForegroundColor DarkCyan
        }
        if ($Cfg.Host -ne '127.0.0.1') {
            Write-Host '      Rede aberta, sem senha: use só em redes confiáveis.' -ForegroundColor Yellow
        }
        if ($Cfg.Agent -eq 'on') {
            if (Test-AgentSupported) {
                Write-Host '      Agente: o modelo poderá ler/gravar arquivos e executar comandos neste PC.' -ForegroundColor Yellow
                if ($Cfg.Host -ne '127.0.0.1') {
                    Write-Host '      PERIGO: rede aberta + agente. Use Rede = local.' -ForegroundColor Red
                }
            } else {
                Write-Host '      Agente: llama-server.exe sem --agent; opção ignorada.' -ForegroundColor Red
            }
        }
        if ($Cfg.Research -eq 'on') {
            if (-not (Test-ResearchSupported)) {
                Write-Host '      Pesquisa: llama-server.exe sem --ui-mcp-proxy; opção ignorada.' -ForegroundColor Red
            } elseif ($Cfg.Agent -eq 'on' -and (Test-AgentSupported)) {
                Write-Host '      Pesquisa: desativada com o Agente ligado.' -ForegroundColor Red
            } elseif (-not (Get-UvPath)) {
                Write-Host '      Pesquisa: uv não encontrado no PATH.' -ForegroundColor Red
            } else {
                Write-Host '      Pesquisa: o modelo poderá buscar na web (requer internet).' -ForegroundColor Yellow
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath) -and -not (Test-Path -LiteralPath ([string]$Cfg.ImagePath) -PathType Leaf)) {
            Write-Host ('      Geração de Imagem: caminho não encontrado: ' + [string]$Cfg.ImagePath) -ForegroundColor Red
        }
        if ($Cfg.Image -eq 'on') {
            $issue = Get-ImageIssue $Cfg
            if ($issue) {
                Write-Host ('      Geração de Imagem: ' + $issue + ' (ignorada ao iniciar).') -ForegroundColor Red
            } else {
                Write-Host '      Geração de Imagem: o modelo poderá criar imagens pelo SwarmUI.' -ForegroundColor Yellow
            }
        }
        if ($rows[$sel].Key -eq 'image') {
            if ([string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) {
                Write-Host '      Digite o caminho completo do launch-windows.bat do SwarmUI (ex.: D:/SwarmUI/launch-windows.bat).' -ForegroundColor Cyan
            } else {
                Write-Host '      Digite para trocar o caminho; Enter confirma.' -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        $footer = '  ↑↓ navegar   ←→ alterar   Enter editar/iniciar   Esc voltar   Q sair'
        Write-Footer $footer

        if ($autoBench) {
            $autoBench = $false
            Invoke-Benchmark $Cfg (Get-RowTop $sel)
            continue
        }

        $key = Read-Key
        $kn = [string]$key.Key
        $clicked = $false
        if ($kn -eq 'MouseLeft') {
            if ($key.Index -ge 0 -and $key.Index -lt $rows.Count) { $sel = $key.Index; $kn = 'Enter'; $clicked = $true } else { continue }
        } elseif ($kn -eq 'MouseRight') {
            if ($key.Index -ge 0 -and $key.Index -lt $rows.Count) { $sel = $key.Index; $kn = 'LeftArrow' } else { $kn = 'Escape' }
        }
        $typKey = [string]$rows[$sel].Key
        $nglTyping = (@('ngl', 'threads', 'batch') -contains $typKey) -and (([string]$key.KeyChar -match '^\d$') -or ($key.Key -eq 'Backspace'))
        $imgChar = ($typKey -eq 'image') -and (-not [char]::IsControl($key.KeyChar))
        $imgBack = ($typKey -eq 'image') -and ($kn -eq 'Backspace')
        if (-not $nglTyping) { $nglBuf = '' }
        if ($imgChar -or $imgBack) {
            $p = [string]$Cfg.ImagePath
            if ($imgBack) {
                if ($p.Length -gt 0) { $p = $p.Substring(0, $p.Length - 1) }
            } elseif ($p.Length -lt 260) {
                $p += [string]$key.KeyChar
            }
            $Cfg.ImagePath = $p
            if ([string]::IsNullOrWhiteSpace($p)) { $Cfg.Image = 'off' } else { $Cfg.Image = 'on' }
            continue
        }
        switch ($kn) {
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt ($rows.Count - 1)) { $sel++ } }
            'Home'      { $sel = 0 }
            'End'       { $sel = $rows.Count - 1 }
            'LeftArrow' {
                if ($rows[$sel].Key -ne 'start' -and $rows[$sel].Key -ne 'model') {
                    Change-CfgSetting $Cfg $rows[$sel].Key -1
                }
            }
            'RightArrow' {
                if ($rows[$sel].Key -ne 'start' -and $rows[$sel].Key -ne 'model') {
                    Change-CfgSetting $Cfg $rows[$sel].Key 1
                }
            }
            'Enter' {
                $k = $rows[$sel].Key
                if ($k -eq 'start') { return [pscustomobject]@{ Action = 'start' } }
                if ($k -eq 'image' -and $clicked) {
                    Change-CfgSetting $Cfg 'image' 1
                } elseif ($k -eq 'image') {
                    $Cfg.ImagePath = ConvertTo-ImagePath ([string]$Cfg.ImagePath)
                    if ([string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) {
                        $Cfg.ImagePath = ''
                        $Cfg.Image = 'off'
                    } else {
                        $Cfg.Image = 'on'
                    }
                } elseif ($k -eq 'model') {
                    $pick = Show-ModelPicker -CurrentPath $Cfg.Model.Path
                    $newModel = $null
                    if ($pick.Action -eq 'model' -or $pick.Action -eq 'editlast') { $newModel = $pick.Model }
                    elseif ($pick.Action -eq 'last' -and $script:LastCfg) { $newModel = $script:LastCfg.Model }
                    if ($newModel) {
                        Save-ModelCfg $Cfg $snap0
                        return [pscustomobject]@{ Action = 'switch'; Cfg = (New-CfgForModel $newModel) }
                    }
                } elseif ($k -eq 'bench') {
                    Invoke-Benchmark $Cfg (Get-RowTop $sel)
                } else {
                    Change-CfgSetting $Cfg $k 1
                }
            }
            'Escape' { Save-ModelCfg $Cfg $snap0; return [pscustomobject]@{ Action = 'back' } }
            'Q'      { Save-ModelCfg $Cfg $snap0; return [pscustomobject]@{ Action = 'exit' } }
            'S'      { return [pscustomobject]@{ Action = 'start' } }
            'B'      {
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    if ($rows[$i].Key -eq 'bench') { $sel = $i; break }
                }
                $autoBench = $true
            }
            'Backspace' {
                if ($nglTyping) {
                    $prop = 'Ngl'
                    if ($typKey -eq 'threads') { $prop = 'Threads' } elseif ($typKey -eq 'batch') { $prop = 'Batch' }
                    if ($nglBuf.Length -gt 0) { $nglBuf = $nglBuf.Substring(0, $nglBuf.Length - 1) }
                    if ($nglBuf -eq '') { $Cfg.$prop = 'auto' } else { $Cfg.$prop = $nglBuf }
                    if ($prop -eq 'Ngl') { $Cfg.Preset = 'personalizado' }
                    Normalize-Cfg $Cfg
                    if ($Cfg.$prop -ne 'auto') { $nglBuf = [string]$Cfg.$prop } else { $nglBuf = '' }
                }
            }
            default {
                if ($nglTyping) {
                    $prop = 'Ngl'
                    if ($typKey -eq 'threads') { $prop = 'Threads' } elseif ($typKey -eq 'batch') { $prop = 'Batch' }
                    $maxLen = 3
                    if ($typKey -eq 'batch') { $maxLen = 4 }
                    if ($nglBuf.Length -lt $maxLen) { $nglBuf += [string]$key.KeyChar }
                    $Cfg.$prop = $nglBuf
                    if ($prop -eq 'Ngl') { $Cfg.Preset = 'personalizado' }
                    Normalize-Cfg $Cfg
                    if ($Cfg.$prop -ne 'auto') { $nglBuf = [string]$Cfg.$prop } else { $nglBuf = '' }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Browser / server lifecycle
# ---------------------------------------------------------------------------
function Start-BrowserJob {
    param($Cfg, [string]$ServerUrl, [string]$OpenWebUiUrl, [string]$OpenWebUiBat, [string]$LogDir)

    $scriptBlock = {
        param($ServerUrl, $Target, $OpenWebUiUrl, $OpenWebUiBat, $LogDir)

        $logPath = ''
        try {
            if ($LogDir) {
                if (-not (Test-Path -LiteralPath $LogDir)) {
                    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
                }
                $logPath = Join-Path $LogDir ('browser_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            }
        } catch { $logPath = '' }

        function Write-BrowserLog {
            param([string]$Message)
            if (-not $logPath) { return }
            try {
                Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
            } catch { }
        }

        function Test-WebReady {
            param([string]$Url, [bool]$Require200 = $false)
            try {
                $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                $code = [int]$r.StatusCode
                if ($Require200) { return ($code -eq 200) }
                return ($code -ge 200 -and $code -lt 500)
            } catch {
                return $false
            }
        }

        function Open-BrowserUrl {
            param([string]$Url)
            try {
                Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
                Write-BrowserLog ('Navegador acionado: ' + $Url)
                Start-Sleep -Seconds 1
                return $true
            } catch {
                Write-BrowserLog ('Start-Process falhou: ' + $_.Exception.Message)
            }
            try {
                Start-Process -FilePath 'rundll32.exe' -ArgumentList 'url.dll,FileProtocolHandler', $Url -ErrorAction Stop | Out-Null
                Write-BrowserLog ('Navegador acionado via rundll32: ' + $Url)
                Start-Sleep -Seconds 1
                return $true
            } catch {
                Write-BrowserLog ('rundll32 falhou: ' + $_.Exception.Message)
            }
            try {
                $cmdLine = 'start "" "' + ($Url -replace '"', '') + '"'
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -WindowStyle Hidden -ErrorAction Stop | Out-Null
                Write-BrowserLog ('Navegador acionado via cmd start: ' + $Url)
                Start-Sleep -Seconds 1
                return $true
            } catch {
                Write-BrowserLog ('cmd start falhou: ' + $_.Exception.Message)
            }
            return $false
        }

        Write-BrowserLog ('Iniciando coordenador. alvo={0} servidor={1}' -f $Target, $ServerUrl)
        if ($Target -eq 'none') {
            Write-BrowserLog 'Navegador desativado na configuração.'
            return
        }

        if ($Target -eq 'openwebui') {
            if (Test-WebReady $OpenWebUiUrl) {
                Write-BrowserLog 'Open WebUI já estava em execução.'
            } elseif (Get-Command 'uvx' -ErrorAction SilentlyContinue) {
                try {
                    $env:DATA_DIR = 'C:\OpenWebUI\data'
                    $uvxCmd = 'uvx --python 3.11 open-webui@latest serve --host 0.0.0.0 --port 8080 || pause'
                    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $uvxCmd -WindowStyle Minimized | Out-Null
                    Write-BrowserLog 'Open WebUI iniciado via uvx em paralelo ao carregamento do modelo.'
                } catch {
                    Write-BrowserLog ('Falha ao iniciar Open WebUI via uvx: ' + $_.Exception.Message)
                }
            } elseif ($OpenWebUiBat -and (Test-Path -LiteralPath $OpenWebUiBat)) {
                try {
                    $wd = Split-Path -Parent $OpenWebUiBat
                    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + $OpenWebUiBat + '"') -WorkingDirectory $wd -WindowStyle Minimized | Out-Null
                    Write-BrowserLog 'Open WebUI iniciado em paralelo ao carregamento do modelo.'
                } catch {
                    Write-BrowserLog ('Falha ao iniciar Open WebUI: ' + $_.Exception.Message)
                }
            } else {
                Write-BrowserLog ('Script do Open WebUI não encontrado: ' + $OpenWebUiBat)
            }
        }

        # /health só responde 200 depois que o modelo termina de carregar.
        $serverOk = $false
        $deadline = (Get-Date).AddSeconds(1800)
        while ((Get-Date) -lt $deadline) {
            if (Test-WebReady ($ServerUrl + '/health') $true) { $serverOk = $true; break }
            Start-Sleep -Milliseconds 700
        }
        if (-not $serverOk) {
            Write-BrowserLog 'Tempo esgotado aguardando o llama-server.'
            return
        }
        Write-BrowserLog 'llama-server pronto.'

        if ($Target -eq 'llamacpp') {
            $null = Open-BrowserUrl $ServerUrl
            return
        }

        if ($Target -eq 'openwebui') {
            $owuiOk = Test-WebReady $OpenWebUiUrl
            if (-not $owuiOk) {
                Write-BrowserLog 'Aguardando o Open WebUI...'
                $owuiDeadline = (Get-Date).AddSeconds(300)
                while (-not $owuiOk -and (Get-Date) -lt $owuiDeadline) {
                    Start-Sleep -Milliseconds 800
                    $owuiOk = Test-WebReady $OpenWebUiUrl
                }
            }
            if ($owuiOk) {
                Write-BrowserLog 'Open WebUI pronto.'
                $null = Open-BrowserUrl $OpenWebUiUrl
            } else {
                Write-BrowserLog 'Open WebUI não respondeu; abrindo a interface do llama.cpp.'
                $null = Open-BrowserUrl $ServerUrl
            }
        }
    }

    try {
        return Start-Job -ScriptBlock $scriptBlock -ArgumentList $ServerUrl, $Cfg.Browser, $OpenWebUiUrl, $OpenWebUiBat, $LogDir
    } catch {
        return $null
    }
}

function Remove-OldLogs {
    try {
        @(Get-ChildItem -LiteralPath $script:LogDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 28) |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Show-StartSummary {
    param($Cfg, [string]$LogPath, $Research = $null, $Image = $null)
    $w = Get-UIWidth
    Clear-Screen
    Show-Header 'Iniciando servidor'
    Write-Host ''
    Write-Host ('  Modelo:     ' + $Cfg.Model.Display) -ForegroundColor White
    Write-Host ('  Contexto:   {0} tokens   |   KV: {1} / {2}   |   Batch: {3}' -f $Cfg.Ctx, $Cfg.Ctk, $Cfg.Ctv, (Get-BatchLabel $Cfg.Batch)) -ForegroundColor Gray
    Write-Host ('  GPU:        {0}   |   Visão: {1}   |   Raciocínio: {2}' -f (Get-NglLabel $Cfg.Ngl $Cfg.Model), (Get-VisionLabel $Cfg), $Cfg.Reasoning) -ForegroundColor Gray
    Write-Host ('  Porta:      {0}   |   Navegador: {1}' -f $Cfg.Port, (Get-BrowserLabel $Cfg.Browser)) -ForegroundColor Gray
    Write-Host ('  Template:   ' + (Get-TemplateLabel $Cfg.Template)) -ForegroundColor Gray
    Write-Host ('  CPU:        Threads {0}   |   Cache de prompt: {1}' -f (Get-ThreadsLabel $Cfg.Threads), (Get-CacheRamLabel $Cfg)) -ForegroundColor Gray
    Write-Host ('  Rede:       ' + (Get-HostLabel $Cfg.Host)) -ForegroundColor Gray
    if ([string]$Cfg.Agent -eq 'on') {
        if (Test-AgentSupported) {
            Write-Host '  Agente:     ligado (ler/gravar arquivos e executar comandos)' -ForegroundColor Yellow
            Write-Host ('  Pasta base: ' + $script:Root) -ForegroundColor Yellow
            if ($Cfg.Host -ne '127.0.0.1') {
                Write-Host '  PERIGO:     rede aberta + agente: qualquer aparelho na rede pode executar comandos aqui.' -ForegroundColor Red
            }
        } else {
            Write-Host '  Agente:     indisponível (llama-server.exe antigo, --agent ignorado)' -ForegroundColor Red
        }
    }
    if ([string]$Cfg.Research -eq 'on') {
        if ($Research -and $Research.Ok) {
            Write-Host ('  Pesquisa:   ligada (servidor local na porta {0})' -f $Research.Port) -ForegroundColor Cyan
        } elseif ($Research) {
            Write-Host ('  Pesquisa:   falhou (' + $Research.Error + ')') -ForegroundColor Red
        } elseif (-not (Test-ResearchSupported)) {
            Write-Host '  Pesquisa:   indisponível (llama-server.exe antigo, sem --ui-mcp-proxy)' -ForegroundColor Red
        } else {
            Write-Host '  Pesquisa:   desativada (Agente ligado)' -ForegroundColor Red
        }
    }
    if ([string]$Cfg.Image -eq 'on') {
        if ($Image -and $Image.Ok) {
            Write-Host ('  Imagem:     ligada (SwarmUI na porta {0}, MCP na porta {1})' -f $Image.Swarm.Port, $Image.Port) -ForegroundColor Cyan
            Write-Host ('  SwarmUI:    ' + [string]$Cfg.ImagePath) -ForegroundColor DarkGray
        } elseif ($Image) {
            Write-Host ('  Imagem:     falhou (' + $Image.Error + ')') -ForegroundColor Red
        } elseif (-not (Test-ResearchSupported)) {
            Write-Host '  Imagem:     indisponível (llama-server.exe antigo, sem --ui-mcp-proxy)' -ForegroundColor Red
        } elseif ([string]::IsNullOrWhiteSpace([string]$Cfg.ImagePath)) {
            Write-Host '  Imagem:     desativada (sem caminho)' -ForegroundColor Red
        } else {
            Write-Host ('  Imagem:     indisponível (' + (Get-ImageIssue $Cfg) + ')') -ForegroundColor Red
        }
    }
    $accessUrl = Get-ServerAccessUrl $Cfg.Host ([int]$Cfg.Port)
    if ($accessUrl) {
        Write-Host ('  Acesso:     ' + $accessUrl) -ForegroundColor Cyan
    } elseif ($Cfg.Host -eq 'tailscale') {
        Write-Host '  Acesso:     Tailscale não detectado' -ForegroundColor Yellow
    }

    if ($LogPath) { Write-Host ('  Log:        ' + $LogPath) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  Carregando o modelo...' -ForegroundColor Cyan
    Write-Host '  Ctrl+C encerra o servidor; Esc duas vezes encerra e volta ao menu.' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-EscWatcher {
    $state = [hashtable]::Synchronized(@{ Stop = $false; Quit = $false })
    $ps = $null
    $handle = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($State, $ServerPid)
            $last = [datetime]::MinValue
            while (-not $State.Stop) {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Escape') {
                        if (((Get-Date) - $last).TotalSeconds -le 3) {
                            $State.Quit = $true
                            foreach ($p in @(Get-CimInstance Win32_Process -Filter ("Name='llama-server.exe' AND ParentProcessId={0}" -f $ServerPid))) {
                                & taskkill.exe /PID $p.ProcessId /T /F | Out-Null
                            }
                            return
                        }
                        $last = Get-Date
                        [Console]::ForegroundColor = 'Yellow'
                        [Console]::WriteLine('  Esc de novo para encerrar o servidor.')
                        [Console]::ResetColor()
                    } else {
                        $last = [datetime]::MinValue
                    }
                }
                Start-Sleep -Milliseconds 100
            }
        }).AddArgument($state).AddArgument($PID)
        $handle = $ps.BeginInvoke()
    } catch { }
    return [pscustomobject]@{ Ps = $ps; Handle = $handle; State = $state }
}

function Stop-EscWatcher {
    param($Watcher)
    $Watcher.State.Stop = $true
    try { if ($Watcher.Handle) { [void]$Watcher.Handle.AsyncWaitHandle.WaitOne(1000) } } catch { }
    try { if ($Watcher.Ps) { $Watcher.Ps.Dispose() } } catch { }
}

function Start-LoadProgress {
    param([int]$Port, [double]$TotalBytes)
    $state = [hashtable]::Synchronized(@{ Stop = $false })
    $ps = $null
    $handle = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($State, $ServerPid, $Port, $Total)
            if ($Total -le 0) { $Total = 1 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $childPid = 0
            $row = -1
            while (-not $State.Stop) {
                $loaded = $false
                try {
                    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/health' -f $Port) -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
                    if ([int]$resp.StatusCode -eq 200) { $loaded = $true }
                } catch { }
                if ($childPid -eq 0) {
                    foreach ($r in @(Get-CimInstance Win32_Process -Filter ("Name='llama-server.exe' AND ParentProcessId={0}" -f $ServerPid))) { $childPid = [int]$r.ProcessId }
                }
                $read = 0.0
                if ($childPid -ne 0) {
                    $p = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $childPid)
                    if ($p) { $read = [double]$p.ReadTransferCount } else { $childPid = 0 }
                }
                $pct = [int][Math]::Min(99, [Math]::Floor(100.0 * $read / $Total))
                if ($loaded) {
                    $text = ('  Modelo carregado em {0:0}s.' -f $sw.Elapsed.TotalSeconds)
                } else {
                    $text = ('  Carregando modelo... {0}%  ({1:0}s)' -f $pct, $sw.Elapsed.TotalSeconds)
                }
                if ($row -lt 0) {
                    if ($loaded -or $read -gt ($Total * 0.03)) {
                        $row = [Console]::CursorTop
                        [Console]::WriteLine($text)
                    }
                } else {
                    $l = [Console]::CursorLeft
                    $t = [Console]::CursorTop
                    [Console]::SetCursorPosition(0, $row)
                    [Console]::Write($text.PadRight(48))
                    [Console]::SetCursorPosition($l, $t)
                }
                if ($loaded) { break }
                Start-Sleep -Milliseconds 500
            }
        }).AddArgument($state).AddArgument($PID).AddArgument($Port).AddArgument($TotalBytes)
        $handle = $ps.BeginInvoke()
    } catch { }
    return [pscustomobject]@{ Ps = $ps; Handle = $handle; State = $state }
}

function Stop-LoadProgress {
    param($Watcher)
    $Watcher.State.Stop = $true
    try { if ($Watcher.Handle) { [void]$Watcher.Handle.AsyncWaitHandle.WaitOne(2000) } } catch { }
    try { if ($Watcher.Ps) { $Watcher.Ps.Dispose() } } catch { }
}

function Start-LlamaServer {
    param($Cfg)

    if (-not (Test-Path -LiteralPath $script:ServerExe)) {
        $null = Show-Choice -Title 'Erro' -Message 'llama-server.exe não encontrado.' -Options @('Voltar') -Default 0
        return 'menu'
    }
    if (-not (Test-Path -LiteralPath $Cfg.Model.Path)) {
        $null = Show-Choice -Title 'Erro' -Message ('Modelo não encontrado:' + "`n" + $Cfg.Model.Path) -Options @('Voltar') -Default 0
        return 'menu'
    }

    do {
        $port = [int]$Cfg.Port
        if (-not (Test-PortFree $port)) {
            if (Test-LlamaHealth $port) {
                $choice = Show-Choice -Title 'Servidor já em execução' `
                    -Message ("Já existe um llama-server em http://127.0.0.1:{0}.`n`nO que deseja fazer?" -f $port) `
                    -Options @('Abrir o servidor existente', 'Encerrar e iniciar novo', 'Voltar') -Default 0
                if ($choice -eq 0) {
                    $openUrl = ''
                    if ($Cfg.Browser -eq 'llamacpp') {
                        $openUrl = ('http://127.0.0.1:{0}' -f $port)
                    } elseif ($Cfg.Browser -eq 'openwebui') {
                        try { $null = Invoke-WebRequest -Uri 'http://localhost:8080' -UseBasicParsing -TimeoutSec 2; $openUrl = 'http://localhost:8080' } catch { $openUrl = ('http://127.0.0.1:{0}' -f $port) }
                    }
                    if ($openUrl) { try { Start-Process $openUrl | Out-Null } catch { } }
                    return 'menu'
                }
                if ($choice -lt 0 -or $choice -eq 2) { return 'settings' }
                if (-not (Stop-LlamaPort $port)) {
                    $null = Show-Choice -Title 'Erro' -Message ('Não foi possível encerrar o processo na porta ' + $port + '.') -Options @('Voltar') -Default 0
                    return 'settings'
                }
                for ($i = 0; $i -lt 10 -and -not (Test-PortFree $port); $i++) { Start-Sleep -Milliseconds 300 }
                if (-not (Test-PortFree $port)) {
                    $null = Show-Choice -Title 'Erro' -Message ('A porta ' + $port + ' continua ocupada.') -Options @('Voltar') -Default 0
                    return 'settings'
                }
            } else {
                $next = Get-NextFreePort ($port + 1)
                $choice = Show-Choice -Title 'Porta em uso' `
                    -Message ("A porta {0} está ocupada por outro programa.`n`nUsar a porta {1}?" -f $port, $next) `
                    -Options @(("Usar porta " + $next), 'Voltar') -Default 0
                if ($choice -eq 0) {
                    $Cfg.Port = $next
                    $port = $next
                } else {
                    return 'settings'
                }
            }
        }

        Update-Hardware
        $mi = Get-MemoryEstimate $Cfg
        if ($mi.Level -eq 'bad' -and $mi.NeedRam -gt ($mi.FreeRam - 1.0)) {
            $choice = Show-Choice -Title 'Aviso de RAM' `
                -Message "A estimativa indica que o modelo pode não caber na RAM disponível.`n`nFeche outros programas ou reduza o contexto/KV." `
                -Options @('Voltar e ajustar', 'Iniciar mesmo assim') -Default 0
            if ($choice -ne 1) { return 'settings' }
        } elseif ($Cfg.Ngl -eq 'all' -and $mi.Level -eq 'bad') {
            $choice = Show-Choice -Title 'Aviso de VRAM' `
                -Message "Todas as camadas foram forçadas para a GPU, mas a estimativa indica VRAM insuficiente." `
                -Options @('Usar modo automático e iniciar', 'Iniciar mesmo assim', 'Voltar') -Default 0
            if ($choice -eq 0) {
                $Cfg.Ngl = 'auto'
                $Cfg.Preset = 'personalizado'
            } elseif ($choice -eq 2 -or $choice -lt 0) {
                return 'settings'
            }
        }

        Save-Cfg $Cfg

        $logPath = ''
        try {
            if (-not (Test-Path -LiteralPath $script:LogDir)) {
                New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
            }
            Remove-OldLogs
            $safe = ($Cfg.Model.Display -replace '[^\w\-\. ]', '_')
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'modelo' }
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $logPath = Join-Path $script:LogDir ('server_{0}_{1}.log' -f $stamp, $safe)
        } catch { $logPath = '' }

        $script:Research = $null
        $script:Image = $null
        if (Test-ResearchWanted $Cfg) {
            Clear-Screen
            Show-Header 'Preparando pesquisa'
            Write-Host ''
            Write-Host '  Iniciando o servidor de pesquisa (na primeira vez baixa as dependências; pode demorar)...' -ForegroundColor Gray
            $script:Research = Start-ResearchServer $logPath ([int]$Cfg.Ctx)
        }

        $imageVision = ([string]$Cfg.Vision -ne 'off') -and [bool]$Cfg.Model.Mmproj
        if ([string]$Cfg.Image -eq 'on') {
            $imageIssue = Get-ImageIssue $Cfg
            if ($imageIssue) {
                $script:Image = [pscustomobject]@{ Ok = $false; Error = $imageIssue; Port = 0; Proc = $null; Files = @(); ErrLog = ''; Swarm = $null; Url = '' }
            } else {
                Clear-Screen
                Show-Header 'Preparando geração de imagem'
                Write-Host ''
                Write-Host '  Iniciando o SwarmUI e o servidor de imagem (na primeira vez o SwarmUI pode demorar)...' -ForegroundColor Gray
                $script:Image = Start-ImageServer $logPath ([string]$Cfg.ImagePath) ([int]$Cfg.Port) ([bool]$imageVision)
            }
        }

        $uiConfigPath = ''
        $researchPort = 0
        $imagePort = 0
        if ($script:Research -and $script:Research.Ok) { $researchPort = [int]$script:Research.Port }
        if ($script:Image -and $script:Image.Ok) { $imagePort = [int]$script:Image.Port }
        if ($researchPort -gt 0 -or $imagePort -gt 0) {
            $uiConfigPath = Write-UiConfig -ResearchPort $researchPort -ImagePort $imagePort -ImageVision ([bool]$imageVision)
        }
        $serverArgs = Build-ServerArgs $Cfg $logPath $uiConfigPath
        Show-StartSummary $Cfg $logPath $script:Research $script:Image

        $serverUrl = ('http://127.0.0.1:{0}' -f [int]$Cfg.Port)
        $owuiUrl = 'http://localhost:8080'
        $owuiBat = Join-Path $script:Root 'iniciar_openwebui.bat'
        $browserJob = $null
        if ($Cfg.Browser -ne 'none') {
            $browserJob = Start-BrowserJob $Cfg $serverUrl $owuiUrl $owuiBat $script:LogDir
        }

        try { $Host.UI.RawUI.WindowTitle = ('llama-server  |  ' + $Cfg.Model.Display) } catch { }
        try { [Console]::CursorVisible = $true } catch { }

        Disable-Mouse
        $esc = Start-EscWatcher
        $progress = Start-LoadProgress ([int]$Cfg.Port) ([double]$Cfg.Model.Size)
        $code = 0
        try {
            Push-Location $script:Root
            & $script:ServerExe @serverArgs
            if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
        } catch {
            Write-Host ''
            Write-Host ('  [ERRO] ' + $_.Exception.Message) -ForegroundColor Red
            $code = 1
        } finally {
            Pop-Location
            Stop-EscWatcher $esc
            Stop-LoadProgress $progress
            Enable-Mouse
            Stop-ImageServer $script:Image
            $script:Image = $null
            Stop-ResearchServer $script:Research
            $script:Research = $null
            if ($uiConfigPath) {
                try { Remove-Item -LiteralPath $uiConfigPath -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        if ($browserJob) {
            try { Stop-Job $browserJob -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job $browserJob -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { $Host.UI.RawUI.WindowTitle = 'Llama Launcher' } catch { }
        try { [Console]::CursorVisible = $false } catch { }

        Update-Hardware
        if ($esc.State.Quit) { return 'menu' }
        $msg = ('Servidor encerrado (código {0}).' -f $code)
        if ($logPath) { $msg += ("`n`nLog: " + $logPath) }
        $choice = Show-Choice -Title 'Servidor encerrado' -Message $msg `
            -Options @('Voltar ao menu', 'Iniciar novamente', 'Sair') -Default 0
        if ($choice -eq 1) { continue }
        if ($choice -eq 2) { return 'exit' }
        return 'menu'
    } while ($true)
}

# ---------------------------------------------------------------------------
# Self test (hidden arg --selftest)
# ---------------------------------------------------------------------------
function Run-SelfTest {
    Write-Host '=== LLAMA LAUNCHER SELF TEST ==='
    Write-Host ('Root:  ' + $script:Root)
    Write-Host ('Models:' + $script:ModelsDir)
    if ($script:Gpu.Ok) {
        Write-Host ('GPU:   {0}  ({1:0.0} GB livre de {2:0.0} GB)' -f $script:Gpu.Name, ($script:Gpu.FreeMB / 1024.0), ($script:Gpu.TotalMB / 1024.0))
    } else {
        Write-Host 'GPU:   não detectada'
    }
    Write-Host ('RAM:   {0:0.0} GB livre de {1:0.0} GB' -f ($script:Mem.FreeMB / 1024.0), ($script:Mem.TotalMB / 1024.0))
    Write-Host ('Modelos encontrados: ' + $script:Models.Count)
    $firstFit = ''
    foreach ($m in $script:Models) {
        if ((Get-ModelStatusShort $m) -eq 'cabe na GPU') { $firstFit = $m.Display; break }
    }
    Write-Host ('Primeiro que cabe na GPU: ' + $firstFit)
    $lanIp = Get-LanIPv4
    $tsIp = Get-TailscaleIPv4
    if ($lanIp) { Write-Host ('LAN:   ' + $lanIp) }
    if ($tsIp) { Write-Host ('Tailscale: ' + $tsIp) }
    Write-Host ('Porta configurada: ' + [int]$script:Global.Port)
    Write-Host ('Geração de imagem: ' + [string]$script:Global.Image + '  ' + [string]$script:Global.ImagePath)
    Write-Host ''

    foreach ($m in $script:Models) {
        $kv8 = Get-KvGB $m.Meta 8192 'q8_0' 'q8_0'
        $heads = @($m.Meta.KvHeads)
        $headTxt = '?'
        if ($heads.Count -gt 0) {
            if ($heads.Count -gt 6) {
                $headTxt = (($heads[0..5] | ForEach-Object { [string]$_ }) -join ',') + ',...'
            } else {
                $headTxt = (($heads | ForEach-Object { [string]$_ }) -join ',')
            }
        }
        $cfg = New-CfgForModel $m $false
        $mi = Get-MemoryEstimate $cfg
        $mm = '-'
        if ($m.Mmproj) { $mm = (Format-GB $m.Mmproj.Length) }
        Write-Host ('{0}' -f $m.Display) -ForegroundColor Cyan
        Write-Host ('  size={0} quant={1} arch={2} layers={3} heads={4} kvheads={5} headDim={6}/{7} maxCtx={8} experts={9}/{10} think={11} parse={12}' -f `
            (Format-GB $m.Size), $m.Quant, $m.Meta.Arch, $m.Meta.Layers, $m.Meta.HeadCount, $headTxt, $m.Meta.HeadDimK, $m.Meta.HeadDimV, `
            $m.Meta.MaxCtx, $m.Meta.Experts, $m.Meta.ExpertsUsed, $m.Meta.HasThinking, $m.Meta.ParseOk)
        Write-Host ('  mmproj={0}  kv@8K/q8_0={1:0.00} GB  recCtx={2}  status={3}  needV={4:0.00} GB' -f `
            $mm, $kv8, $cfg.Ctx, $mi.Text, $mi.NeedVram)
        if (-not $m.Meta.ParseOk -and $m.Meta.ParseError) {
            Write-Host ('  parse error: ' + $m.Meta.ParseError) -ForegroundColor Red
        }
        Write-Host ''
    }

    if ($script:Models.Count -gt 0) {
        $cfg = New-CfgForModel $script:Models[0] $false
        $a = Build-ServerArgs $cfg ''
        Write-Host 'Exemplo de comando:'
        Write-Host (Format-Command $script:ServerExe $a)
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($args -contains '--selftest') {
    $script:Gpu = Get-GpuInfo
    $script:Mem = Get-MemInfo
    Initialize-State
    Refresh-Models
    Run-SelfTest
    exit 0
}

Initialize-Console
Initialize-Mouse
if (Test-UpdateAvailable) {
    try { [Console]::CursorVisible = $false } catch { }
    if ((Show-UpdatePrompt) -and (Install-LauncherUpdate)) {
        Disable-Mouse
        try { [Console]::CursorVisible = $true } catch { }
        exit $script:UpdateExitCode
    }
}

$script:Gpu = Get-GpuInfo
$script:Mem = Get-MemInfo
Initialize-State
Refresh-Models

$exitAll = $false
try {
    try { [Console]::CursorVisible = $false } catch { }
    $currentPath = ''
    while (-not $exitAll) {
        $pick = Show-ModelPicker -CurrentPath $currentPath
        if ($pick.Action -eq 'exit') { break }

        if ($pick.Action -eq 'update') {
            if (Install-LauncherUpdate) {
                $script:ExitCode = $script:UpdateExitCode
                break
            }
            continue
        }

        if ($pick.Action -eq 'last') {
            if (-not $script:LastCfg) { continue }
            $cfg = $script:LastCfg
            $r = Start-LlamaServer $cfg
            if ($r -eq 'exit') { break }
            $currentPath = $cfg.Model.Path
            continue
        }

        if ($pick.Action -eq 'editlast') {
            $pick = [pscustomobject]@{ Action = 'model'; Model = $pick.Model }
        }

        $model = $pick.Model
        if (-not $model) { continue }
        $cfg = New-CfgForModel $model
        $currentPath = $model.Path

        while ($true) {
            $res = Show-Settings $cfg
            if ($res.Action -eq 'switch') {
                $cfg = $res.Cfg
                $currentPath = $cfg.Model.Path
                continue
            }
            if ($res.Action -eq 'back') {
                $currentPath = $cfg.Model.Path
                break
            }
            if ($res.Action -eq 'exit') {
                $exitAll = $true
                break
            }
            if ($res.Action -eq 'start') {
                $r = Start-LlamaServer $cfg
                if ($r -eq 'exit') {
                    $exitAll = $true
                    break
                }
                if ($r -eq 'settings') { continue }
                if ($r -eq 'menu') {
                    $currentPath = $cfg.Model.Path
                    break
                }
            }
        }
    }
} finally {
    Stop-ImageServer $script:Image
    Stop-ResearchServer $script:Research
    Disable-Mouse
    try { [Console]::CursorVisible = $true } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'Llama Launcher' } catch { }
}
exit $script:ExitCode
# === END ===
