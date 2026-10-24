---
name: codex-outsource
description: 把重活外包给本机 Codex CLI（ChatGPT 月度订阅，登录认证，不走 API key）：DSH 写任务书、挂后台进程等结果、只读最终消息和 diff。支持 macOS / Linux / Windows。用于写代码、批量改文件、跑长任务、深度调研等耗上下文的工作。
---

# Codex 外包

把重活派给 Codex（ChatGPT 订阅额度，登录认证，不走 API key）。DSH 只负责写任务书、下令、验收；每轮大约 2 个模型步。DSH 花 token 的地方只有三处：想清楚一句能让 Codex 听懂的目标、下令、验收。中间的实现、工具调用、自测由 Codex 自己的 agent 完成，不经过 DSH。每轮最多 2 次模型调用：一次工具调用（写单 + 下令 + 验收）加一次回复；多一次就是在烧 token。

## 什么时候用

用：写/改代码、批量重命名或重构、跑长脚本、批量读一堆文件出报告、需要几十分钟的单线程苦活。

不用（仅限用户没有点名 `/co` 时）：要跟用户来回确认的需求、需要 DSH 逐行看过程才能判断的调试、一句话就能改完的小活。

用户输入 `/co` 时例外：不管任务大小，一律走本 skill，DSH 不得自己代劳。

## 项目任务 vs 最近任务

- 项目任务（macOS `~/Desktop/workspace/10-projects/<项目>`；Windows `<项目根目录>\project-NNN__name`）：**建项目前先读工作区的 `AGENTS.md`、`全局工作台.md`、`新项目SOP.md` 并遵守**（同会话未变可跳过重读）；任务清楚就直接建项目投递，含糊才先问一句。
- 最近任务（临时、只读研究、一次性）：不拍版，直接 `--new` 投递。
- 过程中遇到需要用户拍板或人工验证的点：停下来问，拿到答复再继续；每次只问一个问题。

## 两条通道

- **A. Codex 应用通道（默认，能看见）**：任务投进 Codex 应用里一条已绑定的对话，应用自己跑，用户可以在应用里全程看。
- **B. CLI 通道（后台，看不见）**：headless `codex exec`，不需要人看时用。

### 对话怎么建

- “最近”里的任务：默认 `--auto` / `-Auto` 续用 `work/codex/thread.json` 记录的对话，没有记录才新建。只有用户明确要新对话时才 `--new` / `-New`。脚本打印 `thread=<id>`。
- 项目任务：先在 `~/Desktop/workspace/10-projects/NNN-name` 建项目文件夹，然后 `codex-app-job.sh --new --cwd <项目目录>`；脚本会 `codex app <目录>` 建/打开 Codex 项目，再在该项目下开新对话。拿到 id 后记进项目 `work/codex/thread.json`：

```json
{"id": "01a1...", "name": "DSH 外包 · 项目名"}
```

- 后续轮次一律 `--thread <id>` 续同一个对话。
- 应用审批模式要设成不询问，否则会停住等人点确认。

## 脚本位置

- macOS / Linux：`scripts/codex-app-job.sh`（A）、`scripts/codex-job.sh`（B）
- Windows：`scripts/codex-app-job.ps1`（A，`-New` 新建对话 / `-New -Background` 不抢前台 / `-Thread` 续已有对话 / `-Auto` 读 thread.json / `-Image` 附图）、`scripts/codex-job.ps1`（B）

下文用 `<skill-dir>` 表示本 skill 的 base directory。

## 一轮流程（通道 A：Codex 应用）

省 token 的标准姿势：一条 bash 里写任务书 → 前台跑脚本（脚本会阻塞到 Codex 返回）→ `--verify` 顺手验收；下一轮用 `--auto` 续同一个对话。全程 2 次模型调用。

```bash
cat > work/codex/01-task.md <<'TASK'
## 目标
...
TASK
bash <skill-dir>/scripts/codex-app-job.sh --new --record --task work/codex/01-task.md \
  --verify '<验收命令>'
```

1. 写任务书到项目 `work/codex/NN-task.md`（模板见下）。
2. 第一轮，新建对话（后台跑，`run_in_background: true`）：

   ```bash
   bash <skill-dir>/scripts/codex-app-job.sh \
     --new \
     --task work/codex/01-task.md \
     --out work/codex/01-result.md
   ```

   脚本会深链开新对话 → 粘贴任务书 → 回车 → 抓到新线程 id → 盯 rollout 到 `task_complete`，打印 `thread=<id>` 并写结果。
3. 后续轮次用同一个会话：

   ```bash
   bash <skill-dir>/scripts/codex-app-job.sh \
     --thread <id> \
     --task work/codex/NN-task.md \
     --out work/codex/NN-result.md
   ```

   脚本用 `codex queue` 投递，应用自己跑。
4. 带图片：加 `--image <png>`（新对话走剪贴板粘贴，后续走 queue 附件）。
5. 等完成通知，不要轮询；只读结果 + 自己跑测试或看 `git diff --stat` 验收。

## 一轮流程（通道 B：CLI）

1. 写任务书到项目 `work/codex/NN-task.md`。
2. 后台启动：

   ```bash
   bash <skill-dir>/scripts/codex-job.sh \
     --dir /绝对路径/项目目录 \
     --task work/codex/NN-task.md \
     --out work/codex/NN-result.md \
     --log work/codex/NN.log
   ```

   Windows 用 `codex-job.ps1 -Dir ... -Task ... -Out ... -Log ...`；缺省 `-m gpt-6-sol`、`-s workspace-write`，自动挂代理，并打印 `session=<id>`。
3. 等完成通知；只读 result + 验收。
4. 追问加 `--resume <session id>`。

## 任务书模板

只写目标，一句话：

```markdown
## 目标
一句话说清要做成什么。
```

不写验收命令、不写回答格式、不写约束、不写防御性检查。验收由 DSH 自己跑。

## 验收（不能省）

codex 说“做完了”不算数。DSH 自己跑一遍项目的测试或构建，看 `git diff --stat`，抽查关键 diff。验收不通过时，用 `-Auto`（或 `--auto`）续同一个对话再下一道令，附上失败现象或报错原文，不要自己上手重写。复杂任务必须这样循环，直到满足要求；简单任务允许一次验收通过就结束。

## 额度（月度订阅）

- 不按 token 记账，也不用记。Codex 额度按 **5 小时窗口**滚动，窗口内任务太多或太大时会限流。
- 脚本失败且日志里出现额度相关报错时会打印提示：等窗口重置再派。
- 建议：先跑小任务再派大活；同一窗口里别连环派满汉全席；剩余额度在 ChatGPT / Codex 客户端里看。

## 默认配置与限制

- 通道 A：`--record` 自动把 thread id 写进 `work/codex/thread.json`；`--auto` 优先续这个对话；`--verify` 在结果后跑验收命令并打印退出码。
- 通道 A：Codex 应用必须开着；绑定的对话要打开过、审批模式不能是“每次询问”；macOS 用 `open "codex://threads/<id>"`，Windows 用 `start "" "codex://threads/<id>"`（脚本已处理）。
- 模型：通道 B 默认 `gpt-6-sol`；你的账号如果报 `model is not supported`，用 `CODEX_MODEL` / `-Model` 换一个客户端里能用的模型。不要去改 `~/.codex/config.toml` 来迁就本工具。
- 网络（通道 B）：需要代理访问 `chatgpt.com`。需要代理时设 `CODEX_PROXY`。
- 权限（通道 B）：默认 `workspace-write`（只写工作目录和临时目录）。Windows 上如果报 sandbox 不可用，改用 `--sandbox danger-full-access` / `-Sandbox danger-full-access`，风险自担。
- `exec resume` 子命令没有 `-s` / `-Sandbox`，脚本已用 `-c "sandbox_mode=..."` 补上；手动跑时别漏。
- 不要改 `~/.codex/config.toml` 和 `~/.codex/AGENTS.md`；那是 Codex 自己的配置。
- 删除类任务：Codex 会拒绝 `rm -f`（安全策略），改成 `mv` 到 `~/.Trash/` 并验证；需要永久删除时由 DSH 自己执行。
- 原生 `subagent_codex` 工具若因模型问题报 product-error，与本 skill 无关；这里走 CLI。

## 平台注意

- Windows：需要 PowerShell 5.1+ 和 PATH 里的 `codex`；用 `-ExecutionPolicy Bypass` 绕过执行策略；任务书和结果按 UTF-8 读写。
- macOS / Linux：bash 或 zsh 都可。
