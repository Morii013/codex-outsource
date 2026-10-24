---
name: cop
description: /cop 快捷入口：把项目任务外包给 Codex，项目根目录以 AGENTS.md 配置为准。普通任务用 /co。
argument-hint: "[任务描述]"
---

# /cop（项目任务）

用户用 `/cop` 指示：在 Codex 项目里执行任务。普通任务用 `/co`。

**硬规则：/cop 必须走 Codex，DSH 不得自己执行。**

## 默认续用同一个对话

- 默认用 `-Auto -Record -Cwd`：项目里有 `work/codex/thread.json` 就续，没有就新建并记录。
- 后续指令、补充、修改一律 `-Auto` 或 `-Thread <id>`，不要再 `-New`。
- 只有用户明确说“新对话/重新开一个”才用 `-New`。

## 项目根目录

以 `AGENTS.md` 里「/co 与 /cop（Codex 外包）」一节的 `项目根目录` 为准（`install.ps1` 写入）。工作区规则文件是它上一级的 `AGENTS.md`、`全局工作台.md`、`新项目SOP.md`，用哈希缓存，内容没变就不重读。

## 一次调用完成

```powershell
$ROOT = '<AGENTS.md 里的项目根目录>'   # 填实际路径
$WS = Split-Path $ROOT -Parent
$h = (Get-FileHash "$WS\AGENTS.md","$WS\全局工作台.md","$WS\新项目SOP.md" | ForEach-Object Hash) -join ','
$cache = "$env:USERPROFILE\.dsh\skills\codex-outsource\.sop-hash"
if (-not (Test-Path $cache) -or (Get-Content $cache -Raw).Trim() -ne $h) {
  Get-Content "$WS\AGENTS.md","$WS\全局工作台.md","$WS\新项目SOP.md" -Raw
  Set-Content $cache $h
}
$nums = Get-ChildItem $ROOT -Directory | Where-Object { $_.Name -match '^project-(\d{3})__' } | ForEach-Object { [int]$_.Name.Substring(8,3) }
$n = if ($nums) { ($nums | Measure-Object -Maximum).Maximum + 1 } else { 1 }
$P = Join-Path $ROOT ("project-{0:D3}__name" -f $n)
New-Item -ItemType Directory -Force "$P\input","$P\work","$P\output","$P\backup","$P\docs","$P\assets","$P\data","$P\work\codex" | Out-Null
Set-Content "$P\work\codex\01-task.md" -Encoding UTF8 -Value "## 目标`n（任务，含按 SOP 补 README）"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\codex-outsource\scripts\codex-app-job.ps1" -Auto -Record -Cwd $P -Task "work\codex\01-task.md" -Out "work\codex\01-result.md" 2>&1 | Select-Object -Last 1
Get-Content "$P\work\codex\01-result.md" -Encoding UTF8 -ErrorAction SilentlyContinue
```

- 任务书只写目标；README 交给 Codex 按 SOP 补。
- 验收接在末尾；结果完整输出。
- 成功直接回复，失败才补一次排查。
- 验收不通过：`-Auto` 续同一对话再下令，附报错原文，循环到通过；简单任务可只验一次。
