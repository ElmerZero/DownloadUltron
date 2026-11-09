[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Entrada,
    [string]$Urls,
    [string]$Lote,
    [string]$Destino,
    [string]$Formato,
    [ValidateRange(1, 8)][int]$Canales,
    [switch]$Listas,
    [switch]$Brave,
    [string]$PerfilBrave,
    [ValidateSet('brave','chrome','edge','firefox')][string]$Navegador,
    [string]$Perfil,
    [string]$Cookies,
    [switch]$Ejecutar,
    [switch]$Diagnostico,
    [switch]$Actualizar,
    [switch]$SinActualizar
)

$ErrorActionPreference = 'Stop'
$script:Base = $PSScriptRoot
$script:Tools = Join-Path $Base 'tools'
$script:State = Join-Path $Base '.state'
$script:ToolNames = @('yt-dlp', 'ffmpeg', 'ffprobe', 'deno')
$script:Spec = Get-Content -LiteralPath (Join-Path $Base 'engine.json') -Encoding utf8 -Raw | ConvertFrom-Json
$script:Formats = @{}
foreach ($item in $Spec.formats) { $Formats[$item.id] = $item }
$script:Browsers = @{}
foreach ($item in $Spec.cookieBrowsers) { $Browsers[$item.id] = $item }
$script:Attempts = $Spec.retrySeconds.Count + 1
$script:Final = @('LISTO', 'OMITIDO', 'ERROR', 'DETENIDO')
$script:Active = @('ABRIENDO', 'DESCARGA', 'PROCESANDO')
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:Escape = [char]27
$script:UseVT = $false
$script:ConsoleOutput = -not [Console]::IsOutputRedirected
$script:CanReadKey = -not [Console]::IsInputRedirected
$script:Activity = [Collections.Generic.Queue[string]]::new()

function Enable-Terminal {
    if (!$ConsoleOutput) { return }
    try {
        if (!('DownloadUltronTerminal' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DownloadUltronTerminal {
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern bool WriteConsoleW(IntPtr handle, string text, uint length, out uint written, IntPtr reserved);
    private static uint originalMode;
    private static bool modeChanged;

    public static bool Enable() {
        IntPtr handle = GetStdHandle(-11);
        if (!GetConsoleMode(handle, out originalMode) || !SetConsoleMode(handle, originalMode | 4))
            return false;
        modeChanged = true;
        return true;
    }

    public static bool Write(string text) {
        uint written;
        return WriteConsoleW(GetStdHandle(-11), text, (uint)text.Length, out written, IntPtr.Zero);
    }

    public static void Restore() {
        if (modeChanged)
            SetConsoleMode(GetStdHandle(-11), originalMode);
        modeChanged = false;
    }
}
'@
        }
        $script:UseVT = [DownloadUltronTerminal]::Enable()
    } catch { $script:UseVT = $false }
}

function Write-Terminal([string]$Text) {
    if ($UseVT -and [DownloadUltronTerminal]::Write($Text)) { return }
    [Console]::Write($Text)
}

function Clean-Text([string]$Text) {
    return [regex]::Replace($Text, '[\p{Cc}\p{Cf}]', '')
}

function Fit-Text([string]$Text, [int]$Width) {
    $text = Clean-Text $Text
    if ($text.Length -gt $Width) {
        $text = $text.Substring(0, $Width)
        if ($text.Length -and [char]::IsHighSurrogate($text[$text.Length - 1])) {
            $text = $text.Substring(0, $text.Length - 1)
        }
    }
    return $text.PadRight($Width)
}

function Color([string]$Text, [string]$Code) {
    if ($UseVT -and $null -eq $env:NO_COLOR) { return "$Escape[$($Code)m$Text$Escape[0m" }
    return $Text
}

function Log([string]$Line) {
    $Activity.Enqueue((Clean-Text $Line))
    if ($Activity.Count -gt 8) { $null = $Activity.Dequeue() }
}

function Get-LinkKey([string]$Link) {
    if ($Link -notmatch '^https?://' -or $Link -match '[\s\p{Cc}]') { return $null }
    $uri = $null
    if (![uri]::TryCreate($Link, [UriKind]::Absolute, [ref]$uri) -or !$uri.Host -or $uri.UserInfo) { return $null }
    $video = ''
    if ($uri.Query -notmatch '(?:[?&])list=') {
        $path = $uri.AbsolutePath.Trim('/')
        if ($uri.Host -in @('youtu.be', 'www.youtu.be')) { $video = $path }
        if ($uri.Host -in @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com')) {
            if ($path -ceq 'watch' -and $uri.Query -cmatch '(?:[?&])v=([^&]+)') { $video = $Matches[1] }
            elseif ($path -cmatch '^(?:shorts|live|embed)/(.+)$') { $video = $Matches[1] }
        }
    }
    if ($video -cmatch '^[A-Za-z0-9_-]{11}$') { return "youtube:$video" }
    return $Link
}

function Add-Links($Queue, [string]$Text) {
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($job in $Queue) { $null = $known.Add($job.Key) }
    $added = $duplicates = $invalid = 0
    foreach ($value in [regex]::Split($Text.TrimStart([char]0xFEFF), '(?i)[\r\n]+|,\s*(?=https?://)')) {
        $link = ([regex]::Split($value, '\t', 2)[0]).Trim()
        if (!$link -or $link.StartsWith('#')) { continue }
        $key = Get-LinkKey $link
        if (!$key) { $invalid++; continue }
        if (!$known.Add($key)) { $duplicates++; continue }
        $Queue.Add([pscustomobject]@{
            Url = $link; Key = $key; Title = ''; Status = 'COLA'; Attempt = 0; Percent = $null
            Speed = 0; Eta = $null; Due = 0; ErrorText = ''; ErrorHint = ''; FailedAt = 0
            AuthError = $false; AuthWarning = $false; AuthDiagnostic = $null; AuthWarningId = ''
            Files = 0; Archived = $false; Existing = $false; Transferred = $false
            FileName = $null; Stream = 0; Streams = 1; Entry = 0; Entries = 0
        })
        $added++
    }
    Log "$added añadido(s) · $duplicates duplicado(s) · $invalid inválido(s)"
}

function Get-Path([string]$Value) {
    $value = $Value.Trim()
    if ($value.Length -ge 2 -and $value[0] -in @('"', "'") -and $value[0] -eq $value[$value.Length - 1]) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ($value -match '^~[\\/]') { $value = Join-Path $HOME $value.Substring(2) }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value)
}

function Read-List([string]$Path) {
    $file = Get-Item -LiteralPath (Get-Path $Path)
    if ($file.PSIsContainer -or $file.Length -gt 8MB) { throw 'Selecciona un archivo de texto de hasta 8 MiB.' }
    return [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
}

function Read-Settings {
    $options = @{
        destino = Join-Path $HOME 'Downloads/DownloadUltron'; formato = 'mp3_320'; trabajadores = 3
        listas = $false; cookies = 'ninguna'; perfil = ''; archivo = ''
    }
    try {
        $saved = Get-Content -LiteralPath (Join-Path $State 'opciones.json') -Raw -Encoding utf8 | ConvertFrom-Json
        if ($saved.destino -is [string] -and $saved.destino) { $options.destino = $saved.destino }
        if ($saved.formato -is [string] -and $Formats.ContainsKey($saved.formato)) { $options.formato = $saved.formato }
        if ($saved.trabajadores -in (1..8)) { $options.trabajadores = [int]$saved.trabajadores }
        $options.listas = $saved.listas -eq $true
    } catch {}
    return $options
}

function Save-Settings($Options) {
    $saved = @{destino = $Options.destino; formato = $Options.formato; trabajadores = $Options.trabajadores; listas = $Options.listas}
    [IO.File]::WriteAllText((Join-Path $State 'opciones.json'), ($saved | ConvertTo-Json), $Utf8)
}

function Lock-Batch {
    $null = [IO.Directory]::CreateDirectory($State)
    $file = [IO.File]::Open((Join-Path $State 'lote.lock'), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
    try { $file.Lock(0, 1) }
    catch {
        $file.Dispose()
        throw 'Hay otro lote o una actualización en esta carpeta de DownloadUltron.'
    }
    return $file
}

function Quote-Argument([string]$Value) {
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Start-Tool([string]$Program, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Program
    $start.Arguments = ($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.StandardOutputEncoding = $Utf8
    $start.StandardErrorEncoding = $Utf8
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Close()
    return $process
}

function Stop-Tool($Process) {
    if (!$Process.HasExited) {
        $kill = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
        try {
            $stopper = Start-Tool $kill @('/T', '/F', '/PID', [string]$Process.Id)
            if (!$stopper.WaitForExit(4000)) { $stopper.Kill() }
            $stopper.Dispose()
        } catch {}
        if (!$Process.HasExited) { $Process.Kill() }
        $null = $Process.WaitForExit(5000)
    }
    $Process.Dispose()
}

function Invoke-Tool([string]$Program, [string[]]$Arguments, [int]$Timeout) {
    $process = Start-Tool $Program $Arguments
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($Timeout)) { throw 'La herramienta no respondió a tiempo.' }
        if (!$stdout.Wait(2000) -or !$stderr.Wait(2000)) { throw 'La herramienta dejó su salida abierta.' }
        return [pscustomobject]@{Code = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result}
    } finally { Stop-Tool $process }
}

function Get-Missing {
    foreach ($name in $ToolNames) {
        if (![IO.File]::Exists((Join-Path $Tools "$name.exe"))) { $name }
    }
}

function Prepare-Tools {
    if (@(Get-Missing).Count) {
        Write-Host 'Preparando herramientas en la carpeta de DownloadUltron…'
        & (Join-Path $Base 'scripts/Get-Tools.ps1')
        if (@(Get-Missing).Count) { throw 'No se pudieron preparar todas las herramientas.' }
    }
}

function Update-Motor([bool]$Force) {
    $stamp = Join-Path $State 'yt-dlp-check.txt'
    $last = 0L
    if ([IO.File]::Exists($stamp)) { $null = [long]::TryParse([IO.File]::ReadAllText($stamp).Trim(), [ref]$last) }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (!$Force -and $now -ge $last -and $now - $last -lt $Spec.updateSeconds) { return $true }
    [IO.File]::WriteAllText($stamp, [string]$now, [Text.Encoding]::ASCII)
    Write-Host 'Buscando actualización oficial de yt-dlp…'
    try {
        $result = Invoke-Tool (Join-Path $Tools 'yt-dlp.exe') $Spec.updateArgs 45000
        if ($result.Code -eq 0) {
            $line = ($result.Out.Trim() -split '\r?\n')[-1]
            if (!$line) { $line = 'Motor al día.' }
            Write-Host (Clean-Text $line)
            return $true
        }
    } catch {}
    Write-Host 'No se pudo actualizar. Se usará el motor local.'
    return $false
}

function Check-Cookies($Options) {
    if ($Browsers.ContainsKey($Options.cookies) -and ($Options.perfil -in @('.', '..') -or $Options.perfil -match '[\\/:]' -or
        (Clean-Text $Options.perfil) -cne $Options.perfil)) {
        throw 'Usa el nombre de carpeta del perfil, como Default o Profile 1.'
    }
    if ($Options.cookies -eq 'archivo') {
        $reader = [IO.StreamReader]::new($Options.archivo)
        try { $header = $reader.ReadLine() }
        finally { $reader.Dispose() }
        if ($header -cnotin @('# Netscape HTTP Cookie File', '# HTTP Cookie File')) {
            throw 'El archivo debe tener el encabezado Netscape HTTP Cookie File.'
        }
    }
}

function Start-Download($Job, $Options) {
    $fmt = $Formats[$Options.formato]
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($Job.Key)))).Replace('-', '').Substring(0, 20).ToLowerInvariant() }
    finally { $sha.Dispose() }
    $partial = Join-Path $Options.destino ".ultron-parciales/$($fmt.id)-$digest"
    $output = '%(title).110s [%(id)s] (' + $fmt.suffix + ').%(ext)s'
    $arguments = @($Spec.downloadArgs) + @($fmt.args) + @(
        '--ffmpeg-location', $Tools, '--js-runtimes', ('deno:' + (Join-Path $Tools 'deno.exe')),
        '--paths', "home:$($Options.destino)", '--paths', "temp:$partial",
        '--download-archive', (Join-Path $Options.destino "_completados_$($fmt.id).txt"), '-o', $output
    )
    if ($Options.listas) { $arguments += '--yes-playlist' }
    else { $arguments += @('--no-playlist', '--playlist-end', '1') }
    $copy = $null
    $process = $null
    try {
        if ($Browsers.ContainsKey($Options.cookies)) {
            $browserArg = $Options.cookies
            if ($Options.perfil) { $browserArg += ':' + $Options.perfil }
            $arguments += @('--cookies-from-browser', $browserArg)
        } elseif ($Options.cookies -eq 'archivo') {
            $copy = [IO.Path]::GetTempFileName()
            [IO.File]::Copy($Options.archivo, $copy, $true)
            $arguments += @('--cookies', $copy)
        }
        $arguments += @('--', $Job.Url)
        $process = Start-Tool (Join-Path $Tools 'yt-dlp.exe') $arguments
        return [pscustomobject]@{
            Job = $Job; Process = $process; Copy = $copy; Partial = $partial
            Out = $process.StandardOutput.ReadLineAsync(); Err = $process.StandardError.ReadLineAsync()
        }
    } catch {
        if ($process) { Stop-Tool $process }
        if ($copy) { [IO.File]::Delete($copy) }
        throw
    }
}

function Read-Telemetry($Job, [string]$Line) {
    if ($Line -cmatch '^DU-(META|DOWN|POST|FILE) (.+)$') {
        $tag = $Matches[1]
        $payload = $Matches[2]
        if ($tag -eq 'FILE') { $Job.Files++; return }
        if ($tag -eq 'POST') {
            if ($payload -in @('"started"', '"processing"')) { $Job.Status = 'PROCESANDO'; $Job.Speed = 0; $Job.Eta = $null }
            return
        }
        try { $data = ConvertFrom-Json -InputObject $payload } catch { return }
        if ($tag -eq 'META') {
            $Job.Title = if ($data.title) { Clean-Text $data.title } else { $Job.Url }
            $Job.Entry = $data.entry; $Job.Entries = $data.entries
            $Job.Stream = 0; $Job.FileName = $null
            $Job.Streams = if ($data.second) { 2 } else { 1 }
            $Job.Status = 'ABRIENDO'; $Job.Percent = $null; $Job.Speed = 0; $Job.Eta = $null
        } else {
            if ($Job.FileName -and $Job.FileName -cne $data.file) { $Job.Stream = [Math]::Min($Job.Stream + 1, $Job.Streams - 1) }
            $Job.FileName = $data.file
            $total = if ($data.total) { $data.total } else { $data.estimate }
            $finished = $data.status -eq 'finished'
            if ($data.got -gt 0 -and !$finished) { $Job.Transferred = $true }
            $fraction = if ($finished) { 1.0 } elseif ($total -gt 0) { [Math]::Min($data.got / $total, 1.0) } else { $null }
            $Job.Status = 'DESCARGA'
            $Job.Percent = if ($null -ne $fraction) { [Math]::Min(99, 100 * ($Job.Stream + $fraction) / $Job.Streams) } else { $null }
            $Job.Speed = if ($finished -or !$data.speed) { 0 } else { $data.speed }
            $Job.Eta = if ($finished) { $null } else { $data.eta }
        }
        return
    }
    if ($Line.Contains('has already been recorded in the archive')) { $Job.Archived = $true }
    if ($Line.Contains('has already been downloaded')) { $Job.Existing = $true }
    if ($Line -cmatch '^(ERROR|WARNING):') {
        $diagnostic = $null
        foreach ($rule in $Spec.cookieDiagnostics) {
            if ($Line -match $rule.pattern) { $diagnostic = $rule; break }
        }
        if ($Line.StartsWith('WARNING:')) {
            if ($diagnostic -and $diagnostic.id -eq 'protected') { $Job.AuthWarningId = $diagnostic.id }
            if ($Line -match $Spec.cookieWarning) { $Job.AuthWarning = $true }
        } else {
            $Job.ErrorText = (Fit-Text ($Line.Substring(6).Trim()) 500).TrimEnd()
            if ($diagnostic) {
                if ($diagnostic.id -eq 'session_required' -and $Job.AuthWarningId -eq 'protected') {
                    $diagnostic = $Spec.cookieDiagnostics | Where-Object id -eq 'protected' | Select-Object -First 1
                }
                $Job.AuthDiagnostic = $diagnostic
                $Job.AuthError = $true
            } elseif ($Line -match $Spec.cookieError) { $Job.AuthError = $true }
        }
    }
}

function Summary($Jobs) {
    $labels = foreach ($label in @('LISTO', 'OMITIDO', 'ERROR', 'DETENIDO')) {
        '{0} {1}' -f @($Jobs | Where-Object Status -eq $label).Count, $label.ToLowerInvariant()
    }
    return ($labels -join ' · ')
}

function Gauge($Percent, [int]$Width, [int]$Tone = 91) {
    $filled = if ($null -eq $Percent) { 0 } else { [int][Math]::Floor([Math]::Max(0, [Math]::Min(100, $Percent)) * $Width / 100) }
    return ((Color '[' 90) + (Color ('=' * $filled) $Tone) + (Color ('-' * ($Width - $filled)) 90) + (Color ']' 90))
}

function Speed-Label([double]$Value) {
    if (!$Value) { return '-' }
    if ($Value -ge 1MB) { return ('{0:0.0}M/s' -f ($Value / 1MB)) }
    return ('{0:0}K/s' -f ($Value / 1KB))
}

function Panel-Width {
    if ($ConsoleOutput) {
        return [Math]::Max(12, [Math]::Min([Console]::WindowWidth - 3, 112))
    }
    return 104
}

function Panel-Height {
    if ($ConsoleOutput) { return [Console]::WindowHeight }
    return 30
}

function Visible-Rows([bool]$Running = $false) {
    $height = Panel-Height
    $width = Panel-Width
    $reserved = if ($Running) { 15 } else { 16 + @(Panel-Menu $width $false).Count }
    return [Math]::Max(1, [Math]::Min($height - $reserved, 14))
}

function Panel-Heading([string]$Left, [string]$Right, [int]$Width, [string]$LeftTone, [string]$RightTone) {
    if ($Left.Length + $Right.Length + 2 -gt $Width) {
        return (Color (Fit-Text $Left $Width).TrimEnd() $LeftTone)
    }
    return ((Color $Left $LeftTone) + (' ' * ($Width - $Left.Length - $Right.Length)) + (Color $Right $RightTone))
}

function Panel-Actions([int]$Width, [string[]]$Actions, [bool]$CanStart) {
    $line = ''
    $used = 0
    foreach ($action in $Actions) {
        $actionText = (Fit-Text $action $Width).TrimEnd()
        if ($used -and $used + $actionText.Length -gt $Width) {
            $line.TrimEnd()
            $line = ''
            $used = 0
        }
        $code = if ($CanStart -and $action.StartsWith('[7]')) { '1;97;41' } else { '37' }
        $line += (Color $actionText $code) + '   '
        $used += $actionText.Length + 3
    }
    return $line.TrimEnd()
}

function Panel-Menu([int]$Width, [bool]$CanStart) {
    Panel-Actions $Width @('[1] Cargar TXT', '[2] Pegar enlaces', '[7] Iniciar') $CanStart
    Panel-Actions $Width @('[3] Destino', '[4] Formato', '[6] Cookies', '[?] Más', '[Q] Salir') $false
}

function Show-Panel($Jobs, $Options, [bool]$Running, [int]$Page = 0) {
    $width = Panel-Width
    $sum = $speed = $complete = $skipped = $failed = $stopped = $queued = 0
    $latestFailure = $null
    foreach ($job in $Jobs) {
        switch ($job.Status) {
            'LISTO'    { $complete++ }
            'OMITIDO'  { $skipped++ }
            'ERROR'    {
                $failed++
                if (!$latestFailure -or $job.FailedAt -ge $latestFailure.FailedAt) { $latestFailure = $job }
            }
            'DETENIDO' { $stopped++ }
            'COLA'     { $queued++ }
        }
        if ($job.Status -in $Active) {
            $fraction = [double]$job.Percent / 100
            if ($job.Entry -and $job.Entries -gt 1) { $fraction = [Math]::Min(0.99, ($job.Entry - 1 + $fraction) / $job.Entries) }
            $sum += $fraction
        }
        $speed += $job.Speed
    }
    $closed = $complete + $skipped + $failed
    $sum += $closed
    $percent = if ($Jobs.Count) { 100.0 * $sum / $Jobs.Count } else { 0.0 }
    $auth = switch ($Options.cookies) {
        'archivo' { 'archivo Netscape' }
        'ninguna' { 'sin cookies' }
        default {
            $label = $Browsers[$Options.cookies].name
            if ($Options.perfil) { $label + ' / ' + $Options.perfil } else { $label }
        }
    }
    $stateText = '[ EN ESPERA ]'
    $stateTone = '37'
    if ($Running) { $stateText = '[ EN CURSO ]'; $stateTone = '97' }
    elseif ($failed) { $stateText = '[ CON ERRORES ]'; $stateTone = '91' }
    elseif ($stopped) { $stateText = '[ DETENIDO ]'; $stateTone = '93' }
    elseif ($closed -and $closed -eq $Jobs.Count) { $stateText = '[ FINALIZADO ]'; $stateTone = '92' }
    $rows = Visible-Rows $Running
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((Panel-Heading 'DOWNLOAD ULTRON' "V$($Spec.version)" $width '1;91' 37))
    $lines.Add((Color (Fit-Text $stateText $width).TrimEnd() $stateTone))
    $lines.Add('')
    $meter = "$closed/$($Jobs.Count) procesados"
    if ($speed -and $width -ge 52) { $meter += '   ' + (Speed-Label $speed) }
    $barWidth = [Math]::Min(28, $width - $meter.Length - 4)
    $barTone = if ($failed -or $stopped) { 37 } elseif ($closed -and $closed -eq $Jobs.Count) { 92 } else { 91 }
    if ($barWidth -ge 4) {
        $lines.Add((Gauge $percent $barWidth $barTone) + '  ' + (Color $meter 97))
    } else { $lines.Add((Fit-Text $meter $width).TrimEnd()) }
    $readyLabel = if ($complete -eq 1) { 'listo' } else { 'listos' }
    $errorLabel = if ($failed -eq 1) { 'error' } else { 'errores' }
    $result = "$complete $readyLabel  ·  $failed $errorLabel"
    if ($skipped) { $result += "  ·  $skipped omitidos" }
    if ($stopped) { $result += "  ·  $stopped detenidos" }
    $lines.Add((Color (Fit-Text $result $width).TrimEnd() 37))
    $profile = "$($Formats[$Options.formato].name)  /  $($Options.trabajadores) canales  /  $auth"
    if ($Options.listas) { $profile += '  /  listas completas' }
    $lines.Add((Color (Fit-Text $profile $width).TrimEnd() 37))
    $lines.Add((Color (Fit-Text ("Destino  " + $Options.destino) $width).TrimEnd() 37))
    $lines.Add('')
    $linkWord = if ($Jobs.Count -eq 1) { 'ENLACE' } else { 'ENLACES' }
    $lines.Add((Panel-Heading 'Cola' "$($Jobs.Count) $linkWord" $width '1;97' 37))
    if (!$Jobs.Count) {
        $lines.Add((Color (Fit-Text 'Carga un TXT o pega un enlace para empezar.' $width).TrimEnd() 37))
    }
    if ($Running) {
        $indices = @(for ($i = 0; $i -lt $Jobs.Count; $i++) {
            $rank = if ($Jobs[$i].Status -in $Active) { 0 } elseif ($Jobs[$i].Status -eq 'ESPERA') { 1 } elseif ($Jobs[$i].Status -eq 'COLA') { 2 } else { 3 }
            [pscustomobject]@{Index = $i; Rank = $rank}
        })
        $visible = @($indices | Sort-Object Rank,Index | Select-Object -First $rows | Sort-Object Index | ForEach-Object Index)
    } else {
        $first = [Math]::Min($Page * $rows, [Math]::Max(0, [Math]::Floor(($Jobs.Count - 1) / $rows) * $rows))
        $visible = @(for ($i = $first; $i -lt [Math]::Min($first + $rows, $Jobs.Count); $i++) { [int]$i })
    }
    $indexWidth = [Math]::Max(3, ([string]$Jobs.Count).Length)
    $rowBarWidth = if ($width -ge 76) { 12 } else { 7 }
    $rowProgressWidth = $rowBarWidth + 7
    $titleWidth = if ($width -ge 76) { $width - $indexWidth - 49 - $rowBarWidth } else { $width - $indexWidth - 24 - $rowBarWidth }
    $idleTitleWidth = [Math]::Max(1, $width - $indexWidth - 21)
    if ($visible.Count -and !$Running -and $width -ge 40) {
        $lines.Add((Color ('{0}  {1}  {2,-11}  INT.' -f '#'.PadLeft($indexWidth), (Fit-Text 'ENLACE' $idleTitleWidth), 'ESTADO') 37))
    } elseif ($visible.Count -and $Running -and $width -ge 50) {
        $header = ('{0}  {1}  {2,-11}  {3}' -f '#'.PadLeft($indexWidth), (Fit-Text 'ENLACE' $titleWidth), 'ESTADO', (Fit-Text 'PROGRESO' $rowProgressWidth))
        if ($width -ge 76) { $header += '  {0,-8}  {1,-6}  {2}' -f 'VEL.', 'ETA', 'INT.' }
        $lines.Add((Color $header.TrimEnd() 37))
    }
    foreach ($index in $visible) {
        $job = $Jobs[$index]
        $status = if ($job.Status -eq 'ESPERA') { 'REINT. {0:00}s' -f [Math]::Max(0, [Math]::Ceiling($job.Due - $Clock.Elapsed.TotalSeconds)) } else { $job.Status }
        $tone = if ($job.Status -in @('LISTO','OMITIDO')) { 92 } elseif ($job.Status -eq 'ERROR') { 91 } elseif ($job.Status -in @('ESPERA','DETENIDO')) { 93 } elseif ($job.Status -in $Active) { 97 } else { 37 }
        $title = if ($job.Title) { $job.Title } else { $job.Url }
        if ($job.Entry -and $job.Entries -gt 1) { $title = "$($job.Entry)/$($job.Entries) $title" }
        $pct = if ($null -eq $job.Percent) { '   -' } else { ('{0,3:0}%' -f $job.Percent) }
        $eta = if ($null -eq $job.Eta) { '-' } else { '{0:00}:{1:00}' -f [Math]::Floor($job.Eta / 60), ($job.Eta % 60) }
        $attempt = if ($job.Attempt) { "$($job.Attempt)/$Attempts" } else { '-' }
        $id = ([string]($index + 1)).PadLeft($indexWidth)
        if (!$Running -and $width -ge 40) {
            $lines.Add("$id  $(Fit-Text $title $idleTitleWidth)  $(Color (Fit-Text $status 11) $tone)  $attempt")
        } elseif ($Running -and $width -ge 50) {
            $row = "$id  $(Fit-Text $title $titleWidth)  $(Color (Fit-Text $status 11) $tone)  $(Gauge $job.Percent $rowBarWidth $tone) $pct"
            if ($width -ge 76) {
                $row += '  {0,-8}  {1,-6}  {2}' -f (Speed-Label $job.Speed), $eta, $attempt
            }
            $lines.Add($row)
        } else {
            $reading = if ($Running) { "$pct  " } else { '' }
            $lines.Add((Fit-Text "$id  $status  $reading$attempt  $title" $width).TrimEnd())
        }
    }
    if ($Jobs.Count -gt $visible.Count) { $lines.Add((Fit-Text "$($visible.Count) visibles / $($Jobs.Count)" $width)) }
    if ($latestFailure) {
        $lines.Add('')
        $lines.Add((Color (Fit-Text ("Error  " + $latestFailure.ErrorText) $width).TrimEnd() 91))
        if ($latestFailure.ErrorHint) { $lines.Add((Fit-Text $latestFailure.ErrorHint $width).TrimEnd()) }
        if (!$Running) { $lines.Add((Color (Fit-Text '[E] Ver detalle   [R] Reintentar' $width).TrimEnd() 97)) }
    } elseif ($Activity.Count) {
        $event = $Activity | Select-Object -Last 1
        $lines.Add('')
        $lines.Add((Color (Fit-Text $event $width).TrimEnd() 37))
    }
    $lines.Add('')
    if ($Running) { $lines.Add((Color (Fit-Text '[X] Detener lote   [Ctrl+C] Cancelar' $width).TrimEnd() 93)) }
    else {
        foreach ($line in @(Panel-Menu $width ($queued -gt 0 -or $stopped -gt 0))) { $lines.Add($line) }
    }
    $indented = @($lines | ForEach-Object { if ($_) { '  ' + $_ } else { '' } })
    if ($UseVT) {
        $newline = [Environment]::NewLine
        Write-Terminal ("$Escape[H" + ($indented -join "$Escape[K$newline") + "$Escape[K$Escape[J")
    } else { Write-Host ($indented -join [Environment]::NewLine) }
}

function Register-Failure($Job, $Options, $Run) {
    $Job.Status = 'ERROR'
    $Job.Percent = $null
    $Job.FailedAt = $Clock.Elapsed.TotalMilliseconds
    if ($Job.AuthDiagnostic) {
        $source = if ($Browsers.ContainsKey($Options.cookies)) { $Browsers[$Options.cookies].name } else { 'la fuente seleccionada' }
        $Job.ErrorText = $Job.AuthDiagnostic.detail -f $source
        $Job.ErrorHint = $Job.AuthDiagnostic.hint -f $source
    } elseif ($Job.AuthError) {
        $Job.ErrorText = if ($Browsers.ContainsKey($Options.cookies)) { $Spec.cookieHelp -f $Browsers[$Options.cookies].name }
        else { 'Revisa que el archivo Netscape sea válido y esté vigente.' }
    }
    Log "ERROR · $($Job.ErrorText)"
    try {
        if (!$Run.Report) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $Run.Report = Join-Path $Options.destino "_errores_$($stamp)_$id.txt"
        }
        $file = [IO.File]::Open($Run.Report, 'Append', 'Write', 'Read')
        try {
            $bytes = $Utf8.GetBytes($Job.Url + [Environment]::NewLine)
            $file.Write($bytes, 0, $bytes.Length)
            $file.Flush($true)
        } finally { $file.Dispose() }
    } catch { Log 'No se pudo guardar un enlace en la lista de errores.' }
}

function Download-Batch($Jobs, $Options) {
    $run = [pscustomobject]@{Report = $null; Stopped = $false}
    $live = [Collections.Generic.List[object]]::new()
    $workers = if ($Options.listas) { 1 } else { $Options.trabajadores }
    foreach ($job in $Jobs) {
        $job.Status = 'COLA'; $job.Attempt = 0; $job.Percent = $null
        $job.Speed = 0; $job.Eta = $null; $job.ErrorText = ''; $job.ErrorHint = ''
    }
    $remaining = $Jobs.Count
    Log "Iniciado · $remaining enlaces · $workers canales activos"
    if (!$UseVT) { Write-Host "Iniciado · $remaining enlaces · $workers canales activos" }
    try {
        while ($remaining -gt 0) {
            $now = $Clock.Elapsed.TotalSeconds
            foreach ($job in $Jobs) {
                if ($live.Count -ge $workers) { break }
                if ($job.Status -notin @('COLA','ESPERA') -or ($job.Status -eq 'ESPERA' -and $job.Due -gt $now)) { continue }
                $job.Attempt++
                $job.Status = 'ABRIENDO'; $job.Percent = $null
                $job.Files = 0; $job.Stream = 0; $job.FileName = $null
                $job.Archived = $job.Existing = $job.Transferred = $job.AuthError = $job.AuthWarning = $false
                $job.ErrorText = ''; $job.ErrorHint = ''; $job.AuthDiagnostic = $null; $job.AuthWarningId = ''
                try { $live.Add((Start-Download $job $Options)) }
                catch {
                    $job.ErrorText = Clean-Text $_.Exception.Message
                    Register-Failure $job $Options $run
                    $remaining--
                }
            }
            foreach ($worker in $live.ToArray()) {
                $job = $worker.Job
                foreach ($stream in @('Out','Err')) {
                    for ($n = 0; $n -lt 256 -and $null -ne $worker.$stream -and $worker.$stream.IsCompleted; $n++) {
                        $text = ($worker.$stream.GetAwaiter()).GetResult()
                        if ($null -eq $text) { $worker.$stream = $null; break }
                        Read-Telemetry $job $text
                        $reader = if ($stream -eq 'Out') { $worker.Process.StandardOutput } else { $worker.Process.StandardError }
                        $worker.$stream = $reader.ReadLineAsync()
                    }
                }
                if ($null -ne $worker.Out -or $null -ne $worker.Err -or !$worker.Process.HasExited) { continue }
                $code = $worker.Process.ExitCode
                $worker.Process.Dispose()
                $null = $live.Remove($worker)
                if ($worker.Copy) { [IO.File]::Delete($worker.Copy) }
                $job.Speed = 0; $job.Eta = $null
                if ($code -eq 0 -and ($job.Files -or $job.Archived -or $job.Existing)) {
                    $job.Status = if (!$job.Files -or ($job.Existing -and !$job.Transferred)) { 'OMITIDO' } else { 'LISTO' }
                    $job.Percent = 100
                    $title = if ($job.Title) { $job.Title } else { $job.Url }
                    Log "$($job.Status) · $title"
                    if ($job.AuthWarning -and $Browsers.ContainsKey($Options.cookies)) {
                        Log 'El navegador no permitió leer algunas cookies.'
                    }
                    try { [IO.Directory]::Delete($worker.Partial) } catch {}
                    $remaining--
                } else {
                    if (!$job.ErrorText) { $job.ErrorText = "yt-dlp terminó sin archivo (código $code)." }
                    if ($job.Attempt -lt $Attempts -and !$job.AuthError) {
                        $delay = $Spec.retrySeconds[$job.Attempt - 1]
                        $job.Status = 'ESPERA'; $job.Percent = $null; $job.Due = $Clock.Elapsed.TotalSeconds + $delay
                        Log "Reintento en $($delay)s · $($job.ErrorText)"
                    } else {
                        Register-Failure $job $Options $run
                        $remaining--
                    }
                }
            }
            if ($CanReadKey) {
                try {
                    if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'X') {
                        $run.Stopped = $true
                        break
                    }
                } catch {}
            }
            if ($UseVT) { Show-Panel $Jobs $Options $true }
            elseif ($ConsoleOutput) {
                Write-Progress -Id 1 -Activity 'DownloadUltron · lote' -Status (Summary $Jobs) -PercentComplete (100 * ($Jobs.Count - $remaining) / $Jobs.Count)
            }
            if ($remaining -gt 0) { Start-Sleep -Milliseconds 180 }
        }
    } finally {
        foreach ($worker in $live) {
            Stop-Tool $worker.Process
            if ($worker.Copy) { [IO.File]::Delete($worker.Copy) }
        }
        foreach ($job in $Jobs) {
            if ($job.Status -notin $Final) { $job.Status = 'DETENIDO'; $job.Speed = 0; $job.Eta = $null }
        }
        if (!$UseVT -and $ConsoleOutput) { Write-Progress -Id 1 -Activity 'DownloadUltron · lote' -Completed }
    }
    if ($run.Report) { Log "Errores guardados · $($run.Report)" }
    Log (Summary $Jobs)
    return $run
}

function Run-Batch($Jobs, $Options) {
    $Options.destino = Get-Path $Options.destino
    Check-Cookies $Options
    $null = [IO.Directory]::CreateDirectory($Options.destino)
    $lock = Lock-Batch
    try {
        Prepare-Tools
        if (!$SinActualizar) { $null = Update-Motor $false }
        try { Save-Settings $Options } catch { Log 'No se pudieron guardar los ajustes.' }
        return (Download-Batch $Jobs $Options)
    } finally { $lock.Dispose() }
}

function Pick-Path([bool]$Directory, [string]$Start) {
    $current = if ([IO.Directory]::Exists($Start)) { $Start } else { $HOME }
    $page = 0
    while ($true) {
        Write-Host (Color ("EXPLORADOR  /  " + (Clean-Text $current)) 91)
        try {
            $entries = @(Get-ChildItem -LiteralPath $current | Where-Object { $_.PSIsContainer -or (!$Directory -and $_.Extension -eq '.txt') } |
                Sort-Object @{Expression = { !$_.PSIsContainer }}, Name)
        } catch {
            $entries = @()
            Write-Host (Clean-Text $_.Exception.Message)
        }
        $page = [Math]::Min($page, [Math]::Max(0, [Math]::Floor(($entries.Count - 1) / 12)))
        $shown = @($entries | Select-Object -Skip ($page * 12) -First 12)
        for ($i = 0; $i -lt $shown.Count; $i++) {
            $kind = if ($shown[$i].PSIsContainer) { '/' } else { '·' }
            Write-Host (' {0,2}  {1}  {2}' -f ($i + 1), $kind, (Clean-Text $shown[$i].Name))
        }
        if ($entries.Count -gt 12) { Write-Host "Página $($page + 1)/$([Math]::Ceiling($entries.Count / 12))" }
        if ($Directory) { Write-Host '0 Usar esta carpeta' }
        $key = (Read-Host 'Número / .. subir / N-P página / G ruta / X volver').Trim()
        if (!$key -or $key -eq 'x') { return $null }
        if ($key -eq '0' -and $Directory) { return $current }
        switch ($key) {
            '..' { $parent = [IO.Directory]::GetParent($current); if ($parent) { $current = $parent.FullName }; $page = 0 }
            'n' { $page++ }
            'p' { $page = [Math]::Max(0, $page - 1) }
            'g' {
                $raw = Read-Host 'Ruta completa'
                if ($raw) {
                    $path = Get-Path $raw
                    if ([IO.File]::Exists($path)) {
                        if (!$Directory) { return $path }
                        Write-Host 'Esa ruta ya corresponde a un archivo. Elige una carpeta.'
                        continue
                    }
                    if ($Directory) { return $path }
                    if ([IO.Directory]::Exists($path)) { $current = $path; $page = 0 }
                    else { Write-Host 'No se encontró el archivo.' }
                }
            }
            default {
                $number = 0
                if ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le $shown.Count) {
                    $item = $shown[$number - 1]
                    if (!$item.PSIsContainer) { return $item.FullName }
                    $current = $item.FullName; $page = 0
                }
            }
        }
    }
}

function Select-Path([bool]$Directory, [string]$Label, [string]$Start) {
    $raw = Read-Host "  $Label [B explorar, Enter volver]"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw.Trim() -eq 'b') { return (Pick-Path $Directory $Start) }
    $path = Get-Path $raw
    if ($Directory -and [IO.File]::Exists($path)) {
        throw 'Esa ruta ya corresponde a un archivo. Elige una carpeta.'
    }
    if (!$Directory -and ![IO.File]::Exists($path)) {
        throw 'No se encontró el archivo en la ruta indicada.'
    }
    return $path
}

function Select-Cookies($Options) {
    $choices = @(foreach ($browser in $Spec.cookieBrowsers) {
        $profiles = @(foreach ($location in $browser.roots) {
            $parent = [Environment]::GetEnvironmentVariable($location.env)
            if (!$parent) { continue }
            $path = Join-Path $parent $location.path
            if ([IO.Directory]::Exists($path)) {
                Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match $browser.pattern } | ForEach-Object Name
            }
        })
        if ($profiles.Count -or $browser.id -eq 'brave') {
            [pscustomobject]@{Source = $browser.id; Profile = ''; Label = "$($browser.name) · perfil automático"}
            foreach ($name in ($profiles | Sort-Object -Unique)) {
                [pscustomobject]@{Source = $browser.id; Profile = $name; Label = "$($browser.name) / $name"}
            }
        }
    })
    Write-Host '0  Sin cookies'
    for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host "$($i + 1)  $($choices[$i].Label)" }
    Write-Host 'A  Archivo Netscape     M  Elegir navegador y perfil manual'
    $value = Read-Host 'Cookies (Enter vuelve)'
    switch ($value) {
        '0' { $Options.cookies = 'ninguna'; $Options.perfil = ''; $Options.archivo = '' }
        'a' {
            $path = Select-Path $false 'Ruta del archivo de cookies' (Get-Location).Path
            if ($path) { $Options.cookies = 'archivo'; $Options.perfil = ''; $Options.archivo = $path }
        }
        'm' {
            $source = (Read-Host 'Navegador [brave/chrome/edge/firefox]').Trim().ToLowerInvariant()
            if ($Browsers.ContainsKey($source)) {
                Write-Host 'Usa el nombre de la carpeta del perfil. Deja vacío para detección automática.'
                $Options.cookies = $source; $Options.perfil = (Read-Host 'Perfil').Trim(); $Options.archivo = ''
            }
        }
        default {
            $number = 0
            if ([int]::TryParse($value, [ref]$number) -and $number -ge 1 -and $number -le $choices.Count) {
                $choice = $choices[$number - 1]
                $Options.cookies = $choice.Source; $Options.perfil = $choice.Profile; $Options.archivo = ''
            }
        }
    }
}

function Invoke-Menu($Jobs, $Options) {
    $page = 0
    $report = $null
    if ($UseVT) { Write-Terminal "$Escape[2J" }
    while ($true) {
        Show-Panel $Jobs $Options $false $page
        try {
            if ($UseVT) { Write-Terminal ([Environment]::NewLine) }
            $raw = Read-Host '  Ultron'
            if ($null -eq $raw) { return 0 }
            $key = $raw.Trim()
            switch -Regex ($key) {
                '^(q|salir)$' { return 0 }
                '^1$' {
                    $path = Select-Path $false 'Ruta del TXT' (Get-Location).Path
                    if ($path) { Add-Links $Jobs (Read-List $path) }
                }
                '^2$' {
                    Write-Host 'Pega tus enlaces separados por saltos de línea o comas. Pulsa Enter en una línea vacía para añadirlos.'
                    $lines = [Collections.Generic.List[string]]::new()
                    while ($line = Read-Host) { $lines.Add($line) }
                    Add-Links $Jobs ($lines -join [Environment]::NewLine)
                }
                '^3$' {
                    $path = Select-Path $true 'Ruta de destino' $Options.destino
                    if ($path) { $Options.destino = $path }
                }
                '^4$' {
                    for ($i = 0; $i -lt $Spec.formats.Count; $i++) { Write-Host " $($i + 1)  $($Spec.formats[$i].name)" }
                    $value = Read-Host 'Formato (Enter vuelve)'
                    $number = 0
                    if ([int]::TryParse($value, [ref]$number) -and $number -ge 1 -and $number -le $Spec.formats.Count) {
                        $Options.formato = $Spec.formats[$number - 1].id
                    }
                }
                '^5$' {
                    $value = Read-Host 'Canales simultáneos (1–8)'
                    $number = 0
                    if ([int]::TryParse($value, [ref]$number) -and $number -in (1..8)) { $Options.trabajadores = $number }
                    elseif ($value) { Log 'Elige un valor entre 1 y 8.' }
                }
                '^6$' { Select-Cookies $Options }
                '^(7|r)$' {
                    $wanted = if ($key -eq '7') { @('COLA','DETENIDO') } else { @('ERROR') }
                    $batch = @($Jobs | Where-Object { $_.Status -in $wanted })
                    if ($batch.Count) {
                        $run = Run-Batch $batch $Options
                        if ($run.Report) { $report = $run.Report }
                    } else { Log 'No hay enlaces para ejecutar con esta opción.' }
                }
                '^e$' {
                    foreach ($job in $Jobs) {
                        if ($job.Status -eq 'ERROR') {
                            $title = if ($job.Title) { $job.Title } else { $job.Url }
                            Write-Host (Clean-Text $title)
                            Write-Host "  $($job.ErrorText)"
                            if ($job.ErrorHint) { Write-Host "  $($job.ErrorHint)" }
                        }
                    }
                    if ($report) { Write-Host "Lista guardada en $report" }
                    $null = Read-Host 'Enter para volver'
                }
                '^(\?|h|ayuda)$' {
                    Write-Host 'Más opciones'
                    Write-Host '  [5] Canales   [L] Listas completas   [O] Abrir destino'
                    Write-Host '  [E] Detalle de errores   [R] Reintentar fallidos   [N/P] Cambiar página'
                    $null = Read-Host 'Enter para volver'
                }
                '^l$' {
                    $Options.listas = !$Options.listas
                    if ($Options.listas) { Log 'Listas completas · un canal para evitar descargas duplicadas.' }
                    else { Log 'Las listas se limitan a su primer video.' }
                }
                '^[np]$' {
                    $delta = if ($key -eq 'n') { 1 } else { -1 }
                    $page = [Math]::Min([Math]::Max(0, $page + $delta), [Math]::Max(0, [Math]::Floor(($Jobs.Count - 1) / (Visible-Rows))))
                }
                '^o$' {
                    $path = Get-Path $Options.destino
                    $null = [IO.Directory]::CreateDirectory($path)
                    Invoke-Item -LiteralPath $path
                }
                '^https?://' { Add-Links $Jobs $key }
                default { if ($key) { Log 'Elige una opción del menú o pega un enlace.' } }
            }
        } catch {
            if ([Console]::IsInputRedirected -and $_.Exception -is [System.Management.Automation.Host.HostException]) { return 0 }
            Log $_.Exception.Message
        }
    }
}

function Invoke-Ultron {
    if ($Diagnostico) {
        Write-Host "DownloadUltron $($Spec.version) · Shell"
        $failed = $false
        foreach ($name in $ToolNames) {
            $tool = Join-Path $Tools "$name.exe"
            if (![IO.File]::Exists($tool)) { Write-Host "$name · ausente"; $failed = $true; continue }
            $flag = if ($name.StartsWith('ff')) { '-version' } else { '--version' }
            $result = Invoke-Tool $tool @($flag) 20000
            if ($result.Code) { $failed = $true; Write-Host "$name · error"; continue }
            Write-Host "$name · $(($result.Out -split '\r?\n')[0])"
        }
        return [int]$failed
    }
    if ($Actualizar) {
        $lock = Lock-Batch
        try {
            Prepare-Tools
            return [int](!(Update-Motor $true))
        } finally { $lock.Dispose() }
    }
    if (($Brave -or $PerfilBrave) -and ($Cookies -or $Navegador) -or $Navegador -and $Cookies -or $Perfil -and !$Navegador) {
        throw 'Elige una sola fuente de cookies. Usa -Perfil con -Navegador.'
    }
    $options = Read-Settings
    if ($Destino) { $options.destino = $Destino }
    if ($Formato) {
        if (!$Formats.ContainsKey($Formato)) { throw "Formatos: $($Spec.formats.id -join ', ')." }
        $options.formato = $Formats[$Formato].id
    }
    if ($Canales) { $options.trabajadores = $Canales }
    if ($Listas) { $options.listas = $true }
    if ($Brave -or $PerfilBrave) { $options.cookies = 'brave'; $options.perfil = $PerfilBrave }
    if ($Navegador) { $options.cookies = $Navegador.ToLowerInvariant(); $options.perfil = $Perfil }
    if ($Cookies) { $options.cookies = 'archivo'; $options.archivo = Get-Path $Cookies }
    $jobs = [Collections.Generic.List[object]]::new()
    if ($Entrada) {
        if ($Entrada -match '^https?://') { Add-Links $jobs $Entrada }
        else { Add-Links $jobs (Read-List $Entrada) }
    }
    if ($Lote) { Add-Links $jobs (Read-List $Lote) }
    if ($Urls) { Add-Links $jobs $Urls }
    if (!$Ejecutar) { return (Invoke-Menu $jobs $options) }
    if (!$jobs.Count) { throw 'No hay enlaces válidos. Usa una URL, -Urls o -Lote.' }
    $run = Run-Batch ($jobs.ToArray()) $options
    Write-Host ''
    Write-Host (Summary $jobs)
    if ($run.Report) { Write-Host "Errores: $($run.Report)" }
    foreach ($job in $jobs) {
        if ($job.Status -eq 'ERROR') {
            Write-Host $job.ErrorText
            if ($job.ErrorHint) { Write-Host $job.ErrorHint }
        }
    }
    if ($run.Stopped) { return 130 }
    return [int](@($jobs | Where-Object Status -eq 'ERROR').Count -gt 0)
}

$originalEncoding = $null
try {
    Enable-Terminal
    if (!$ConsoleOutput) {
        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $Utf8
    }
    exit (Invoke-Ultron)
} catch {
    Write-Host (Clean-Text $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($UseVT) { [DownloadUltronTerminal]::Restore() }
    if ($null -ne $originalEncoding) { [Console]::OutputEncoding = $originalEncoding }
}
