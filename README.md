# codex-outsource

把重活外包给本机 Codex（ChatGPT 订阅额度，登录认证，不走 API key）。DSH 只负责想清楚目标、下令、验收；实现过程由 Codex 自己的 agent 和工具完成。

这份文档写给第一次在全新 Windows 电脑上安装的人，也写给 agent。照做完就能用 `/co`、`/cop`，并把 DSH 的 token 消耗压到最低。

---

## 一、目标与原理

### 1.1 两套额度，别混

| 资源 | 谁在用 | 怎么扣 |
|---|---|---|
| DSH token | DSH 每次调用模型 | 按「固定载荷 + 会话历史」计费 |
| Codex 额度 | Codex 应用/CLI | ChatGPT 订阅的 5 小时窗口，不按 token |

Codex 干活不花 DSH 的钱。DSH 只在「下令」和「验收」两个动作上花钱。

### 1.2 为什么这样能省

DSH 每发一次模型请求，都会把固定载荷（系统提示、工具定义、AGENTS.md、技能目录）加当前会话历史重新发一遍，固定载荷本身就有几十 K token。

- 直接在 DSH 里干活：一次工具调用 + 一次回复，约 2 次请求。
- 旧的 `/co` 流程：加载 skill、单独写任务书、跑脚本、回复，约 4 次请求，翻倍。
- 现在：规则写进 `AGENTS.md`（本来就在上下文里），任务书在同一条命令里写，整轮固定 2 次请求。

省 token 的关键只有两条：**减少请求次数**、**缩短会话历史**。

### 1.3 分工

```text
DSH：想清楚一句目标 → 写任务书 → 下令 → 验收
Codex：读任务书 → 自己调工具/改文件/跑测试 → 返回最终回答
```

复杂任务验收不通过时，DSH 续同一个对话再次下令，循环到满足要求；简单任务验收一次即可。

---

## 二、环境要求

| 组件 | 要求 | 检查命令 |
|---|---|---|
| 系统 | Windows 10/11 x64 | `[System.Environment]::OSVersion` |
| PowerShell | 5.1（系统自带即可） | `$PSVersionTable.PSVersion` |
| Git | 任意较新版本 | `git --version` |
| Node.js | 18+，供 npm 安装 Codex CLI | `node --version` |
| Codex 桌面应用 | 已安装并用 ChatGPT 账号登录 | 打开应用能看到对话 |
| Codex CLI | >= 0.164 | `codex --version` |
| 网络 | 能访问 `chatgpt.com` | 见 2.2 |

### 2.1 安装 Codex CLI

```powershell
npm install -g @openai/codex@latest
codex --version
codex login status
```

`codex login status` 要显示 `Logged in using ChatGPT`。

### 2.2 代理

需要代理才能访问 `chatgpt.com` 时，把环境变量设成你的代理地址：

```powershell
$env:CODEX_PROXY = "http://你的代理地址:端口"
```

脚本投递 Codex 时会带上它。

---

## 三、安装

### 3.1 获取仓库

仓库公开，直接克隆即可。

### 3.2 一条命令安装

```powershell
git clone https://github.com/Morii013/codex-outsource.git "$env:TEMP\codex-outsource"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\codex-outsource\install.ps1" -ProjectsRoot "<项目根目录>"
```

### 3.3 install.ps1 逐步做了什么

1. 建 `%USERPROFILE%\.dsh\skills`。
2. 克隆仓库到 `%USERPROFILE%\.dsh\skills\codex-outsource`；已存在就 `git pull`。
3. 把 `aliases\co`、`aliases\cop` 复制到 `%USERPROFILE%\.dsh\skills\co`、`...\cop`。
4. 建项目根目录。
5. 往 `%USERPROFILE%\.dsh\AGENTS.md` 追加「/co 与 /cop（Codex 外包）」一节，含项目根目录和整轮一次工具调用等规则；已有则跳过。
6. 检查 `codex` 是否在 PATH、版本是否过旧、是否已登录。

参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DshHome` | `%USERPROFILE%\.dsh` | DSH 用户目录 |
| `-ProjectsRoot` | `%USERPROFILE%\projects` | 项目根目录，写入 AGENTS.md |
| `-RepoUrl` | 官方仓库地址 | 换成自己的 fork 时用 |
| `-SkipChecks` | 关 | 跳过 codex 检查 |

重复运行是安全的：会 `git pull`、覆盖 aliases、跳过已存在的 AGENTS 段落。

### 3.4 手动安装

```powershell
git clone https://github.com/Morii013/codex-outsource.git "$env:USERPROFILE\.dsh\skills\codex-outsource"
Copy-Item "$env:USERPROFILE\.dsh\skills\codex-outsource\aliases\co" "$env:USERPROFILE\.dsh\skills\co" -Recurse -Force
Copy-Item "$env:USERPROFILE\.dsh\skills\codex-outsource\aliases\cop" "$env:USERPROFILE\.dsh\skills\cop" -Recurse -Force
```

然后手动把第四节里的 AGENTS 段落加到 `%USERPROFILE%\.dsh\AGENTS.md`。

### 3.5 重开 DSH

技能只在会话启动时扫描。安装完重开一个 DSH 会话，技能列表里应出现 `codex-outsource`、`co`、`cop`。

---

## 四、安装后配置

### 4.1 AGENTS.md

`install.ps1` 会写入（示例）：

```markdown
## /co 与 /cop（Codex 外包）

用户输入 `/co` 或 `/cop` 时，不要再加载 skill 工具，按本节直接执行。

- 项目根目录：<你的项目根目录>
- 整轮只允许一次 pwsh 调用加一次回复。
- 任务书在同一条 pwsh 里用 `Set-Content` 写，不要用 write/edit 工具。
- `/co` 用 `-Auto -Record`；`/cop` 用 `-Auto -Record -Cwd`。只有用户明确要新对话才 `-New`。
- 验收接在同一条命令末尾；结果文件完整输出，不截断。
- 成功直接回复，失败才补一次排查。
- 复杂任务验收不通过就继续 `-Auto` 续同一对话再下令，循环到通过；简单任务可只验一次。
```

这一节决定 `/co`、`/cop` 的行为和 token 上限。

### 4.2 Codex 应用的审批模式

打开 Codex 应用设置，把审批模式设为「不询问 / never」，否则执行到需要确认的步骤会停住。

### 4.3 目录信任

新项目目录第一次打开会弹信任确认。脚本会往 `%USERPROFILE%\.codex\config.toml` 追加：

```toml
[projects.'<项目根目录>\project-022__xxx']
trust_level = "trusted"
```

应用若缓存配置，重启一次 Codex 生效。

### 4.4 模型

脚本默认 `gpt-6-sol`。账号不支持时用 `-Model` 或设 `CODEX_MODEL`。

---

## 五、验证安装

```powershell
# 1. 技能目录
Get-ChildItem "$env:USERPROFILE\.dsh\skills" | Where-Object Name -in 'codex-outsource','co','cop'

# 2. 脚本能加载（应提示缺少 -Dir、-Task）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\codex-outsource\scripts\codex-job.ps1"

# 3. Codex
codex --version
codex login status
```

全部通过后再试第一次 `/co`。

---

## 六、使用

### 6.1 两个入口

- `/co <任务>`：跑在“最近”，不建项目。
- `/cop <任务>`：项目任务，落在 `AGENTS.md` 配置的项目根目录。

### 6.2 默认续用

- 有 `work/codex/thread.json` 就续用同一个对话，没有就新建并记录。
- 后续指令、补充、修改一律 `-Auto` 或 `-Thread <id>`。
- 只有明确说“新对话/重新开一个”才用 `-New`。

### 6.3 参数

| 参数 | 作用 |
|---|---|
| `-Auto` | 读 `thread.json` 续用，没有则新建 |
| `-New` | 强制新建对话 |
| `-Cwd <目录>` | 在该目录下新建/续用（项目模式） |
| `-Record` | 把 thread id 写进 `work/codex/thread.json` |
| `-Thread <id>` | 指定已有对话 |
| `-Background` | headless 执行，不抢前台，线程仍进应用历史 |
| `-Image <png>` | 附图 |
| `-Verify '<命令>'` | 完成后跑验收命令并打印退出码 |
| `-Open` | 后台模式完成后用深链打开对话 |
| `-Model <名字>` | 覆盖模型 |
| `-Sandbox <模式>` | 默认 `workspace-write` |
| `-TimeoutSec <秒>` | 默认 900 |

---

## 七、运行时每一环

### 7.1 `/co` 一轮

1. DSH 收到 `/co`，按 `AGENTS.md` 不加载 skill。
2. DSH 发一次 PowerShell：建 `work\codex`、`Set-Content` 写 `01-task.md`、运行 `codex-app-job.ps1 -Auto -Record`。
3. 脚本读 `work\codex\thread.json`：
   - 没有 → 新建对话
   - 有 → 续用
4. 新建流程：
   - 记录 `%USERPROFILE%\.codex\session_index.jsonl` 里的现有 id
   - `Start-Process "codex://threads/new?path=<目录>"`（无 `-Cwd` 时省略 `?path`）
   - 等 5 秒让输入框就绪
   - 把 ChatGPT 切到前台（`AppActivate` + 强制置前，最多 6 次）
   - 校验前台进程是不是 `ChatGPT`，不是就退出（退出码 7）
   - 任务书放进剪贴板 → `Ctrl+V` → 回车
   - 轮询 `session_index.jsonl` 找新 id（25 秒 × 2 次，失败重发一次）
   - 定位 `sessions\YYYY\MM\DD\rollout-*-<id>.jsonl`
5. 续用流程：
   - 深链打开该对话，记下 rollout 当前长度
   - `codex queue --thread <id> --message <任务书>`，失败重试 10 次
6. 脚本每 2 秒读 rollout 尾部，直到出现 `task_complete`（本地文件读取，不消耗模型 token）。
7. 取 `last_agent_message` 写入结果文件，打印一行 `codex-app-job: ok thread=<id> result=<路径>`。
8. DSH 完整读取结果文件，验收，回复。
9. 验收不通过 → 回到第 2 步续用同一对话再下令，附失败原因，循环到通过。

### 7.2 `/cop` 一轮

1. 按 `AGENTS.md` 的项目根目录定位。
2. 三份规则文件（`AGENTS.md`、`全局工作台.md`、`新项目SOP.md`）用哈希缓存：内容没变不重读。
3. 取最大项目编号 +1，建 `project-NNN__name` 和标准子目录 `input/work/output/backup/docs/assets/data`。
4. 写 `work\codex\01-task.md`，运行 `codex-app-job.ps1 -Auto -Record -Cwd <项目>`。
5. 之后与 `/co` 相同；README 由 Codex 按 SOP 补。

### 7.3 后台模式

`-New -Background` 走 `codex-job.ps1`，即 `codex exec`：不抢前台，对话仍写进 `~/.codex/sessions`，会出现在应用历史里。

### 7.4 退出码

| 码 | 含义 |
|---|---|
| 2 | 参数或路径错误 |
| 3 | 等待超时 |
| 4 | 没解析到最终回答 |
| 6 | 找不到窗口或新对话没建出来 |
| 7 | 前台不是 ChatGPT，已中止 |

---

## 八、Token 规范

### 8.1 对 DSH（写进 AGENTS.md）

- 一轮只允许一次工具调用 + 一次回复。
- 任务书用 `Set-Content` 内联，不用 write/edit。
- 结果完整输出，不截断。
- 成功直接回复，失败才补一次排查。
- 复杂任务验收不通过就续同一对话再下令，循环到通过；简单任务可只验一次。

### 8.2 对使用者

- 一条消息把目标写全，不要来回补充。
- 简单任务直接做比 `/co` 便宜。
- 批量任务合并到一次 `/co`。
- 完成一批任务后开新会话。
- 只在需要派活和验收时用 DSH。

### 8.3 成本对照

| 方式 | 请求次数 | 相对成本 |
|---|---|---|
| Codex 应用里直接干 | 0 | 0 |
| DSH 只看结果验收 | 1 | 1× |
| `/co`（当前实现） | 2 | 2× |
| 旧 `/co`（加载 skill、单独写单、回读） | 4 | 4× |

每次返工再加 2 次请求。复杂任务必须循环到通过，简单任务允许一次验收结束。

---

## 九、故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `codex: command not found` | 未安装或不在 PATH | 安装 CLI，重开终端 |
| 模型不支持 | CLI 过旧或账号无此模型 | 升级 CLI；`-Model` 换可用模型 |
| 中文乱码、`The string is missing the terminator` | `.ps1` 丢了 BOM | 用带 BOM 的 UTF-8 重新保存 |
| 新对话没建出来 | 输入框未就绪、信任弹窗、应用不在前台 | 保持 ChatGPT 在前台；重启应用后再试 |
| 前台不是 ChatGPT（退出码 7） | 切窗口或激活被拦 | 运行期间不要切换窗口 |
| `queue` 失败 | Codex 应用没开 | 打开应用后重试 |
| 一直卡住 | 代理没开或地址不对 | 设置 `CODEX_PROXY` |
| 结果为空 | 任务书太模糊 | 看 `.log` 尾部，写清目标后重跑 |
| 重复弹信任 | 应用缓存了旧配置 | 重启 Codex 一次 |
| 图片没带上 | `queue` 不支持 `-i` | 续对话带图走应用内粘贴，脚本已处理 |

---

## 十、安全与边界

- 新建对话需要 ChatGPT 在前台；脚本粘前校验前台进程，不是 `ChatGPT` 立即中止。
- 前台校验与发送之间存在极小时间窗，运行期间不要操作鼠标键盘。
- 脚本会写 `~/.codex/config.toml` 的信任条目；只写当前项目目录。
- 不写入任何 key、token、账号信息到仓库。
- 删除类任务 Codex 会拒绝执行，改为移动或由 DSH 处理。
- 仓库公开，任何机器都可以直接克隆。

---

## 十一、平台差异

| 平台 | 应用通道 | 后台通道 | 状态 |
|---|---|---|---|
| Windows | `codex-app-job.ps1` | `codex-job.ps1` | 已实测（PS 5.1） |
| macOS/Linux | `codex-app-job.sh` | `codex-job.sh` | 保留原实现 |

---

## 十二、目录结构与文件职责

```text
install.ps1                   Windows 安装脚本
SKILL.md                      主 skill：流程、参数、限制
scripts/codex-app-job.ps1     A 通道：应用内新建/续用、前台守卫、自动信任
scripts/codex-job.ps1         B 通道：headless codex exec
scripts/codex-app-job.sh      A 通道（macOS/Linux）
scripts/codex-job.sh          B 通道（macOS/Linux）
aliases/co/SKILL.md           /co
aliases/cop/SKILL.md          /cop
README.md
```

运行时产生的文件：

| 文件 | 位置 | 作用 |
|---|---|---|
| `01-task.md` | `work/codex/` | 任务书 |
| `thread.json` | `work/codex/` | 记录对话 id，供 `-Auto` 续用 |
| `01-result.md` | `work/codex/` | Codex 最终回答 |
| `01.log` | `work/codex/` | 过程日志（失败时看） |

---

## 十三、升级与卸载

升级：

```powershell
git -C "$env:USERPROFILE\.dsh\skills\codex-outsource" pull
```

或重跑 `install.ps1`。

卸载：删除 `%USERPROFILE%\.dsh\skills\codex-outsource`、`co`、`cop`，并删掉 `AGENTS.md` 里「/co 与 /cop」一节。

---

## 十四、新电脑验收清单

- [ ] `git --version`、`node --version` 正常
- [ ] `codex --version` >= 0.164
- [ ] `codex login status` 显示 Logged in
- [ ] `install.ps1` 执行无报错
- [ ] `~/.dsh/skills` 下有 `codex-outsource`、`co`、`cop`
- [ ] `AGENTS.md` 里有「/co 与 /cop」一节，项目根目录正确
- [ ] 两个 `.ps1` 的 BOM 为 `239,187,191`
- [ ] `codex-job.ps1` 无参数运行时提示缺少 `-Dir/-Task`
- [ ] 重开 DSH 会话后技能列表出现三个技能
- [ ] Codex 应用审批模式为「不询问」
- [ ] 第一次 `/co` 能建对话、返回结果
- [ ] 第二次 `/co` 续用同一个对话
