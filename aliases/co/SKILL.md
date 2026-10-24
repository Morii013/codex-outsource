---
name: co
description: /co 快捷入口：把普通任务（最近，不进项目）外包给 Codex 应用。项目任务用 /cop。
argument-hint: "[任务描述]"
---

# /co（普通任务）

用户用 `/co` 指示：把任务外包给 Codex，跑在“最近”。项目任务用 `/cop`。

**硬规则：/co 必须走 Codex，DSH 不得自己执行。**

## 默认续用同一个对话

- 默认用 `-Auto -Record`：有 `work/codex/thread.json` 就续，没有就新建并记录。
- 后续指令、补充、修改一律 `-Auto` 或 `-Thread <id>`，不要再 `-New`。
- 只有用户明确说“新对话/重新开一个”才用 `-New`。

## 一次调用完成

写任务书、下令、验收、读结果全部放进同一条命令，只输出末尾几行。

```powershell
New-Item -ItemType Directory -Force work\codex | Out-Null
Set-Content work\codex\01-task.md -Encoding UTF8 -Value "## 目标`n（任务）"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\codex-outsource\scripts\codex-app-job.ps1" -Auto -Record -Task "work\codex\01-task.md" -Out "work\codex\01-result.md" 2>&1 | Select-Object -Last 1
Get-Content work\codex\01-result.md -Encoding UTF8 -ErrorAction SilentlyContinue
```

- 任务书只写一句目标。
- 验收命令接在同一条命令末尾；结果完整输出。
- 成功直接回复，失败才补一次排查。
- 验收不通过：`-Auto` 续同一对话再下令，附报错原文，循环到通过；简单任务可只验一次。
