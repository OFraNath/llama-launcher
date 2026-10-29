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
    try { [Console]::Clear() } catch { Clear-Host }
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

function Read-Key {
    return [Console]::ReadKey($true)
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

function Test-LanIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -eq '0.0.0.0' -or $Ip -eq '255.255.255.255') { return $false }
    if ($Ip -match '^(127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)') { return $false }
    return $true
}

function Get-LanIPv4 {
    if ($null -ne $script:LanIPv4Cache) { return [string]$script:LanIPv4Cache }
    $script:LanIPv4Cache = ''

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
    if ($null -ne $script:TailscaleIPv4Cache) { return [string]$script:TailscaleIPv4Cache }
    $script:TailscaleIPv4Cache = ''

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
    $base = @(1024, 2048, 4096, 8192, 16384, 32768, 65536)
    $opts = @($base | Where-Object { $_ -le $max })
    if ($opts.Count -eq 0) { $opts = @([Math]::Max(512, $max)) }
    return $opts
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
        Port       = [int]$script:Global.Port
        Host       = [string]$script:Global.Host
        Browser    = [string]$script:Global.Browser
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
        }
        'qualidade' {
            $Cfg.Ctx = [Math]::Min(8192, $maxCtx)
            $Cfg.Ctk = 'f16'
            $Cfg.Ctv = 'f16'
            $Cfg.Ngl = 'auto'
            $Cfg.NPredict = -1
        }
        'longo' {
            $Cfg.Ctx = [Math]::Min(32768, $maxCtx)
            $Cfg.Ctk = 'q4_0'
            $Cfg.Ctv = 'q4_0'
            $Cfg.Ngl = 'auto'
            $Cfg.NPredict = -1
        }
        'cpu' {
            $Cfg.Ctx = [Math]::Min(8192, $maxCtx)
            $Cfg.Ctk = 'q8_0'
            $Cfg.Ctv = 'q8_0'
            $Cfg.Ngl = '0'
            $Cfg.NPredict = -1
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
    if (@('auto', '0', 'all') -notcontains [string]$Cfg.Ngl) { $Cfg.Ngl = 'auto' }
    if (@('off', 'gpu', 'cpu') -notcontains [string]$Cfg.Vision) { $Cfg.Vision = 'off' }
    if (-not $Cfg.Model.Mmproj) { $Cfg.Vision = 'off' }
    if (@('auto', 'on', 'off') -notcontains [string]$Cfg.Reasoning) { $Cfg.Reasoning = 'auto' }
    if (-not $Cfg.Model.Meta.HasThinking) { $Cfg.Reasoning = 'auto' }
    if (@('recomendado', 'qualidade', 'longo', 'cpu', 'personalizado') -notcontains [string]$Cfg.Preset) { $Cfg.Preset = 'personalizado' }
    if ([int]$Cfg.Port -lt 1 -or [int]$Cfg.Port -gt 65535) { $Cfg.Port = 5001 }
    if (@('127.0.0.1', '0.0.0.0', 'tailscale') -notcontains [string]$Cfg.Host) { $Cfg.Host = '127.0.0.1' }
    if (@('llamacpp', 'openwebui', 'none') -notcontains [string]$Cfg.Browser) { $Cfg.Browser = 'llamacpp' }
    if ([int]$Cfg.NPredict -lt -1) { $Cfg.NPredict = -1 }
    if ([int]$Cfg.NPredict -gt 32768) { $Cfg.NPredict = 32768 }
}

# ---------------------------------------------------------------------------
# Persistent state
# ---------------------------------------------------------------------------
$script:Global = [pscustomobject]@{ port = 5001; host = '127.0.0.1'; browser = 'llamacpp' }
$script:StateModels = @{}
$script:LastModelPath = ''
$script:LastCfg = $null
$script:SessionCfg = @{}
$script:Models = @()

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
    }

    $cfg.Port = [int]$script:Global.Port
    $cfg.Host = [string]$script:Global.Host
    $cfg.Browser = [string]$script:Global.Browser
    Normalize-Cfg $cfg
    if ($UseSession) { $script:SessionCfg[$Model.Path] = $cfg }
    return $cfg
}

function Save-Cfg {
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
    }
    $script:LastModelPath = $Cfg.Model.Path
    $script:Global = [pscustomobject]@{
        port    = [int]$Cfg.Port
        host    = [string]$Cfg.Host
        browser = [string]$Cfg.Browser
    }
    $script:LastCfg = $Cfg
    $obj = [pscustomobject]@{
        lastModel = $script:LastModelPath
        global    = $script:Global
        models    = $script:StateModels
    }
    try {
        $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    } catch { }
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

function Get-NglLabel {
    param([string]$Ngl)
    switch ($Ngl) {
        'auto' { return 'automático (--fit)' }
        '0'    { return 'CPU (0 camadas)' }
        'all'  { return 'todas (all)' }
        default { return $Ngl }
    }
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
function Build-ServerArgs {
    param($Cfg, [string]$LogPath)
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('--model'); $a.Add($Cfg.Model.Path)
    $a.Add('--alias'); $a.Add($Cfg.Model.Display)
    $a.Add('--ctx-size'); $a.Add([string]$Cfg.Ctx)
    if ([int]$Cfg.NPredict -ge 0) {
        $a.Add('--n-predict'); $a.Add([string]$Cfg.NPredict)
    }
    $a.Add('--cache-type-k'); $a.Add([string]$Cfg.Ctk)
    $a.Add('--cache-type-v'); $a.Add([string]$Cfg.Ctv)

    $quantK = ($Cfg.Ctk -notin @('f16', 'f32', 'bf16'))
    $quantV = ($Cfg.Ctv -notin @('f16', 'f32', 'bf16'))
    if ($quantK -or $quantV) {
        $a.Add('--flash-attn'); $a.Add('on')
    } else {
        $a.Add('--flash-attn'); $a.Add('auto')
    }

    $a.Add('--fit'); $a.Add('on')
    if ($Cfg.Ngl -ne 'auto') {
        $a.Add('--n-gpu-layers'); $a.Add([string]$Cfg.Ngl)
    }

    if ($Cfg.Vision -ne 'off' -and $Cfg.Model.Mmproj) {
        $a.Add('--mmproj'); $a.Add($Cfg.Model.Mmproj.FullName)
        if ($Cfg.Vision -eq 'cpu') { $a.Add('--no-mmproj-offload') }
    }

    if ($Cfg.Reasoning -ne 'auto' -and $Cfg.Model.Meta.HasThinking) {
        $a.Add('--reasoning'); $a.Add([string]$Cfg.Reasoning)
    }

    $a.Add('--jinja')
    $a.Add('--no-mmap')
    $a.Add('--parallel'); $a.Add('1')
    $a.Add('--host'); $a.Add((Get-BindHost ([string]$Cfg.Host)))
    $a.Add('--port'); $a.Add([string]$Cfg.Port)
    if ($LogPath) {
        $a.Add('--log-file'); $a.Add($LogPath)
    }
    return $a.ToArray()
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
            Write-Row $txt ($i -eq $sel)
        }
        Write-Host ''
        Write-Host '  ↑↓ navegar   Enter confirmar   Esc cancelar' -ForegroundColor DarkGray
        $key = Read-Key
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
            Write-Host '  R atualizar   Esc sair' -ForegroundColor DarkGray
            $key = Read-Key
            if ($key.Key -eq 'Escape' -or $key.Key -eq 'Q') { return [pscustomobject]@{ Action = 'exit' } }
            if ($key.Key -eq 'R' -or $key.Key -eq 'F5') { Refresh-Models; $rebuild = $true }
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
        $footer = '  ↑↓ navegar   Enter abrir   L última   E editar última   R atualizar   Esc sair'
        Write-Host (Cut-Text $footer ($w - 1)) -ForegroundColor DarkGray

        $key = Read-Key
        switch ($key.Key) {
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
            'R' {
                Refresh-Models
                $rebuild = $true
            }
            'F5' {
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
            'Escape' { return [pscustomobject]@{ Action = 'exit' } }
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
    $rows += [pscustomobject]@{ Key = 'kv'; Label = 'KV cache'; Value = ('{0}  ~{1:0.0} GB' -f (Find-KvOption $Cfg).Label, $mi.KvGB); Color = 'White' }
    if ([int]$Cfg.NPredict -lt 0) {
        $np = '-1 (ilimitado)'
    } else {
        $np = ('{0} tokens' -f $Cfg.NPredict)
    }
    $rows += [pscustomobject]@{ Key = 'npredict'; Label = 'Máx. resposta'; Value = $np; Color = 'White' }
    $rows += [pscustomobject]@{ Key = 'ngl'; Label = 'GPU'; Value = (Get-NglLabel $Cfg.Ngl); Color = 'White' }
    if ($Cfg.Model.Mmproj) {
        $rows += [pscustomobject]@{ Key = 'vision'; Label = 'Visão'; Value = (Get-VisionLabel $Cfg); Color = 'White' }
    }
    if ($Cfg.Model.Meta.HasThinking) {
        $reason = $Cfg.Reasoning
        if ($reason -eq 'on') { $reason = 'ligado' }
        elseif ($reason -eq 'off') { $reason = 'desligado' }
        $rows += [pscustomobject]@{ Key = 'reasoning'; Label = 'Raciocínio'; Value = $reason; Color = 'White' }
    }
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
        default { return }
    }
    if (@('preset', 'port', 'host', 'browser') -notcontains $Key) {
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
            Write-SettingRow $rows[$i] ($i -eq $sel)
        }

        $mi = Get-MemoryEstimate $Cfg
        Write-Host ''
        $mm = ''
        if ($mi.MmprojGB -gt 0) { $mm = (' + mmproj {0:0.0}' -f $mi.MmprojGB) }
        $mem = ('  Pesos {0:0.0} + KV {1:0.0}{2} = {3:0.0} GB  |  VRAM livre {4:0.0} GB' -f `
            $mi.WeightsGB, $mi.KvGB, $mm, ($mi.WeightsGB + $mi.KvGB + $mi.MmprojGB), $mi.FreeVram)
        Write-Host (Cut-Text $mem ($w - 1)) -ForegroundColor DarkGray

        $tag = '!'
        $color = 'Red'
        if ($mi.Level -eq 'good') { $tag = 'OK'; $color = 'Green' }
        elseif ($mi.Level -eq 'warn') { $tag = '~'; $color = 'Yellow' }
        elseif ($mi.Level -eq 'dim') { $tag = 'CPU'; $color = 'DarkGray' }
        Write-Host ('  [' + $tag + '] ' + $mi.Text) -ForegroundColor $color
        if ($mi.Level -eq 'bad') {
            Write-Host '      Reduza o contexto/KV ou deixe a GPU no automático (--fit).' -ForegroundColor DarkYellow
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

        Write-Host ''
        $footer = '  ↑↓ navegar   ←→ alterar   Enter editar/iniciar   Esc voltar   Q sair'
        Write-Host (Cut-Text $footer ($w - 1)) -ForegroundColor DarkGray

        $key = Read-Key
        switch ($key.Key) {
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
                        return [pscustomobject]@{ Action = 'switch'; Cfg = (New-CfgForModel $newModel) }
                    }
                } else {
                    Change-CfgSetting $Cfg $k 1
                }
            }
            'Escape' { return [pscustomobject]@{ Action = 'back' } }
            'Q'      { return [pscustomobject]@{ Action = 'exit' } }
            'S'      { return [pscustomobject]@{ Action = 'start' } }
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

        try {
            $warmBody = '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0,"stream":false}'
            $warmBytes = [System.Text.Encoding]::UTF8.GetBytes($warmBody)
            $null = Invoke-WebRequest -Uri ($ServerUrl + '/v1/chat/completions') -Method Post -ContentType 'application/json' -Body $warmBytes -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
            Write-BrowserLog 'Modelo carregado por completo.'
        } catch {
            Write-BrowserLog ('Aquecimento falhou: ' + $_.Exception.Message)
        }

        if ($Target -eq 'none') {
            return
        }

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

function Show-StartSummary {
    param($Cfg, [string]$LogPath, [string[]]$ServerArgs)
    $w = Get-UIWidth
    Clear-Screen
    Show-Header 'Iniciando servidor'
    Write-Host ''
    Write-Host ('  Modelo:     ' + $Cfg.Model.Display) -ForegroundColor White
    Write-Host ('  Contexto:   {0} tokens   |   KV: {1} / {2}' -f $Cfg.Ctx, $Cfg.Ctk, $Cfg.Ctv) -ForegroundColor Gray
    Write-Host ('  GPU:        {0}   |   Visão: {1}   |   Raciocínio: {2}' -f (Get-NglLabel $Cfg.Ngl), (Get-VisionLabel $Cfg), $Cfg.Reasoning) -ForegroundColor Gray
    Write-Host ('  Porta:      {0}   |   Navegador: {1}' -f $Cfg.Port, (Get-BrowserLabel $Cfg.Browser)) -ForegroundColor Gray
    Write-Host ('  Rede:       ' + (Get-HostLabel $Cfg.Host)) -ForegroundColor Gray
    $accessUrl = Get-ServerAccessUrl $Cfg.Host ([int]$Cfg.Port)
    if ($accessUrl) {
        Write-Host ('  Acesso:     ' + $accessUrl) -ForegroundColor Cyan
    } elseif ($Cfg.Host -eq 'tailscale') {
        Write-Host '  Acesso:     Tailscale não detectado' -ForegroundColor Yellow
    }

    $mi = Get-MemoryEstimate $Cfg
    Write-Host ('  Memória:    pesos {0:0.0} + KV {1:0.0} + mmproj {2:0.0} = {3:0.0} GB  |  VRAM livre {4:0.0} GB' -f `
        $mi.WeightsGB, $mi.KvGB, $mi.MmprojGB, ($mi.WeightsGB + $mi.KvGB + $mi.MmprojGB), $mi.FreeVram) -ForegroundColor DarkGray
    if ($LogPath) { Write-Host ('  Log:        ' + $LogPath) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  Comando:' -ForegroundColor DarkGray
    Write-Host ('  ' + (Format-Command $script:ServerExe $ServerArgs)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Carregando o modelo... o navegador abrirá quando o modelo estiver totalmente carregado.' -ForegroundColor Cyan
    Write-Host '  Pressione Ctrl+C nesta janela para encerrar o servidor.' -ForegroundColor DarkGray
    Write-Host ''
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
                    try { Start-Process ("http://127.0.0.1:{0}" -f $port) | Out-Null } catch { }
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

        $mi = Get-MemoryEstimate $Cfg
        if ($mi.Level -eq 'bad' -and $mi.NeedRam -gt ($mi.FreeRam - 1.0)) {
            $choice = Show-Choice -Title 'Aviso de RAM' `
                -Message ("A estimativa indica que o modelo pode não caber na RAM disponível.`n`nRAM necessária: {0:0.0} GB | livre: {1:0.0} GB`n`nFeche outros programas ou reduza o contexto/KV." -f $mi.NeedRam, $mi.FreeRam) `
                -Options @('Voltar e ajustar', 'Iniciar mesmo assim') -Default 0
            if ($choice -ne 1) { return 'settings' }
        } elseif ($Cfg.Ngl -eq 'all' -and $mi.Level -eq 'bad') {
            $choice = Show-Choice -Title 'Aviso de VRAM' `
                -Message ("Todas as camadas foram forçadas para a GPU, mas a estimativa indica VRAM insuficiente.`n`nVRAM necessária: {0:0.0} GB | livre: {1:0.0} GB" -f $mi.NeedVram, $mi.FreeVram) `
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
            $safe = ($Cfg.Model.Display -replace '[^\w\-\. ]', '_')
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'modelo' }
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $logPath = Join-Path $script:LogDir ('server_{0}_{1}.log' -f $stamp, $safe)
        } catch { $logPath = '' }

        $serverArgs = Build-ServerArgs $Cfg $logPath
        Show-StartSummary $Cfg $logPath $serverArgs

        $serverUrl = ('http://127.0.0.1:{0}' -f [int]$Cfg.Port)
        $owuiUrl = 'http://localhost:8080'
        $owuiBat = Join-Path $script:Root 'iniciar_openwebui.bat'
        $browserJob = Start-BrowserJob $Cfg $serverUrl $owuiUrl $owuiBat $script:LogDir

        try { $Host.UI.RawUI.WindowTitle = ('llama-server  |  ' + $Cfg.Model.Display) } catch { }
        try { [Console]::CursorVisible = $true } catch { }

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
        }

        if ($browserJob) {
            try { Stop-Job $browserJob -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job $browserJob -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { $Host.UI.RawUI.WindowTitle = 'Llama Launcher' } catch { }
        try { [Console]::CursorVisible = $false } catch { }

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
    try { [Console]::CursorVisible = $true } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'Llama Launcher' } catch { }
}
# === END ===
