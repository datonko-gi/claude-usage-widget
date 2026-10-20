# Claude Usage Widget. Two rows: 5-hour session (big) + weekly all-models (small).
# Traffic-light bars, percent, and time-to-reset. Data: GET https://api.anthropic.com/api/oauth/usage
# (an UNDOCUMENTED endpoint that may change or disappear) with the Claude Code OAuth bearer token
# from ~/.claude/.credentials.json (read-only; token freshness delegated to the CLI).
# Not affiliated with or endorsed by Anthropic.
# States: ok | auth (401, CLI can still refresh -> it is poked once per 15 min) | login (no
# tokens or refresh token expired -> the CLI wiped them; only `claude auth login` helps, the
# widget says so and a click opens that login) | rate (429) | net.
# Test mode: CLAUDEUSAGE_TESTMODE=1 loads functions only (no mutex, no UI); CLAUDEUSAGE_LOGDIR
# redirects the log and the widget's data files.

# ===== Observability =====
$script:LogDir = if ($env:CLAUDEUSAGE_LOGDIR) { $env:CLAUDEUSAGE_LOGDIR } else { Join-Path $env:APPDATA 'ClaudeUsage' }
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogFile = Join-Path $script:LogDir 'widget.log'
function Write-WidgetLog { param([string]$m)
    try {
        "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Add-Content -Path $script:LogFile -Encoding UTF8
        $fi = Get-Item $script:LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 200000) {
            $tail = Get-Content $script:LogFile -Tail 400 -ErrorAction SilentlyContinue
            Set-Content -Path $script:LogFile -Value $tail -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {}
}
trap { Write-WidgetLog ("FATAL: " + ($_ | Out-String).Trim()); exit 1 }
Write-WidgetLog "startup: begin (pid $PID)"

# Bulletproof single instance (a duplicate = double polling of a rate-limited endpoint = 429
# storm, the exact bug that froze the widget on stale/wrong data). TWO guards, because each
# alone has a hole:
#  (a) process check - catches a still-alive OLDER instance whose named mutex the PowerShell GC
#      quietly released (the finalizer frees an unreferenced Mutex mid-ShowDialog). This is what
#      let duplicates come back after the mutex-only fix.
#  (b) named mutex - catches the simultaneous-login race where both instances see zero others.
function Is-WidgetCmd([string]$c) {
    # Only a launcher-style command line counts: -File <path>\claude_usage.ps1. A -Command shell
    # that merely mentions the name (diagnostics, tests, test_claude_usage.ps1) must not count.
    if (-not $c) { return $false }
    return [bool]($c -match '-File\s+"?[^"]*\\claude_usage\.ps1')
}
if (-not $env:CLAUDEUSAGE_TESTMODE) {
try {
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and (Is-WidgetCmd $_.CommandLine) })
    if ($others.Count -gt 0) {
        Write-WidgetLog "another instance already running (pids $($others.ProcessId -join ',')) -> exiting (pid $PID)"
        exit 0
    }
} catch {}
$script:SingleMutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeUsageWidgetSingleton')
# PIN the mutex with a strong GC handle. A script-scope reference was NOT enough: across a
# multi-hour ShowDialog the GC finalizer collected the Mutex and RELEASED it, so a duplicate
# launched hours later re-acquired it (the recurring-duplicate bug). GCHandle.Alloc keeps the
# object alive for the whole process, so the finalizer never runs.
$script:MutexPin = [System.Runtime.InteropServices.GCHandle]::Alloc($script:SingleMutex)
if (-not $script:SingleMutex.WaitOne(0)) {
    Write-WidgetLog "mutex held by another instance -> exiting (pid $PID)"
    exit 0
}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch {}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Native {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int v);
    [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int cx, int cy);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const uint SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;
    public const uint LWA_ALPHA = 0x2;
}
"@
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class IdleHelper {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double IdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount - lii.dwTime) / 1000.0;
    }
}
"@

[Native]::SetProcessDPIAware() | Out-Null

# ===== Geometry =====
# All drawing code works in "design" pixels: a 168x60 card at 100% display scaling. The form is the design
# size times the Windows display scale (DPI/96; this process is DPI-aware), and the Paint handler applies the
# same scale to the Graphics, so the layout is identical at 100%, 125%, 150%, 175% and 200%.
$script:DesignW = 168
$script:DesignH = 60
$script:Scale = 1.0
try {
    $gd = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = [Math]::Max(1.0, [Math]::Round($gd.DpiX / 96.0, 2))
    $gd.Dispose()
} catch {}
$script:FormW = [int][Math]::Round($script:DesignW * $script:Scale)   # physical px
$script:FormH = [int][Math]::Round($script:DesignH * $script:Scale)
$script:PadL  = 9   # design px
$script:PadR  = 8

# ===== Colors (light card, traffic-light bars) =====
function C($r,$g,$b) { [System.Drawing.Color]::FromArgb($r,$g,$b) }
$script:ColBg    = C 248 248 248
$script:ColTrack = C 224 224 229
$script:ColBlue  = C 52 130 215
$script:ColAmber = C 224 162 54
$script:ColRed   = C 206 68 54
$script:ColRedD  = C 176 51 40
$script:ColLabel = C 70 70 78
$script:ColMuted = C 150 150 158

function Bar-Color([double]$pct) {
    if ($pct -ge 85) { return $script:ColRed }
    if ($pct -ge 60) { return $script:ColAmber }
    return $script:ColBlue
}
function Text-Color([double]$pct) {
    if ($pct -ge 85) { return $script:ColRedD }
    if ($pct -ge 60) { return (C 150 108 30) }
    return (C 46 109 168)
}

# ===== Data files =====
$script:DataFile  = Join-Path $script:LogDir 'data.json'
$script:CacheFile = Join-Path $script:LogDir 'usage_cache.json'
$script:CredFile  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:ApiUrl    = 'https://api.anthropic.com/api/oauth/usage'

function Load-Pos {
    if (-not (Test-Path $script:DataFile)) { return @{ posX = $null; posY = $null } }
    try {
        $o = Get-Content $script:DataFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $px = if ($o.PSObject.Properties.Name -contains 'posX') { $o.posX } else { $null }
        $py = if ($o.PSObject.Properties.Name -contains 'posY') { $o.posY } else { $null }
        return @{ posX = $px; posY = $py }
    } catch { return @{ posX = $null; posY = $null } }
}
function Save-Pos {
    try { @{ posX = $script:Pos.posX; posY = $script:Pos.posY } | ConvertTo-Json -Compress | Set-Content $script:DataFile -Encoding UTF8 } catch {}
}
$script:Pos = Load-Pos

# Shared state written by the background fetch runspace, read by the UI timer.
$script:Usage = [hashtable]::Synchronized(@{
    ok = $false; err = $null; errMsg = $null; ts = $null
    sPct = $null; sReset = $null
    wPct = $null; wReset = $null
})

# Seed from cache so the first paint is not empty.
if (Test-Path $script:CacheFile) {
    try {
        $c = Get-Content $script:CacheFile -Raw | ConvertFrom-Json
        $script:Usage.ok = $true
        $script:Usage.sPct = [double]$c.sPct; $script:Usage.wPct = [double]$c.wPct
        if ($c.sReset) { $script:Usage.sReset = ([DateTime]::Parse($c.sReset)).ToUniversalTime() }
        if ($c.wReset) { $script:Usage.wReset = ([DateTime]::Parse($c.wReset)).ToUniversalTime() }
        if ($c.ts) { $script:Usage.ts = ([DateTime]::Parse($c.ts)).ToUniversalTime() }
    } catch {}
}

# ===== Background fetch (runspace, so the UI never blocks on the network) =====
$script:FetchBusy = $false
$script:FetchPS   = $null
$script:FetchHandle = $null
$script:FetchStart = [DateTime]::MinValue

$script:FetchScript = {
    param($state, $credFile, $cacheFile, $apiUrl)
    if (-not $apiUrl) { $apiUrl = 'https://api.anthropic.com/api/oauth/usage' }
    $state.errMsg = $null
    function ConvertTo-ResetUtc($v) {
        # null or empty reset time -> $null: the bar is still shown, just without a countdown.
        # A value that is present but not a date still throws (reported as an error), so an API format change stays visible.
        if ($null -eq $v -or "$v".Trim() -eq '') { return $null }
        if ($v -is [DateTime]) { return $v.ToUniversalTime() }
        return [DateTime]::Parse([string]$v).ToUniversalTime()
    }
    # --- credentials: decide up front whether the CLI could still refresh on its own ---
    # refreshTokenExpiresAt is an ABSOLUTE lifetime (~30 days from login). Once it passes the
    # CLI wipes both tokens, so an empty/expired refresh token
    # means "logged out": poking claude.exe cannot help, only `claude auth login` can.
    $tok = ''; $canRefresh = $false
    try {
        $raw = Get-Content $credFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $o = $raw.claudeAiOauth
        if ($null -eq $o) { throw 'claudeAiOauth block missing' }
        $tok = [string]$o.accessToken
        $rt  = [string]$o.refreshToken
        $canRefresh = ($rt.Length -gt 0)
        if ($canRefresh -and ($o.PSObject.Properties.Name -contains 'refreshTokenExpiresAt') -and $o.refreshTokenExpiresAt) {
            $rtExpMs = [double]$o.refreshTokenExpiresAt
            if ($rtExpMs -gt 0 -and $rtExpMs -lt [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) { $canRefresh = $false }
        }
    } catch {
        $state.err = 'login'; $state.ok = $false
        $state.errMsg = "credentials unreadable: $($_.Exception.Message)"
        return
    }
    if ($tok.Length -eq 0) {
        $state.err = if ($canRefresh) { 'auth' } else { 'login' }
        $state.ok = $false
        $state.errMsg = if ($canRefresh) { 'no access token (refresh token present)' } else { 'no tokens in credentials file (CLI logged out)' }
        return
    }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $headers = @{
            'Authorization'  = "Bearer $tok"
            'anthropic-beta' = 'oauth-2025-04-20'
            'Content-Type'   = 'application/json'
        }
        $r = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -TimeoutSec 8
        # Read the SAME source the claude.ai usage page renders: the limits[] array (kind=session
        # -> "Current session", kind=weekly_all -> "All models"). The legacy top-level
        # five_hour/seven_day.utilization diverged from the page under the Max (20x) plan,
        # so limits[] is authoritative; fall back to the
        # legacy fields only if limits[] is absent.
        $sPct = $null; $wPct = $null; $sReset = $null; $wReset = $null
        if ($r.PSObject.Properties.Name -contains 'limits' -and $r.limits) {
            foreach ($L in $r.limits) {
                if ($L.kind -eq 'session')        { $sPct = [double]$L.percent; $sReset = ConvertTo-ResetUtc $L.resets_at }
                elseif ($L.kind -eq 'weekly_all') { $wPct = [double]$L.percent; $wReset = ConvertTo-ResetUtc $L.resets_at }
            }
        }
        if ($null -eq $sPct -and $r.five_hour) { $sPct = [double]$r.five_hour.utilization; $sReset = ConvertTo-ResetUtc $r.five_hour.resets_at }
        if ($null -eq $wPct -and $r.seven_day) { $wPct = [double]$r.seven_day.utilization; $wReset = ConvertTo-ResetUtc $r.seven_day.resets_at }
        if ($null -eq $sPct -and $null -eq $wPct) { throw 'response had neither limits[] nor five_hour/seven_day' }
        $now = [DateTime]::UtcNow
        $state.sPct = $sPct; $state.wPct = $wPct
        $state.sReset = $sReset; $state.wReset = $wReset
        $state.err = $null; $state.ok = $true; $state.ts = $now
        try {
            @{ sPct = $sPct; wPct = $wPct; sReset = $(if ($sReset) { $sReset.ToString('o') } else { $null }); wReset = $(if ($wReset) { $wReset.ToString('o') } else { $null }); ts = $now.ToString('o') } |
                ConvertTo-Json -Compress | Set-Content $cacheFile -Encoding UTF8
        } catch {}
    } catch {
        $msg = $_.Exception.Message
        $state.errMsg = $msg
        if ($msg -match '429' -or $msg -match 'Too Many') { $state.err = 'rate' }
        elseif ($msg -match '401' -or $msg -match 'Unauthorized') { $state.err = if ($canRefresh) { 'auth' } else { 'login' } }
        else { $state.err = 'net' }
        # keep last-good values (do not blank the widget on a transient failure)
    }
}

function Start-Fetch {
    if ($script:FetchBusy) { return }
    $script:FetchBusy = $true
    $script:FetchStart = [DateTime]::UtcNow
    try {
        $script:FetchPS = [PowerShell]::Create()
        [void]$script:FetchPS.AddScript($script:FetchScript).AddArgument($script:Usage).AddArgument($script:CredFile).AddArgument($script:CacheFile).AddArgument($script:ApiUrl)
        $script:FetchHandle = $script:FetchPS.BeginInvoke()
    } catch {
        $script:FetchBusy = $false
        Write-WidgetLog "Start-Fetch error: $($_.Exception.Message)"
    }
}
# Manual refresh (click / menu) with a 60s floor so it can never be used to hammer the endpoint.
function Request-Manual-Fetch {
    $since = ([DateTime]::UtcNow - $script:LastFetch).TotalSeconds
    if ($since -lt 60) { Write-WidgetLog ("manual refresh ignored (last fetch {0:n0}s ago, 60s floor)" -f $since); return }
    $script:LastFetch = [DateTime]::UtcNow
    Start-Fetch
}
function Reap-Fetch {
    if (-not $script:FetchBusy) { return $false }
    if ($script:FetchHandle -and $script:FetchHandle.IsCompleted) {
        try { $script:FetchPS.EndInvoke($script:FetchHandle) } catch {}
        try { $script:FetchPS.Dispose() } catch {}
        $script:FetchPS = $null; $script:FetchHandle = $null
        $script:FetchBusy = $false
        return $true
    }
    # Watchdog: a hung fetch must never wedge FetchBusy=true forever (that was the
    # bug that froze the widget on pre-reset data). Force-tear-down after 25s so the
    # next tick can retry.
    if (($script:FetchStart -ne [DateTime]::MinValue) -and (([DateTime]::UtcNow - $script:FetchStart).TotalSeconds -gt 25)) {
        try { if ($script:FetchPS) { $script:FetchPS.Stop() } } catch {}
        try { if ($script:FetchPS) { $script:FetchPS.Dispose() } } catch {}
        $script:FetchPS = $null; $script:FetchHandle = $null
        $script:FetchBusy = $false
        $script:Usage.err = 'net'
        Write-WidgetLog "fetch watchdog: force-reset a stuck fetch (>25s)"
    }
    return $false
}

# ===== Login launcher =====
# The CLI's OAuth session expires roughly monthly (refreshTokenExpiresAt is absolute); when it
# does, the CLI wipes its tokens and `claude -p` says "OAuth session expired and could not be
# refreshed". Only a browser re-login fixes that, so the widget offers it on click.
$script:ClaudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $script:ClaudeExe)) {
    # Other install layouts (npm global, custom prefix): use whatever `claude` resolves to on PATH.
    try {
        $gc = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ($gc -and $gc.Source) { $script:ClaudeExe = $gc.Source }
    } catch {}
}
$script:WtExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
function Get-LoginCommand {
    # cmd /k keeps the console open so the outcome of `claude auth login` stays readable.
    # Opened THROUGH wt.exe when present: a bare cmd.exe can be delegated to a Windows Terminal COM
    # host with no child process, and anything that closes such orphan windows would take the OAuth
    # localhost listener down with it.
    $cmdArgs = '/k title Claude CLI login && "' + $script:ClaudeExe + '" auth login'
    if (Test-Path $script:WtExe) { return @{ File = $script:WtExe; Args = ('-w new cmd ' + $cmdArgs) } }
    return @{ File = 'cmd.exe'; Args = $cmdArgs }
}
$script:LastLoginLaunch = [DateTime]::UtcNow.AddYears(-1)
function Start-Login {
    $since = ([DateTime]::UtcNow - $script:LastLoginLaunch).TotalSeconds
    if ($since -lt 30) { return }   # one console per click, not one per double-click
    $script:LastLoginLaunch = [DateTime]::UtcNow
    try {
        if (-not (Test-Path $script:ClaudeExe)) { Write-WidgetLog "login: claude.exe not found at $($script:ClaudeExe) or on PATH"; return }
        $c = Get-LoginCommand
        Start-Process -FilePath $c.File -ArgumentList $c.Args -WindowStyle Normal
        Write-WidgetLog "login: opened console for 'claude auth login'"
    } catch { Write-WidgetLog "login: launch failed: $($_.Exception.Message)" }
}
function Get-CredMtime {
    try { return (Get-Item $script:CredFile -ErrorAction Stop).LastWriteTimeUtc } catch { return [DateTime]::MinValue }
}
$script:CredMtime = Get-CredMtime

if ($env:CLAUDEUSAGE_TESTMODE) { Write-WidgetLog "test mode: functions loaded, no UI (pid $PID)"; return }

# ===== Time-to-reset formatting =====
function Fmt-Short([DateTime]$resetUtc) {
    # session: within a few hours -> "H:MM", under an hour -> "MMm"
    $span = $resetUtc.ToUniversalTime() - [DateTime]::UtcNow
    if ($span.TotalSeconds -le 0) { return [char]0x2026 }  # reset passed: a refetch is in flight
    if ($span.TotalHours -ge 1) { return ("{0}:{1:d2}" -f [int][Math]::Floor($span.TotalHours), $span.Minutes) }
    return ("{0}m" -f [int]$span.TotalMinutes)
}
function Fmt-Long([DateTime]$resetUtc) {
    # weekly: "Nd Nh", under a day -> "Nh", under an hour -> "Nm"
    $span = $resetUtc.ToUniversalTime() - [DateTime]::UtcNow
    if ($span.TotalSeconds -le 0) { return [char]0x2026 }
    if ($span.TotalDays -ge 1) { return ("{0}d {1}h" -f [int][Math]::Floor($span.TotalDays), $span.Hours) }
    if ($span.TotalHours -ge 1) { return ("{0}h" -f [int][Math]::Floor($span.TotalHours)) }
    return ("{0}m" -f [int]$span.TotalMinutes)
}

# ===== Form =====
$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size($script:FormW, $script:FormH)
$form.FormBorderStyle = "None"
$form.ShowInTaskbar = $false
$form.StartPosition = "Manual"
$form.BackColor = $script:ColBg
$form.TopMost = $false
$form.Text = "ClaudeUsage"

# Default position: bottom-right corner of the primary screen, above the taskbar.
function Default-Location {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $wa.Right - $script:FormW - [int](24 * $script:Scale)
    $y = $wa.Bottom - $script:FormH - [int](24 * $script:Scale)
    return New-Object System.Drawing.Point([int]$x, [int]$y)
}
function Test-OnScreen($x, $y) {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $wa = $s.WorkingArea
        if (($x + $script:FormW) -gt ($wa.Left + 40) -and $x -lt ($wa.Right - 40) -and
            ($y + $script:FormH) -gt ($wa.Top + 20) -and $y -lt ($wa.Bottom - 20)) { return $true }
    }
    return $false
}
if ($null -ne $script:Pos.posX -and $null -ne $script:Pos.posY -and (Test-OnScreen ([int]$script:Pos.posX) ([int]$script:Pos.posY))) {
    $form.Location = New-Object System.Drawing.Point([int]$script:Pos.posX, [int]$script:Pos.posY)
} else {
    $form.Location = Default-Location
}

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.BackColor = $script:ColBg
$form.Controls.Add($panel)
$prop = $panel.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
$prop.SetValue($panel, $true, $null)

# ===== Drawing =====
function Draw-Row {
    param($g, [int]$y, [int]$barH, $label, $fLabel, $fVal, $pct, $reset, [bool]$long, $note, $noteCol)
    # Fixed column geometry (same for both rows so the bars line up):
    #  label 8..32 | bar 34..70 | percent 72..106 | countdown 108..160
    $barX = 34; $barRight = 70
    $pctX = 72;  $pctRight = 106
    $cdX  = 108; $cdRight  = $script:DesignW - $script:PadR
    $barW = $barRight - $barX

    $vc = New-Object System.Drawing.StringFormat
    $vc.LineAlignment = [System.Drawing.StringAlignment]::Center
    $vc.Alignment = [System.Drawing.StringAlignment]::Near
    $vc.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $vc.Trimming = [System.Drawing.StringTrimming]::None
    $lblBrush = New-Object System.Drawing.SolidBrush($script:ColLabel)
    $lblRect = New-Object System.Drawing.RectangleF ([float]$script:PadL, [float]$y, [float]24, [float]$barH)
    $g.DrawString($label, $fLabel, $lblBrush, $lblRect, $vc)
    $lblBrush.Dispose()

    $rad = $barH / 2.0
    $trackBrush = New-Object System.Drawing.SolidBrush($script:ColTrack)
    Fill-Round $g $trackBrush $barX $y $barW $barH $rad
    $trackBrush.Dispose()

    $fmtR = New-Object System.Drawing.StringFormat
    $fmtR.Alignment = [System.Drawing.StringAlignment]::Far
    $fmtR.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmtR.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap -bor [System.Drawing.StringFormatFlags]::NoClip
    $fmtR.Trimming = [System.Drawing.StringTrimming]::None

    if ($null -eq $pct) {
        $txt = if ($note) { $note } else { "no data" }
        $col = if ($noteCol) { $noteCol } else { $script:ColMuted }
        $q = New-Object System.Drawing.SolidBrush($col)
        $rr = New-Object System.Drawing.RectangleF ([float]$pctX, [float]$y, [float]($cdRight - $pctX), [float]$barH)
        $g.DrawString($txt, $fLabel, $q, $rr, $fmtR); $q.Dispose()
        $fmtR.Dispose(); $vc.Dispose(); return
    }

    $fillW = [int]($barW * [Math]::Max(0.0, [Math]::Min(100.0, [double]$pct)) / 100.0)
    if ($fillW -gt 2) {
        $fb = New-Object System.Drawing.SolidBrush((Bar-Color $pct))
        Fill-Round $g $fb $barX $y $fillW $barH $rad
        $fb.Dispose()
    }

    $cd = ""
    if ($reset -is [DateTime]) { $cd = if ($long) { Fmt-Long $reset } else { Fmt-Short $reset } }
    $exhausted = ($pct -ge 100) -and ($cd -ne "")   # no reset time known -> keep the percent, no countdown
    if ($exhausted) {
        # percent slot merges into the countdown: one big red "reset in N"
        $rb = New-Object System.Drawing.SolidBrush($script:ColRedD)
        $rr = New-Object System.Drawing.RectangleF ([float]$pctX, [float]$y, [float]($cdRight - $pctX), [float]$barH)
        $g.DrawString(("$([char]0x21BB)$cd"), $fVal, $rb, $rr, $fmtR); $rb.Dispose()
    } else {
        $pb = New-Object System.Drawing.SolidBrush((Text-Color $pct))
        $pRect = New-Object System.Drawing.RectangleF ([float]$pctX, [float]$y, [float]($pctRight - $pctX), [float]$barH)
        $g.DrawString(("{0}%" -f [int][Math]::Round($pct)), $fVal, $pb, $pRect, $fmtR); $pb.Dispose()
        if ($cd -ne "") {
            $cb = New-Object System.Drawing.SolidBrush($script:ColMuted)
            $cRect = New-Object System.Drawing.RectangleF ([float]$cdX, [float]$y, [float]($cdRight - $cdX), [float]$barH)
            $g.DrawString(("$([char]0x21BB) $cd"), $fLabel, $cb, $cRect, $fmtR); $cb.Dispose()
        }
    }
    $fmtR.Dispose(); $vc.Dispose()
}

function Fill-Round($g, $brush, [int]$x, [int]$y, [int]$w, [int]$h, [double]$r) {
    if ($w -le 0) { return }
    if ($r * 2 -gt $w) { $r = $w / 2.0 }
    if ($r * 2 -gt $h) { $r = $h / 2.0 }
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [float]($r * 2)
    $gp.AddArc([float]$x, [float]$y, $d, $d, 180, 90)
    $gp.AddArc([float]($x + $w - $d), [float]$y, $d, $d, 270, 90)
    $gp.AddArc([float]($x + $w - $d), [float]($y + $h - $d), $d, $d, 0, 90)
    $gp.AddArc([float]$x, [float]($y + $h - $d), $d, $d, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($brush, $gp)
    $gp.Dispose()
}

$panel.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.ScaleTransform([float]$script:Scale, [float]$script:Scale)   # draw in design px

        # sizes in design pixels (10 px = 7.5 pt and 12 px = 9 pt at 96 dpi); the transform scales them
        $fLabel = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fBig   = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fSmall = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

        $u = $script:Usage
        if ($u.err -eq 'login') {
            # Logged out: stale cached numbers would be a lie. Say the real state and what a
            # click does.
            Draw-Row $g 12 15 "5h"  $fLabel $fBig   $null $null $false "signed out"  $script:ColRedD
            Draw-Row $g 37 11 "wk" $fLabel $fSmall $null $null $true  "click: sign in" $script:ColMuted
        } else {
            $sP = $u.sPct; $wP = $u.wPct
            Draw-Row $g 12 15 "5h"  $fLabel $fBig   $sP $u.sReset $false
            Draw-Row $g 37 11 "wk" $fLabel $fSmall $wP $u.wReset $true
        }

        # top-right status dot: red = token expired, amber = net/rate error, gray = data is stale
        # (last good fetch > 8 min old). No dot = fresh and healthy. Makes a lag visibly a lag.
        $ageSec = 99999.0
        if ($u.ts -is [DateTime]) { $ageSec = ([DateTime]::UtcNow - $u.ts.ToUniversalTime()).TotalSeconds }
        $dotCol = $null
        if ($u.err -eq 'auth' -or $u.err -eq 'login') { $dotCol = $script:ColRed }
        elseif ($u.err -eq 'rate' -or $u.err -eq 'net') { $dotCol = $script:ColAmber }
        elseif ($ageSec -gt 480) { $dotCol = $script:ColMuted }
        if ($dotCol) {
            $d = New-Object System.Drawing.SolidBrush($dotCol)
            $g.FillEllipse($d, $script:DesignW - 7, 3, 4, 4); $d.Dispose()
        }

        $fLabel.Dispose(); $fBig.Dispose(); $fSmall.Dispose()
    } catch { Write-WidgetLog "paint: $($_.Exception.Message)" }
})

# ===== Click vs drag =====
$script:Drag = @{ Down=$false; Dragging=$false; SX=0; SY=0; FX=0; FY=0 }
$panel.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:Drag.Down = $true; $script:Drag.Dragging = $false
    $pt = [System.Windows.Forms.Cursor]::Position
    $script:Drag.SX = $pt.X; $script:Drag.SY = $pt.Y
    $script:Drag.FX = $form.Location.X; $script:Drag.FY = $form.Location.Y
})
$panel.Add_MouseMove({
    param($s, $e)
    if (-not $script:Drag.Down) { return }
    $pt = [System.Windows.Forms.Cursor]::Position
    $dx = $pt.X - $script:Drag.SX; $dy = $pt.Y - $script:Drag.SY
    if (-not $script:Drag.Dragging -and ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 4)) { $script:Drag.Dragging = $true }
    if ($script:Drag.Dragging) {
        $form.Location = New-Object System.Drawing.Point([int]($script:Drag.FX + $dx), [int]($script:Drag.FY + $dy))
    }
})
$panel.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:Drag.Down) {
        if ($script:Drag.Dragging) {
            $script:Pos.posX = $form.Location.X; $script:Pos.posY = $form.Location.Y
            Save-Pos
        } elseif ($script:Usage.err -eq 'login') {
            Start-Login             # click = open `claude auth login` (the only cure)
        } else {
            Request-Manual-Fetch    # click = refresh now (60s floored)
        }
    }
    $script:Drag.Down = $false; $script:Drag.Dragging = $false
    try { if (-not $script:UiOpen) { Sink-ToBottom } } catch {}
})

# ===== Context menu =====
$script:UiOpen = $false
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
[void]$ctx.Items.Add("Refresh now", $null, { Request-Manual-Fetch })
[void]$ctx.Items.Add("Open usage page", $null, {
    try { Start-Process "https://claude.ai/settings/usage" } catch {}
})
[void]$ctx.Items.Add("Sign in to Claude CLI", $null, { Start-Login })
[void]$ctx.Items.Add("-")
[void]$ctx.Items.Add("Close widget", $null, { $form.Close() })
$ctx.add_Opening({ $script:UiOpen = $true })
$ctx.add_Closed({ $script:UiOpen = $false; try { Sink-ToBottom } catch {} })
$form.ContextMenuStrip = $ctx
$panel.ContextMenuStrip = $ctx

# ===== Pin below all windows =====
function Sink-ToBottom {
    # Re-sink only when actually raised: an unconditional HWND_BOTTOM makes DWM redo the
    # window shadow on every tick, which reads as widget shadows blinking.
    if (-not ('SinkGuard' -as [type])) {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class SinkGuard {[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);public static bool IsRaised(IntPtr hwnd) {IntPtr below = GetWindow(hwnd, 2);int g = 0;while (below != IntPtr.Zero && !IsWindowVisible(below) && g++ < 32) below = GetWindow(below, 2);if (below == IntPtr.Zero) return false;var sb = new System.Text.StringBuilder(64);GetClassName(below, sb, 64);string cls = sb.ToString();if (cls == "Progman" || cls == "WorkerW" || cls.StartsWith("WindowsForms10")) return false;return true;}}'
    }
    if (-not [SinkGuard]::IsRaised($form.Handle)) { return }
    [Native]::SetWindowPos($form.Handle, [Native]::HWND_BOTTOM, 0, 0, 0, 0,
        [Native]::SWP_NOMOVE -bor [Native]::SWP_NOSIZE -bor [Native]::SWP_NOACTIVATE) | Out-Null
}

$form.Add_Shown({
    try {
        $h = $form.Handle
        $ex = [Native]::GetWindowLong($h, [Native]::GWL_EXSTYLE)
        [Native]::SetWindowLong($h, [Native]::GWL_EXSTYLE,
            $ex -bor [Native]::WS_EX_NOACTIVATE -bor [Native]::WS_EX_TOOLWINDOW) | Out-Null
        # SetWindowRgn kills the DWM drop shadow (A/B capture proved layered/opacity does NOT,
        # while a window region does) and supplies the rounded corners, alone. DPI-aware window ->
        # region coords are physical px 1:1, so the rounded rect lines up exactly.
        # Intentionally NOT calling DwmSetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE) here:
        # corners must come from the region only, never from DWM.
        $rr14 = [int][Math]::Round(14 * $script:Scale)
        $rgn = [Native]::CreateRoundRectRgn(0, 0, $script:FormW + 1, $script:FormH + 1, $rr14, $rr14)
        [Native]::SetWindowRgn($h, $rgn, $true) | Out-Null
        Sink-ToBottom
        Write-WidgetLog "shown; region shadow-kill + rounded corners applied"
    } catch { Write-WidgetLog "Shown: $($_.Exception.Message)" }
    $script:LastFetch = [DateTime]::UtcNow   # mark now so the first timer tick does not double-fetch
    Start-Fetch
    $panel.Invalidate()
})

# ===== Timers =====
$script:LastFetch = [DateTime]::UtcNow.AddYears(-1)
$script:LastTick  = [DateTime]::UtcNow
$script:Backoff   = 0   # seconds; >0 after a failed fetch (429/net), doubles to a 300s cap
$script:LastAuthRefresh = [DateTime]::UtcNow.AddYears(-1)
$script:DupCheck  = 0
$script:LastErr   = $null
$script:CredCheck = 0
$script:CredChangedAt = [DateTime]::MinValue
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $now = [DateTime]::UtcNow
        # resume-from-sleep: a big gap between ticks -> refresh immediately
        $wokeUp = (($now - $script:LastTick).TotalSeconds -gt 90)
        $script:LastTick = $now

        if (Reap-Fetch) {
            $e = $script:Usage.err
            if ($null -eq $e) {
                if ($script:LastErr) { Write-WidgetLog ("fetch ok after err={0}: 5h={1}% week={2}%" -f $script:LastErr, $script:Usage.sPct, $script:Usage.wPct) }
                $script:Backoff = 0
            } elseif ($e -eq 'login') {
                # Logged out. Usually no request was even made; if one was, the token is dead for
                # good. Nothing to back off from: the credentials watcher below refetches the
                # moment `claude auth login` rewrites the file, else a slow 10-min safety poll.
                $script:Backoff = 0
                if ($script:LastErr -ne 'login') { Write-WidgetLog "fetch err=login: $($script:Usage.errMsg); waiting for 'claude auth login' (click the widget)" }
            } else {
                # Back OFF hard on failure (esp. 429): 300 -> 600 -> 1200 -> 1800 cap.
                $script:Backoff = [Math]::Min(1800, [Math]::Max(300, $script:Backoff * 2))
                Write-WidgetLog "fetch err=$e; backoff -> $($script:Backoff)s; $($script:Usage.errMsg)"
            }
            $script:LastErr = $e
            $panel.Invalidate()
        }

        # Token expired (401): the widget must NOT rewrite the shared credentials (rotating the
        # refresh token can break the CLI), so trigger the OFFICIAL CLI once to refresh+persist it.
        # Rate-limited to every 15 min; the next fetch then succeeds with the fresh token. This is
        # what makes the widget survive the ~8h token expiry when Claude Code is otherwise idle.
        if ($script:Usage.err -eq 'auth' -and (($now - $script:LastAuthRefresh).TotalSeconds -ge 900)) {
            $script:LastAuthRefresh = $now
            try {
                if (Test-Path $script:ClaudeExe) {
                    Start-Process -FilePath $script:ClaudeExe -ArgumentList '-p','--model','claude-haiku-4-5-20251001','OK' -WindowStyle Hidden
                    Write-WidgetLog "token expired -> triggered claude.exe refresh"
                }
            } catch { Write-WidgetLog "claude.exe refresh failed: $($_.Exception.Message)" }
        }

        # Duplicate backstop: once a minute, if a live claude_usage widget with a LOWER PID exists,
        # I am the younger duplicate -> exit. Converges to one instance (lowest PID survives) even if
        # a dup ever slips past the startup mutex + process guards.
        $script:DupCheck++
        if ($script:DupCheck -ge 60) {
            $script:DupCheck = 0
            try {
                $lower = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
                    Where-Object { $_.ProcessId -lt $PID -and (Is-WidgetCmd $_.CommandLine) })
                if ($lower.Count -gt 0) {
                    Write-WidgetLog "duplicate backstop: lower-PID instance $($lower.ProcessId -join ',') alive -> exiting (pid $PID)"
                    $form.Close()
                }
            } catch {}
        }

        # Credentials watcher: the CLI (or `claude auth login`) rewrote the file -> refetch now,
        # dropping any backoff. A local stat every 5s, no network.
        $script:CredCheck++
        if ($script:CredCheck -ge 5) {
            $script:CredCheck = 0
            $m = Get-CredMtime
            if ($m -ne $script:CredMtime) {
                $script:CredMtime = $m
                $script:CredChangedAt = $now
                $script:Backoff = 0
                Write-WidgetLog "credentials file changed -> refetch"
                if (-not $script:FetchBusy) { $script:LastFetch = $now; Start-Fetch }
            }
        }

        $idle = 0.0
        try { $idle = [IdleHelper]::IdleSeconds() } catch {}
        # Polite cadence, but close enough to track the browser: 2 min active / 5 min idle, with
        # backoff on failure. Single-instance is now hard-guaranteed (pinned mutex + backstop), so
        # there is no doubling, and the endpoint stays under its rate limit.
        $interval = 120
        if ($idle -ge 3600) { $interval = 600 } elseif ($idle -ge 600) { $interval = 300 }
        # Logged out: the timer must not hammer a dead token. Slow safety poll only, except right
        # after the credentials file changed (a login may land in two writes -> re-read quickly).
        if ($script:Usage.err -eq 'login') { $interval = if (($now - $script:CredChangedAt).TotalSeconds -lt 120) { 15 } else { 600 } }
        if ($script:Backoff -gt $interval) { $interval = $script:Backoff }  # a failure backoff always wins

        # Reset-boundary refetch: refresh soon after a window rolls over, but NEVER faster than the
        # current interval (min 45s) so it cannot create a 429 feedback loop.
        $boundary = $false
        foreach ($rt in @($script:Usage.sReset, $script:Usage.wReset)) {
            if ($rt -is [DateTime] -and $now -ge $rt.ToUniversalTime()) { $boundary = $true }
        }
        $sinceFetch = ($now - $script:LastFetch).TotalSeconds
        $forced = $boundary -and ($script:Usage.err -ne 'login') -and ($sinceFetch -ge [Math]::Max(45, $script:Backoff))

        if (-not $script:FetchBusy -and ($wokeUp -or $forced -or $sinceFetch -ge $interval)) {
            $script:LastFetch = $now
            Start-Fetch
        }
        # repaint once a second so the countdowns tick down
        $panel.Invalidate()
    } catch { Write-WidgetLog "tick: $($_.Exception.Message)" }
})
$timer.Start()

$sinkTimer = New-Object System.Windows.Forms.Timer
$sinkTimer.Interval = 30000
$sinkTimer.Add_Tick({ try { if (-not $script:UiOpen) { Sink-ToBottom } } catch {} })
$sinkTimer.Start()

$form.Add_FormClosed({ Save-Pos })

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) try { Write-WidgetLog "ThreadException (recovered): $($e.Exception.Message)" } catch {} })
Write-WidgetLog "start (pid $PID) pos=$($form.Location.X),$($form.Location.Y)"
$form.ShowDialog() | Out-Null
# keep the single-instance mutex rooted for the whole process lifetime (stops the GC finalizer
# from releasing it mid-run, which was letting a duplicate acquire it)
[System.GC]::KeepAlive($script:SingleMutex)
try { $script:SingleMutex.ReleaseMutex() } catch {}
Write-WidgetLog "ShowDialog returned (closed) pid $PID"
