param(
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [string]$ProjectsRoot = (Join-Path $env:USERPROFILE 'projects'),
    [string]$RepoUrl = 'https://github.com/Morii013/codex-outsource.git',
    [switch]$SkipChecks
)

# native 命令写 stderr 时 Stop 会误判，这里统一 Continue 并检查退出码
$ErrorActionPreference = 'Continue'
$skills = Join-Path $DshHome 'skills'
$skillDir = Join-Path $skills 'codex-outsource'
New-Item -ItemType Directory -Force $skills | Out-Null

if (Test-Path (Join-Path $skillDir '.git')) {
    git -C $skillDir pull --ff-only 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git pull 失败：$skillDir" }
} elseif (Test-Path $skillDir) {
    throw "目标已存在且不是 git 仓库：$skillDir"
} else {
    git clone $RepoUrl $skillDir 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git clone 失败：$RepoUrl" }
}

foreach ($n in @('co', 'cop')) {
    $src = Join-Path $skillDir "aliases\$n"
    if (-not (Test-Path $src)) { throw "缺少 aliases\$n" }
    $dst = Join-Path $skills $n
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Item $src $dst -Recurse -Force -ErrorAction Stop
}

New-Item -ItemType Directory -Force $ProjectsRoot | Out-Null

$agents = Join-Path $DshHome 'AGENTS.md'
$section = @'
## /co 与 /cop（Codex 外包）

用户输入 `/co` 或 `/cop` 时，不要再加载 skill 工具，按本节直接执行。

- 项目根目录：{{ROOT}}
- 整轮只允许一次 pwsh 调用加一次回复。
- 任务书在同一条 pwsh 里用 `Set-Content` 写，不要用 write/edit 工具。
- `/co` 用 `-Auto -Record`；`/cop` 用 `-Auto -Record -Cwd`。只有用户明确要新对话才 `-New`。
- 验收接在同一条命令末尾；结果文件完整输出，不截断。
- 成功直接回复，失败才补一次排查。
- 复杂任务验收不通过就继续 `-Auto` 续同一对话再下令，循环到通过；简单任务可只验一次。
'@
$section = $section.Replace('{{ROOT}}', $ProjectsRoot)

$txt = if (Test-Path $agents) { [System.IO.File]::ReadAllText($agents) } else { '' }
if ($txt -notmatch '/co 与 /cop（Codex 外包）') {
    if ($txt -and -not $txt.EndsWith("`n")) { $txt += "`r`n" }
    $txt += "`r`n" + $section
    [System.IO.File]::WriteAllText($agents, $txt, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "AGENTS.md 已追加配置"
} else {
    Write-Output "AGENTS.md 已有配置，跳过"
}

if (-not $SkipChecks) {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        Write-Warning 'codex 不在 PATH：先安装 Codex CLI 并 codex login'
    } else {
        $v = (& codex --version 2>&1 | Out-String).Trim()
        Write-Output "codex: $v"
        if ($v -match 'codex-cli 0\.(1[0-5][0-9]|[0-9])\.') {
            Write-Warning 'Codex CLI 过旧：npm install -g @openai/codex@latest'
        }
        $st = (& codex login status 2>&1 | Out-String)
        if ($st -notmatch 'Logged in') { Write-Warning 'codex 未登录：codex login' }
    }
}

Write-Output "已安装：$skillDir"
Write-Output "项目根目录：$ProjectsRoot"
