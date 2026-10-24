# codex-job — 把一次任务外包给本机 Codex CLI（ChatGPT 订阅登录，不走 API key）。
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-job.ps1 -Dir DIR -Task TASK_FILE [-Out OUT] [-Log LOG] [-Model M] [-Resume SESSION] [-Sandbox MODE]
# TASK/OUT/LOG 用相对路径时按 -Dir 解析。成功时只把最终回答写进 OUT，过程写进 LOG。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][string]$Task,
    [string]$Out,
    [string]$Log,
    [string]$Model = $(if ($env:CODEX_MODEL) { $env:CODEX_MODEL } else { 'gpt-6-sol' }),
    [string]$Resume,
    [string]$Sandbox = 'workspace-write',
    [string[]]$Image
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Resolve-Against([string]$Path, [string]$Base) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $Path))
}

$dirPath = [System.IO.Path]::GetFullPath($Dir)
if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { Write-Error "codex-job: no such dir: $Dir"; exit 2 }
$taskPath = Resolve-Against $Task $dirPath
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { Write-Error "codex-job: no such task file: $taskPath"; exit 2 }
$outPath = if ($Out) { Resolve-Against $Out $dirPath } else { "$taskPath.out.md" }
$logPath = if ($Log) { Resolve-Against $Log $dirPath } else { "$taskPath.log" }
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath)
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath)

# 需要代理时由 CODEX_PROXY 提供
$proxy = $env:CODEX_PROXY
if ($proxy) {
    $env:HTTPS_PROXY = $proxy
    $env:HTTP_PROXY = $proxy
    $env:ALL_PROXY = $proxy
}

$prompt = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
$imgArgs = @()
foreach ($img in @($Image)) { if ($img) { $imgArgs += @('-i', (Resolve-Against $img $dirPath)) } }
Push-Location -LiteralPath $dirPath
try {
    if ($Resume) {
        # resume 子命令没有 -Sandbox，用 config 覆盖同样的沙箱策略，否则默认只读
        $output = $prompt | codex exec resume $Resume --skip-git-repo-check -m $Model -c "sandbox_mode=`"$Sandbox`"" -o $outPath @imgArgs - 2>&1
    } else {
        $output = $prompt | codex exec --skip-git-repo-check -s $Sandbox -m $Model -o $outPath @imgArgs - 2>&1
    }
    $rc = $LASTEXITCODE
} catch {
    $output = @($_.Exception.Message)
    $rc = 1
} finally {
    Pop-Location
}

$output | Out-File -FilePath $logPath -Encoding utf8

$sid = $null
foreach ($line in @($output)) {
    if ("$line" -match 'session id: ([0-9a-fA-F-]{8,})') { $sid = $Matches[1]; break }
}
$sidText = if ($sid) { $sid } else { '?' }
Write-Output "codex-job: exit=$rc session=$sidText result=$outPath"

if ($rc -ne 0) {
    Write-Output '--- tail of log ---'
    @($output) | Select-Object -Last 8 | ForEach-Object { Write-Output $_ }
    if ((@($output) -join "`n") -match '(?i)usage limit|rate limit|rate_limit|usageLimitExceeded|quota exceeded') {
        Write-Output 'codex-job: 疑似撞上 Codex 额度窗口，等 5 小时窗口重置后再派，或先跑小任务。'
    }
}
exit $rc
