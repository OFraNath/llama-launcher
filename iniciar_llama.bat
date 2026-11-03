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

# Registra a linha atual da tela como clicável (Id = índice do item)
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
    $map = @{ 'Enter' = 'Enter'; 'Esc' = 'Escape'; '←→' = 'RightArrow'; 'L' = 'L'; 'E' = 'E'; 'R' = 'R'; 'Q' = 'Q' }
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
# Mouse (Win32 console input). Clique esquerdo = Enter, direito = voltar/<-,
# roda = cima/baixo. Se falhar, o launcher continua só com teclado.
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
    public static LlamaEvt Read() {
        while (true) {
            INPUT_RECORD r; uint n;
            if (!ReadConsoleInput(hIn, out r, 1, out n) || n == 0) return null;
            if (r.EventType == 1) {
                if (r.bKeyDown == 0) continue;
                ushort vk = r.wVirtualKeyCode;
                if (vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x14 || vk == 0x90 || vk == 0x91) continue;
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
                if ((flags & (1u | 2u | 8u)) != 0) continue; // mover / duplo clique / roda horizontal
                LlamaEvt c = null;
                if ((pressed & 1u) != 0) { c = new LlamaEvt(); c.Kind = 2; }
                else if ((pressed & 2u) != 0) { c = new LlamaEvt(); c.Kind = 3; }
                if (c != null) { c.X = r.MouseX; c.Y = r.MouseY; return c; }
            }
        }
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
    try {
        $raw = $Host.UI.RawUI
        $ws = $raw.WindowSize
        $max = $raw.MaxWindowSize
        $nw = [Math]::Min($max.Width, [Math]::Max($ws.Width, 100))
        $nh = [Math]::Min($max.Height, [Math]::Max($ws.Height, 34))
        if ($nw -ne $ws.Width -or $nh -ne $ws.Height) {
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
# GGUF metadata reader (fast: stops before the tokenizer arrays)
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
        [void]$br.ReadUInt64()  # tensor count
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
    if ([int]$Cfg.NPredict -lt -1) { $Cfg.NPredict = -1 }
    if ([int]$Cfg.NPredict -gt 32768) { $Cfg.NPredict = 32768 }
}

# ---------------------------------------------------------------------------
# Persistent state
# ---------------------------------------------------------------------------
$script:Global = [pscustomobject]@{ port = 5001; host = '127.0.0.1'; browser = 'llamacpp'; agent = 'off'; research = 'off' }
$script:StateModels = @{}
$script:LastModelPath = ''
$script:LastCfg = $null
$script:SessionCfg = @{}
$script:Models = @()
$script:Research = $null

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

function Save-Cfg {
    param($Cfg)
    Set-StateModel $Cfg
    $script:LastModelPath = $Cfg.Model.Path
    $script:Global = [pscustomobject]@{
        port    = [int]$Cfg.Port
        host    = [string]$Cfg.Host
        browser = [string]$Cfg.Browser
        agent   = [string]$Cfg.Agent
        research = [string]$Cfg.Research
    }
    $script:LastCfg = $Cfg
    Write-State
}

function Save-ModelCfg {
    param($Cfg, [string]$Snap)
    if ((Get-CfgSnap $Cfg) -eq $Snap) { return }
    Set-StateModel $Cfg
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

function Get-PresetName {
    param($Model)
    $n = ([string]$Model.Display -replace '[\[\]\r\n]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { $n = [System.IO.Path]::GetFileNameWithoutExtension([string]$Model.Path) }
    return $n
}

function ConvertTo-PresetPath {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function Get-PresetLines {
    param($Cfg, [bool]$LoadOnStartup)
    $m = $Cfg.Model
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('[' + (Get-PresetName $m) + ']')
    $l.Add('model = ' + (ConvertTo-PresetPath ([string]$m.Path)))
    $l.Add('ctx-size = ' + [string]$Cfg.Ctx)
    if ([int]$Cfg.NPredict -ge 0) { $l.Add('n-predict = ' + [string]$Cfg.NPredict) }
    $l.Add('cache-type-k = ' + [string]$Cfg.Ctk)
    $l.Add('cache-type-v = ' + [string]$Cfg.Ctv)

    $quantK = ($Cfg.Ctk -notin @('f16', 'f32', 'bf16'))
    $quantV = ($Cfg.Ctv -notin @('f16', 'f32', 'bf16'))
    if ($quantK -or $quantV) { $l.Add('flash-attn = on') } else { $l.Add('flash-attn = auto') }

    if ([string]$Cfg.Template -eq 'chatml') { $l.Add('chat-template = chatml') }
    if ($Cfg.Threads -match '^\d+$') { $l.Add('threads = ' + [string]$Cfg.Threads) }
    if ($Cfg.Batch -match '^\d+$') {
        $l.Add('ubatch-size = ' + [string]$Cfg.Batch)
        if ([int]$Cfg.Batch -gt 2048) { $l.Add('batch-size = ' + [string]$Cfg.Batch) }
    }
    if ($Cfg.CacheRam -eq 'off') {
        $l.Add('cache-ram = 0')
    } else {
        $cr = Get-AutoCacheRamMiB $Cfg
        if ($cr -ge 0) { $l.Add('cache-ram = ' + [string]$cr) }
    }

    $l.Add('fit = on')
    if ($Cfg.Ngl -ne 'auto') { $l.Add('n-gpu-layers = ' + [string]$Cfg.Ngl) }

    if ($Cfg.Vision -ne 'off' -and $m.Mmproj) {
        $l.Add('mmproj = ' + (ConvertTo-PresetPath ([string]$m.Mmproj.FullName)))
        if ($Cfg.Vision -eq 'cpu') { $l.Add('no-mmproj-offload = true') }
    }

    if ($Cfg.Reasoning -ne 'auto' -and $m.Meta.HasThinking) {
        $l.Add('reasoning = ' + [string]$Cfg.Reasoning)
    }

    if ($LoadOnStartup) { $l.Add('load-on-startup = true') } else { $l.Add('load-on-startup = false') }
    $l.Add('')
    return $l.ToArray()
}

function Write-ModelPresets {
    param($Cfg)
    $path = Join-Path $script:Root 'llama_presets.ini'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('version = 1')
    $lines.Add('')
    $selName = Get-PresetName $Cfg.Model
    $seen = @{}
    $seen[$selName] = $true
    foreach ($line in (Get-PresetLines $Cfg $true)) { $lines.Add($line) }
    foreach ($m in $script:Models) {
        $n = Get-PresetName $m
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        $other = New-CfgForModel $m $false
        foreach ($line in (Get-PresetLines $other $false)) { $lines.Add($line) }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, (($lines.ToArray()) -join "`n"), $enc)
    return $path
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
    $a = New-Object System.Collections.Generic.List[string]
    $presetPath = Write-ModelPresets $Cfg
    $a.Add('--models-preset'); $a.Add($presetPath)
    $a.Add('--models-max'); $a.Add('1')
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
    # page is about the query if its domain holds a query term, or its title/description cover half of them
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
        "description": "Returns only a list of links with title and snippet, NOT the content of the pages. Use it only to discover URLs (for example the official site of something); then read a page with fetch_url, or use web_search to get the content.",
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
        "description": "Download one web page and return its main text (as much as fits the context window). Use offset to continue a cut page, and the listed links to follow the site.",
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
        "description": "Search the web, read the most promising pages and return the most relevant excerpts, all with numbered sources. The default (quick) is short and cheap; use depth=deep to get the full text of up to 10 pages. Default tool for any question about current events, specific sites, people or products, or facts you are unsure about. If the query contains a domain or URL, that site (and a few of its internal pages) is read directly. For broad topics ('everything about X') pass several different angles in queries, or set depth to deep.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Main thing to find out"},
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
            text = fn(params.get("arguments") or {})
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

function Write-UiConfig {
    param([int]$McpPort)
    $date = (Get-Date).ToString('yyyy-MM-dd (dddd)', [System.Globalization.CultureInfo]::InvariantCulture)
    $sys = ('Current date: {0}. Your training data is older than this date, so your memory is outdated and may be wrong. If the user asks you to search something, always do it. Unless the answer is extremely obvious (greetings, simple math, code you can write directly, creative writing), call web_search before answering and never answer factual questions from memory. If the user gives a domain or URL, use web_search or fetch_url with it. For broad requests, give web_search several different angles in queries, or use depth=deep. Answer only from the results. At the end of your answer, add a line Sources: (translated to the language of the user) followed by a bullet list with only the URLs you actually used, like: - https://example.com. Never list a source you did not use. If the results do not answer the question, do not give up yet: try depth=deep, and use fetch_url on a page the results mention but did not include in full. After two or three failed tries, say plainly what you found and what you could not find. Never tell the user to search by themselves. Reply in the user language.' -f $date)
    $server = [ordered]@{ enabled = $true; id = 'c0a8e5d2-3f1b-4c7a-9b6e-2d4f8a1e7c30'; url = ('http://127.0.0.1:{0}/mcp' -f $McpPort); useProxy = $true }
    $servers = ConvertTo-Json -InputObject @($server) -Compress
    $obj = [ordered]@{ mcpServers = $servers; systemMessage = $sys }
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
        if ($result.Ok) {
            $cfgPath = Write-UiConfig $port
            $files.Add($cfgPath)
            $result.UiConfig = $cfgPath
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
            Write-Footer '  R atualizar   Q sair'
            $key = Read-Key
            if ($key.Key -eq 'Q') { return [pscustomobject]@{ Action = 'exit' } }
            if ($key.Key -eq 'R' -or $key.Key -eq 'F5') { Update-Hardware; Refresh-Models; $rebuild = $true }
            continue
        }

        $w = Get-UIWidth
        $nameW = [Math]::Max(20, $w - 48)
        $typeW = 13
        $statusW = 17
        $drawnModels = $false

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
                Write-Host '  Modelos' -ForegroundColor DarkGray
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
                $drawnModels = $true
            }
        }

        if (-not $script:LastCfg -and $drawnModels) { }
        Write-Host ''
        $footer = '  ↑↓ navegar   Enter abrir   L última   E editar última   R atualizar   Q sair'
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
        default { return }
    }
    if (@('preset', 'port', 'host', 'browser', 'agent', 'research', 'template', 'threads', 'cacheram', 'batch') -notcontains $Key) {
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
    $label = Fit-Text ('  ' + $Row.Label) 17
    $value = Cut-Text ([string]$Row.Value) ($w - 18)
    $txt = $label + ' ' + $value
    if ($Selected) {
        Write-Row $txt $true
    } else {
        Write-Host (Fit-Text $txt $w) -ForegroundColor $Row.Color
    }
}

function Show-Settings {
    param($Cfg)
    $sel = -1
    $nglBuf = ''
    $snap0 = Get-CfgSnap $Cfg

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
            if ($rows[$i].Key -eq 'start') {
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
            $hint = 'Reduza o contexto/KV ou deixe a GPU no automático (--fit).'
            if ($Cfg.Ngl -eq 'auto') { $hint = 'Reduza o contexto/KV.' }
            Write-Host ('      ' + $hint) -ForegroundColor DarkYellow
        }
        $wGB = $Cfg.Model.Size / 1GB
        if ($wGB -gt ($mi.FreeRam - 2.0)) {
            Write-Host '      Fixar na RAM pode travar o Windows.' -ForegroundColor Yellow
        } else {
            Write-Host '      Fixa o modelo na RAM: carga mais lenta, mas sem quedas de velocidade por paginação.' -ForegroundColor DarkGray
        }
        if (-not (Test-PortFree ([int]$Cfg.Port))) {
            Write-Host ('      Porta {0} em uso: o launcher vai perguntar o que fazer ao iniciar.' -f $Cfg.Port) -ForegroundColor Yellow
        }
        $accessUrl = Get-ServerAccessUrl $Cfg.Host ([int]$Cfg.Port)
        if ($Cfg.Host -eq 'tailscale' -and -not $accessUrl) {
            Write-Host '      Tailscale não detectado. Instale/ative o Tailscale para usar este modo.' -ForegroundColor Yellow
        } elseif ($accessUrl) {
            Write-Host ('      Acesso: {0}' -f $accessUrl) -ForegroundColor DarkCyan
        }
        if ($Cfg.Host -ne '127.0.0.1') {
            Write-Host '      Atenção: escuta em todas as interfaces, sem senha. Use apenas em redes confiáveis.' -ForegroundColor Yellow
        }
        if ($Cfg.Agent -eq 'on') {
            if (Test-AgentSupported) {
                Write-Host '      Agente: o modelo poderá ler/gravar arquivos e executar comandos neste PC (sem limite de pasta).' -ForegroundColor Yellow
                if ($Cfg.Host -ne '127.0.0.1') {
                    Write-Host '      PERIGO: com a rede aberta, qualquer aparelho que alcance a porta poderá fazer isso. Prefira Rede = local.' -ForegroundColor Red
                }
            } else {
                Write-Host '      Agente: este llama-server.exe é antigo e não tem --agent. A opção será ignorada; atualize o llama.cpp.' -ForegroundColor Red
            }
        }
        if ($Cfg.Research -eq 'on') {
            if (-not (Test-ResearchSupported)) {
                Write-Host '      Pesquisa: este llama-server.exe é antigo e não tem --ui-mcp-proxy. A opção será ignorada; atualize o llama.cpp.' -ForegroundColor Red
            } elseif ($Cfg.Agent -eq 'on' -and (Test-AgentSupported)) {
                Write-Host '      Pesquisa: desativada enquanto o Agente estiver ligado (conteúdo da web + comandos no PC é arriscado).' -ForegroundColor Red
            } elseif (-not (Get-UvPath)) {
                Write-Host '      Pesquisa: uv não encontrado no PATH. Instale o uv para usar esta opção.' -ForegroundColor Red
            } else {
                Write-Host '      Pesquisa: o modelo poderá buscar na web e ler páginas (precisa de internet; instala dependências na 1ª vez).' -ForegroundColor Yellow
                if ($Cfg.Host -ne '127.0.0.1') {
                    Write-Host '      Atenção: com a rede aberta, qualquer aparelho que alcance a porta poderá usar a pesquisa por este PC.' -ForegroundColor Yellow
                }
            }
        }

        Write-Host ''
        $footer = '  ↑↓ navegar   ←→ alterar   Enter editar/iniciar   Esc voltar   Q sair'
        Write-Footer $footer

        $key = Read-Key
        $kn = [string]$key.Key
        if ($kn -eq 'MouseLeft') {
            if ($key.Index -ge 0 -and $key.Index -lt $rows.Count) { $sel = $key.Index; $kn = 'Enter' } else { continue }
        } elseif ($kn -eq 'MouseRight') {
            if ($key.Index -ge 0 -and $key.Index -lt $rows.Count) { $sel = $key.Index; $kn = 'LeftArrow' } else { $kn = 'Escape' }
        }
        $typKey = [string]$rows[$sel].Key
        $nglTyping = (@('ngl', 'threads', 'batch') -contains $typKey) -and (([string]$key.KeyChar -match '^\d$') -or ($key.Key -eq 'Backspace'))
        if (-not $nglTyping) { $nglBuf = '' }
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
                if ($k -eq 'model') {
                    $pick = Show-ModelPicker -CurrentPath $Cfg.Model.Path
                    $newModel = $null
                    if ($pick.Action -eq 'model' -or $pick.Action -eq 'editlast') { $newModel = $pick.Model }
                    elseif ($pick.Action -eq 'last' -and $script:LastCfg) { $newModel = $script:LastCfg.Model }
                    if ($newModel) {
                        Save-ModelCfg $Cfg $snap0
                        return [pscustomobject]@{ Action = 'switch'; Cfg = (New-CfgForModel $newModel) }
                    }
                } else {
                    Change-CfgSetting $Cfg $k 1
                }
            }
            'Escape' { Save-ModelCfg $Cfg $snap0; return [pscustomobject]@{ Action = 'back' } }
            'Q'      { Save-ModelCfg $Cfg $snap0; return [pscustomobject]@{ Action = 'exit' } }
            'S'      { return [pscustomobject]@{ Action = 'start' } }
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
        param($ServerUrl, $Target, $OpenWebUiUrl, $OpenWebUiBat, $LogDir, $ModelName)

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
                # Inicia o Open WebUI direto (equivale ao iniciar_openwebui.bat)
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

        $serverOk = $false
        $serverDeadline = (Get-Date).AddSeconds(600)
        while ((Get-Date) -lt $serverDeadline) {
            if (Test-WebReady ($ServerUrl + '/health') $true) {
                $serverOk = $true
                break
            }
            Start-Sleep -Milliseconds 700
        }
        if (-not $serverOk) {
            Write-BrowserLog 'Tempo esgotado aguardando o llama-server.'
            return
        }
        Write-BrowserLog 'llama-server pronto.'

        $modelOk = $false
        $modelDeadline = (Get-Date).AddSeconds(1800)
        while ((Get-Date) -lt $modelDeadline) {
            $state = ''
            try {
                $resp = Invoke-WebRequest -Uri ($ServerUrl + '/models') -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                $json = $resp.Content | ConvertFrom-Json
                $items = @()
                if ($json.data) { $items = @($json.data) } elseif ($json.models) { $items = @($json.models) }
                foreach ($it in $items) {
                    if ([string]$it.id -eq $ModelName) {
                        if ($it.status -and $it.status.value) { $state = [string]$it.status.value }
                        break
                    }
                }
            } catch { }
            if ($state -eq 'loaded') { $modelOk = $true; break }
            if ($state -eq 'failed') {
                Write-BrowserLog 'Falha ao carregar o modelo selecionado.'
                break
            }
            Start-Sleep -Milliseconds 700
        }
        if (-not $modelOk) {
            Write-BrowserLog 'Modelo não ficou pronto; navegador não será aberto.'
            return
        }
        Write-BrowserLog ('Modelo ' + $ModelName + ' pronto.')

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
        return Start-Job -ScriptBlock $scriptBlock -ArgumentList $ServerUrl, $Cfg.Browser, $OpenWebUiUrl, $OpenWebUiBat, $LogDir, (Get-PresetName $Cfg.Model)
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
    param($Cfg, [string]$LogPath, [string[]]$ServerArgs, $Research = $null)
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
                Write-Host '  PERIGO:     rede aberta + agente = qualquer aparelho na rede pode executar comandos aqui.' -ForegroundColor Red
            }
        } else {
            Write-Host '  Agente:     indisponível (llama-server.exe antigo, --agent ignorado)' -ForegroundColor Red
        }
    }
    if ([string]$Cfg.Research -eq 'on') {
        if ($Research -and $Research.Ok) {
            Write-Host ('  Pesquisa:   ligada (servidor local na porta {0})' -f $Research.Port) -ForegroundColor Cyan
            if ($Cfg.Host -ne '127.0.0.1') {
                Write-Host '  Atenção:    rede aberta: qualquer aparelho na rede pode usar a pesquisa por este PC.' -ForegroundColor Yellow
            }
        } elseif ($Research) {
            Write-Host ('  Pesquisa:   falhou (' + $Research.Error + ')') -ForegroundColor Red
        } elseif (-not (Test-ResearchSupported)) {
            Write-Host '  Pesquisa:   indisponível (llama-server.exe antigo, sem --ui-mcp-proxy)' -ForegroundColor Red
        } else {
            Write-Host '  Pesquisa:   desativada (Agente ligado)' -ForegroundColor Red
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
    Write-Host '  Comando:' -ForegroundColor DarkGray
    Write-Host ('  ' + (Format-Command $script:ServerExe $ServerArgs)) -ForegroundColor DarkGray
    Write-Host ''
    if ($Cfg.Browser -eq 'none') {
        Write-Host '  Carregando o modelo...' -ForegroundColor Cyan
    } else {
        Write-Host '  Carregando o modelo... o navegador abrirá quando o servidor estiver pronto.' -ForegroundColor Cyan
    }
    Write-Host '  Pressione Ctrl+C nesta janela para encerrar o servidor.' -ForegroundColor DarkGray
    Write-Host '  Pressione Esc duas vezes para encerrar o servidor e voltar ao menu.' -ForegroundColor DarkGray
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
                        [Console]::WriteLine('  Pressione Esc novamente para encerrar o servidor e voltar ao menu.')
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
    param([int]$Port, [string]$ModelName, [double]$TotalBytes)
    $state = [hashtable]::Synchronized(@{ Stop = $false })
    $ps = $null
    $handle = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($State, $ServerPid, $Port, $ModelName, $Total)
            if ($Total -le 0) { $Total = 1 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $childPid = 0
            $row = -1
            while (-not $State.Stop) {
                $loaded = $false
                try {
                    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/models' -f $Port) -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
                    $json = $resp.Content | ConvertFrom-Json
                    $items = @()
                    if ($json.data) { $items = @($json.data) } elseif ($json.models) { $items = @($json.models) }
                    foreach ($it in $items) {
                        if ([string]$it.id -eq $ModelName -and $it.status -and [string]$it.status.value -eq 'loaded') { $loaded = $true }
                    }
                } catch { }
                if ($childPid -eq 0) {
                    foreach ($r in @(Get-CimInstance Win32_Process -Filter ("Name='llama-server.exe' AND ParentProcessId={0}" -f $ServerPid))) {
                        foreach ($c in @(Get-CimInstance Win32_Process -Filter ("Name='llama-server.exe' AND ParentProcessId={0}" -f $r.ProcessId))) { $childPid = [int]$c.ProcessId }
                    }
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
        }).AddArgument($state).AddArgument($PID).AddArgument($Port).AddArgument($ModelName).AddArgument($TotalBytes)
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
        if (Test-ResearchWanted $Cfg) {
            Clear-Screen
            Show-Header 'Preparando pesquisa'
            Write-Host ''
            Write-Host '  Iniciando o servidor de pesquisa (na primeira vez baixa as dependências; pode demorar)...' -ForegroundColor Gray
            $script:Research = Start-ResearchServer $logPath ([int]$Cfg.Ctx)
        }
        $uiConfigPath = ''
        if ($script:Research -and $script:Research.Ok) { $uiConfigPath = [string]$script:Research.UiConfig }
        $serverArgs = Build-ServerArgs $Cfg $logPath $uiConfigPath
        Show-StartSummary $Cfg $logPath $serverArgs $script:Research

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
        $progress = Start-LoadProgress ([int]$Cfg.Port) (Get-PresetName $Cfg.Model) ([double]$Cfg.Model.Size)
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
            Stop-ResearchServer $script:Research
            $script:Research = $null
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

$script:Gpu = Get-GpuInfo
$script:Mem = Get-MemInfo
Initialize-State
Refresh-Models
Initialize-Console
Initialize-Mouse

$exitAll = $false
try {
    try { [Console]::CursorVisible = $false } catch { }
    $currentPath = ''
    while (-not $exitAll) {
        $pick = Show-ModelPicker -CurrentPath $currentPath
        if ($pick.Action -eq 'exit') { break }

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
    Stop-ResearchServer $script:Research
    Disable-Mouse
    try { [Console]::CursorVisible = $true } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'Llama Launcher' } catch { }
}
# === END ===
