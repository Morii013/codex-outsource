#!/usr/bin/env bash
# codex-app-job — 把任务投给 Codex 应用（可新建对话），等它跑完，只输出最终回答。
# 用法:
#   codex-app-job.sh --task TASK --thread <会话id或名字> [--out OUT] [--image IMG ...]
#   codex-app-job.sh --task TASK --new [--cwd 项目目录] [--out OUT] [--image IMG ...]
# 相对路径按当前目录解析。成功时最终回答写入 OUT，退出码 0。
set -uo pipefail

thread=""; task=""; out=""; limit=900; is_new=0; cwd=""; verify=""; record=0; auto=0; images=()
while (( $# )); do
  case "$1" in
    --thread) thread="$2"; shift 2;;
    --new) is_new=1; shift;;
    --cwd) cwd="$2"; shift 2;;
    --verify) verify="$2"; shift 2;;
    --record) record=1; shift;;
    --auto) auto=1; shift;;
    --task) task="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    --image|-i) images+=("$2"); shift 2;;
    --timeout) limit="$2"; shift 2;;
    -h|--help) sed -n '2,7p' "$0"; exit 0;;
    *) echo "codex-app-job: unknown argument: $1" >&2; exit 2;;
  esac
done
if (( auto )) && [[ -z "$thread" ]] && (( is_new == 0 )); then
  if [[ -f work/codex/thread.json ]]; then
    thread="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' work/codex/thread.json 2>/dev/null)"
  fi
  [[ -n "$thread" ]] || is_new=1
fi
[[ -f "$task" ]] || { echo "codex-app-job: no such task file: $task" >&2; exit 2; }
[[ -n "$thread" || $is_new -eq 1 ]] || { echo "codex-app-job: give --thread or --new" >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "codex-app-job: 应用通道目前只支持 macOS" >&2; exit 2; }
out="${out:-$task.out.md}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
db="$(ls "$codex_home"/state_*.sqlite 2>/dev/null | sort -V | tail -1)"
[[ -n "$db" ]] || { echo "codex-app-job: 找不到 Codex 状态数据库" >&2; exit 2; }

press() { osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1; }

if [[ "$(osascript -e 'tell application "System Events" to get UI elements enabled' 2>/dev/null)" != "true" ]]; then
  echo "codex-app-job: 需要辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能 → DeepSeek Harness）" >&2
  exit 5
fi

find_rollout() { ls "$codex_home"/sessions/*/*/*/rollout-*"$1"*.jsonl 2>/dev/null | head -1; }

# 读 rollout 里最后一条 task_complete 的最终回答
last_answer() {
  python3 -c '
import json, sys
message = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: row = json.loads(line)
    except Exception: continue
    payload = row.get("payload") or {}
    if payload.get("type") == "task_complete":
        message = payload.get("last_agent_message")
if message is not None:
    sys.stdout.write(message)
' "$1"
}

wait_done() { # $1 rollout path
  local started; started="$(date +%s)"
  while :; do
    if (( $(date +%s) - started > limit )); then
      echo "codex-app-job: 等待超时（${limit}s）" >&2
      exit 3
    fi
    if grep -q '"type":"task_complete"' "$1" 2>/dev/null; then break; fi
    sleep 2
  done
  local answer; answer="$(last_answer "$1")"
  [[ -n "$answer" ]] || { echo "codex-app-job: 没解析到最终回答" >&2; exit 4; }
  printf '%s\n' "$answer" > "$out"
}

if (( is_new )); then
  if [[ -n "$cwd" ]]; then
    [[ -d "$cwd" ]] || { echo "codex-app-job: 目录不存在: $cwd" >&2; exit 2; }
    codex app "$cwd" >/dev/null 2>&1 || { echo "codex-app-job: codex app 失败" >&2; exit 1; }
    sleep 3
  fi
  before="$(mktemp)"; sqlite3 "$db" "select id from threads;" > "$before"
  open "codex://threads/new" || { echo "codex-app-job: 打不开新对话" >&2; exit 1; }
  sleep 2
  osascript -e 'tell application "ChatGPT" to activate' >/dev/null 2>&1
  sleep 1
  for img in ${images[@]+"${images[@]}"}; do
    [[ -f "$img" ]] || { echo "codex-app-job: 图片不存在: $img" >&2; exit 2; }
    osascript -e "set the clipboard to (read (POSIX file \"$img\") as «class PNGf»)" >/dev/null 2>&1
    press 'keystroke "v" using command down'
    sleep 1
  done
  pbcopy < "$task"
  press 'keystroke "v" using command down'
  sleep 0.5
  press 'key code 36'

  id=""
  started="$(date +%s)"
  while :; do
    if (( $(date +%s) - started > 20 )); then
      echo "codex-app-job: 新对话没有创建出来（检查应用是否在前台、输入框是否聚焦）" >&2
      exit 6
    fi
    id="$(sqlite3 "$db" "select id from threads;" | grep -v -x -F -f "$before" | head -1)"
    [[ -n "$id" ]] && break
    sleep 1
  done
  rm -f "$before"
  rollout=""
  while [[ -z "$rollout" ]]; do rollout="$(find_rollout "$id")"; sleep 1; done
  wait_done "$rollout"
  echo "codex-app-job: ok thread=$id result=$out"
  if (( record )); then
    mkdir -p work/codex 2>/dev/null && printf '{"id":"%s"}\n' "$id" > work/codex/thread.json && echo "codex-app-job: recorded=work/codex/thread.json"
  fi
else
  id="$thread"
  if [[ "$thread" != *-*-*-*-* ]]; then
    id="$(python3 - "$codex_home/session_index.jsonl" "$thread" <<'PY' 2>/dev/null
import json, sys
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try: row = json.loads(line)
        except Exception: continue
        if row.get("thread_name") == sys.argv[2]:
            print(row["id"]); break
except FileNotFoundError:
    pass
PY
)"
    [[ -n "$id" ]] || { echo "codex-app-job: 找不到会话: $thread" >&2; exit 2; }
  fi
  rollout="$(find_rollout "$id")"
  [[ -n "$rollout" ]] || { echo "codex-app-job: 找不到会话文件: $id" >&2; exit 2; }
  open "codex://threads/$id" >/dev/null 2>&1 || true
  sleep 2
  base="$(wc -c < "$rollout" | tr -d ' ')"
  args=(--thread "$id" --message "$(cat "$task")")
  for img in ${images[@]+"${images[@]}"}; do args+=(--image "$img"); done
  queued=0
  for _ in $(seq 1 10); do
    if codex queue "${args[@]}" >/dev/null 2>&1; then queued=1; break; fi
    sleep 1
  done
  (( queued )) || { echo "codex-app-job: queue 失败" >&2; exit 1; }
  started="$(date +%s)"
  while :; do
    if (( $(date +%s) - started > limit )); then
      echo "codex-app-job: 等待超时（${limit}s）" >&2
      exit 3
    fi
    if tail -c +$((base + 1)) "$rollout" 2>/dev/null | grep -q '"type":"task_complete"'; then break; fi
    sleep 2
  done
  tail -c +$((base + 1)) "$rollout" | python3 -c '
import json, sys
message = None
for line in sys.stdin:
    try: row = json.loads(line)
    except Exception: continue
    payload = row.get("payload") or {}
    if payload.get("type") == "task_complete":
        message = payload.get("last_agent_message")
if message is None: sys.exit(4)
open(sys.argv[1], "w", encoding="utf-8").write(message + "\n")
' "$out" || { echo "codex-app-job: 没解析到最终回答" >&2; exit 4; }
  echo "codex-app-job: ok thread=$id result=$out"
fi

if [[ -n "$verify" ]]; then
  echo "--- verify ---"
  ( cd "${cwd:-$PWD}" 2>/dev/null; bash -lc "$verify" ) 2>&1 | tail -n 20
  echo "verify_exit=${PIPESTATUS[0]}"
fi
