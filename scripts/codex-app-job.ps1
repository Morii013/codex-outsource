# codex-app-job — 把任务投给 Codex 应用（可新建对话），等它跑完，只输出最终回答。
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-app-job.ps1 -Thread <会话id或名字> -Task TASK [-Out OUT] [-Image IMG ...] [-TimeoutSec 900]
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-app-job.ps1 -New [-Cwd 项目目录] -Task TASK [-Out OUT] [-Record] [-Verify '命令'] [-Image IMG ...] [-Open]
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-app-job.ps1 -New -Background [-Cwd 项目目录] -Task TASK ...  # 不抢前台，线程仍进应用历史
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-app-job.ps1 -Auto -Task TASK ...
[CmdletBinding()]
param(
    [string]$Thread,
    [Parameter(Mandatory = $true)][string]$Task,
    [string]$Out,
    [int]$TimeoutSec = 900,
    [switch]$New,
    [string]$Cwd,
    [switch]$Record,
    [switch]$Auto,
    [string]$Verify,
    [string[]]$Image,
    [switch]$Background,
    [switch]$Open,
    [string]$Model = $(if ($env:CODEX_MODEL) { $env:CODEX_MODEL } else { 'gpt-6-sol' }),
    [string]$Sandbox = 'workspace-write'
)

# Stop 在 PS 5.1 下叠 native stderr + 重定向会死锁，统一用 Continue
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not ('Fg' -as [type])) {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;using System.Text;public class Fg { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid); [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); [DllImport("user32.dll")] public static extern bool AttachThreadInput(int a, int b, bool f); [DllImport("kernel32.dll")] public static extern int GetCurrentThreadId(); public static int Pid(){ int p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; } public static string Title(){ var b=new StringBuilder(256); GetWindowText(GetForegroundWindow(), b, 256); return b.ToString(); } public static bool Force(IntPtr h){ ShowWindow(h, 9); var fg=GetForegroundWindow(); int fgPid; GetWindowThreadProcessId(fg, out fgPid); int t=GetCurrentThreadId(); AttachThreadInput(t, fgPid, true); bool r=SetForegroundWindow(h); AttachThreadInput(t, fgPid, false); return r; } }'
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$indexPath = Join-Path $codexHome 'session_index.jsonl'

if (-not (Test-Path -LiteralPath $Task -PathType Leaf)) { Write-Error "codex-app-job: no such task file: $Task"; exit 2 }
if ($Background -and -not $New) { Write-Error "codex-app-job: -Background 只能和 -New 一起用"; exit 2 }
$taskPath = [System.IO.Path]::GetFullPath($Task)
$workDir = if ($Cwd) { $Cwd } else { (Get-Location).Path }
$outPath = if ($Out) { [System.IO.Path]::GetFullPath($Out) } else { "$taskPath.out.md" }

function Resolve-Against([string]$Path, [string]$Base) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Get-IndexIds {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path -LiteralPath $indexPath) {
        foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
            if (-not $line.Trim()) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            if ($row.id) { $null = $set.Add($row.id) }
        }
    }
    return ,$set
}

function Find-Rollout([string]$Id) {
    Get-ChildItem -Path (Join-Path $codexHome 'sessions') -Recurse -Filter "rollout-*$Id*.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Read-NewBytes([string]$Path, [long]$From) {
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($From -ge $fs.Length) { return '' }
        $fs.Position = $From
        $length = [int]($fs.Length - $From)
        $buffer = New-Object byte[] $length
        $read = $fs.Read($buffer, 0, $length)
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    } finally { $fs.Dispose() }
}

function Wait-Done([string]$RolloutPath, [long]$From) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $new = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $new = Read-NewBytes $RolloutPath $From
        if ($new -match '"type":"task_complete"') { break }
    }
    if ($new -notmatch '"type":"task_complete"') { Write-Error "codex-app-job: 等待超时（${TimeoutSec}s）"; exit 3 }
    $message = $null
    foreach ($line in ($new -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.payload -and $row.payload.type -eq 'task_complete') { $message = $row.payload.last_agent_message }
    }
    if ($null -eq $message) { Write-Error "codex-app-job: 没解析到最终回答"; exit 4 }
    [System.IO.File]::WriteAllText($outPath, "$message`n", (New-Object System.Text.UTF8Encoding($false)))
}

# 新目录第一次打开会弹信任；直接写进 config.toml，省掉点击
function Trust-ProjectPath([string]$Path) {
    $cfg = Join-Path $codexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) { return }
    $key = "[projects.'" + $Path.Replace("'", "''") + "']"
    $txt = [System.IO.File]::ReadAllText($cfg)
    if ($txt.Contains($key)) { return }
    if ($txt.Length -gt 0 -and -not $txt.EndsWith("`n")) { $txt += "`r`n" }
    $txt += "`r`n$key`r`ntrust_level = `"trusted`"`r`n"
    [System.IO.File]::WriteAllText($cfg, $txt, (New-Object System.Text.UTF8Encoding($false)))
}

function Save-ThreadId([string]$Id) {    if (-not $Record) { return }
    $rd = Join-Path $workDir 'work/codex'
    New-Item -ItemType Directory -Force $rd | Out-Null
    '{"id":"' + $Id + '"}' | Set-Content -LiteralPath (Join-Path $rd 'thread.json') -Encoding UTF8
    Write-Output "codex-app-job: recorded=$(Join-Path $rd 'thread.json')"
}

function Get-ForegroundName {
    $fgPid = [Fg]::Pid()
    $proc = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return ''
}

# AppActivate 可能被前台锁拦下；重试并用 SetForegroundWindow 强制置前
function Activate-ChatGPT {
    $p = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return $false }
    $ws = New-Object -ComObject WScript.Shell
    for ($i = 0; $i -lt 6; $i++) {
        if ($ws.AppActivate($p.Id)) {
            Start-Sleep -Milliseconds 300
            if ((Get-ForegroundName) -eq 'ChatGPT') { return $true }
        }
        [void][Fg]::Force($p.MainWindowHandle)
        Start-Sleep -Milliseconds 300
        if ((Get-ForegroundName) -eq 'ChatGPT') { return $true }
    }
    return $false
}

# 前台必须真是 ChatGPT，否则 SendKeys 会把内容打进当前焦点窗口（微信等）
function Assert-ChatGPTForeground {
    $proc = Get-Process -Id ([Fg]::Pid()) -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -ne 'ChatGPT') {
        Write-Error "codex-app-job: 前台不是 ChatGPT（当前: $($proc.ProcessName) / $([Fg]::Title())），已中止，避免误输入"
        exit 7
    }
}

# 往应用里粘贴：$Id 为空且给了 $Path 时，在该项目目录下开新对话。
function Send-ToApp([string]$Id, [string]$Path, [string]$Text, [string[]]$Images) {
    if ($Id) { Start-Process "codex://threads/$Id" -ErrorAction SilentlyContinue }
    elseif ($Path) { Start-Process "codex://threads/new?path=$([uri]::EscapeDataString($Path))" }
    else { Start-Process "codex://threads/new" }
    # 新对话/工作区都要等输入框就绪，统一等 5 秒再粘贴
    Start-Sleep -Seconds 5

    if (-not (Activate-ChatGPT)) { Write-Error "codex-app-job: 无法把 ChatGPT 切到前台"; exit 6 }
    Start-Sleep -Seconds 1
    Assert-ChatGPTForeground
    $ws = New-Object -ComObject WScript.Shell

    if ($Images) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        foreach ($img in @($Images)) {
            if (-not $img) { continue }
            $ip = Resolve-Against $img $workDir
            if (-not (Test-Path -LiteralPath $ip -PathType Leaf)) { Write-Error "codex-app-job: 图片不存在: $ip"; exit 2 }
            $bmp = [System.Drawing.Image]::FromFile($ip)
            [System.Windows.Forms.Clipboard]::SetImage($bmp)
            $ws.SendKeys('^v')
            Start-Sleep -Milliseconds 800
            $bmp.Dispose()
        }
    }

    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 500
    Assert-ChatGPTForeground
    $ws.SendKeys('^v')
    Start-Sleep -Milliseconds 800
    Assert-ChatGPTForeground
    $ws.SendKeys('{ENTER}')
}

if ($Auto -and -not $Thread -and -not $New) {
    $tj = Join-Path $workDir 'work/codex/thread.json'
    if (Test-Path -LiteralPath $tj) {
        try { $Thread = (Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).id } catch { }
    }
    if (-not $Thread) { $New = $true }
}
if (-not $Thread -and -not $New) { Write-Error "codex-app-job: give -Thread or -New"; exit 2 }

$text = Get-Content -LiteralPath $Task -Raw -Encoding UTF8

if ($New -and $Background) {
    # 后台模式：headless codex exec，线程照样写进 ~/.codex/sessions，应用历史里可见
    $jobScript = Join-Path $PSScriptRoot 'codex-job.ps1'
    if (-not (Test-Path -LiteralPath $jobScript)) { Write-Error "codex-app-job: 找不到同目录的 codex-job.ps1"; exit 2 }
    $jobArgs = @('-Dir', $workDir, '-Task', $taskPath, '-Out', $outPath, '-Model', $Model, '-Sandbox', $Sandbox)
    if ($Image) { $jobArgs += '-Image'; $jobArgs += @($Image) }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $jobScript @jobArgs 2>&1
    foreach ($line in @($out)) { Write-Output $line }
    $id = $null
    foreach ($line in @($out)) {
        if ("$line" -match 'session=([0-9a-fA-F-]{8,})') { $id = $Matches[1]; break }
    }
    if (-not $id) { Write-Error "codex-app-job: 后台任务没拿到 session id"; exit 1 }
    Write-Output "codex-app-job: ok thread=$id result=$outPath"
    Save-ThreadId $id
    if ($Open) { Start-Process "codex://threads/$id" -ErrorAction SilentlyContinue }
} elseif ($New) {
    $before = Get-IndexIds
    if ($Cwd -and -not (Test-Path -LiteralPath $Cwd -PathType Container)) { Write-Error "codex-app-job: 目录不存在: $Cwd"; exit 2 }
    if ($Cwd) { Trust-ProjectPath $workDir }
    # 用 codex://threads/new?path=... 直接在该目录下开新对话，不额外开默认目录的对话
    Send-ToApp '' $workDir $text $Image

    # 新线程 id 从 session_index.jsonl 的 diff 里拿，不用 sqlite
    $id = $null
    for ($attempt = 0; $attempt -lt 2 -and -not $id; $attempt++) {
        if ($attempt -gt 0) { Send-ToApp '' $workDir $text $Image }  # 第一轮没发出去，重发一次
        $deadline = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            $now = Get-IndexIds
            $id = $now | Where-Object { -not $before.Contains($_) } | Select-Object -First 1
            if ($id) { break }
        }
    }
    if (-not $id) { Write-Error "codex-app-job: 新对话没有创建出来（检查 ChatGPT 是否在前台、输入框是否聚焦）"; exit 6 }

    $rollout = $null
    while (-not $rollout) { $rollout = Find-Rollout $id; if (-not $rollout) { Start-Sleep -Seconds 1 } }

    Wait-Done $rollout.FullName 0
    Write-Output "codex-app-job: ok thread=$id result=$outPath"
    Save-ThreadId $id
} else {
    $id = $Thread
    if ($Thread -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-') {
        $found = $null
        if (Test-Path -LiteralPath $indexPath) {
            foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
                if (-not $line.Trim()) { continue }
                try { $row = $line | ConvertFrom-Json } catch { continue }
                if ($row.thread_name -eq $Thread) { $found = $row.id; break }
            }
        }
        if (-not $found) { Write-Error "codex-app-job: 找不到会话: $Thread"; exit 2 }
        $id = $found
    }

    $rollout = Find-Rollout $id
    if (-not $rollout) { Write-Error "codex-app-job: 找不到会话文件: $id"; exit 2 }
    $base = (Get-Item -LiteralPath $rollout.FullName).Length

    if ($Image) {
        # queue 不支持图片（CLI 会报 does not support image attachments），改走应用内粘贴
        Send-ToApp $id '' $text $Image
    } else {
        Start-Process "codex://threads/$id" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $queued = $false
        for ($i = 0; $i -lt 10; $i++) {
            & codex queue --thread $id --message $text *> $null
            if ($LASTEXITCODE -eq 0) { $queued = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $queued) { Write-Error "codex-app-job: queue 失败（Codex 应用没开或 IPC 不可用）"; exit 1 }
    }

    Wait-Done $rollout.FullName $base
    Write-Output "codex-app-job: ok thread=$id result=$outPath"
}

if ($Verify) {
    Write-Output '--- verify ---'
    $vcwd = if ($Cwd) { $Cwd } else { (Get-Location).Path }
    Push-Location -LiteralPath $vcwd
    & powershell -NoProfile -ExecutionPolicy Bypass -Command $Verify 2>&1 | Select-Object -Last 20 | ForEach-Object { Write-Output $_ }
    Write-Output "verify_exit=$LASTEXITCODE"
    Pop-Location
}
