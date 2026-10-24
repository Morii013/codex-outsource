#!/usr/bin/env bash
# codex-job — 把一次任务外包给本机 Codex CLI（ChatGPT 订阅登录，不走 API key）。
# 用法: codex-job.sh --dir DIR --task TASK_FILE [--out OUT] [--log LOG] [--model M] [--resume SESSION] [--sandbox MODE]
# TASK/OUT/LOG 用相对路径时按 --dir 解析。成功时只把最终回答写进 OUT，过程写进 LOG。
set -uo pipefail

abs_in_dir() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$dir" "$1";; esac; }

dir=""; task=""; out=""; log=""; model="${CODEX_MODEL:-gpt-6-sol}"; resume=""; sandbox="workspace-write"
while (( $# )); do
  case "$1" in
    --dir) dir="$2"; shift 2;;
    --task) task="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    --log) log="$2"; shift 2;;
    --model) model="$2"; shift 2;;
    --resume) resume="$2"; shift 2;;
    --sandbox) sandbox="$2"; shift 2;;
    -h|--help) sed -n '2,4p' "$0"; exit 0;;
    *) echo "codex-job: unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -n "$dir" && -n "$task" ]] || { echo "codex-job: --dir and --task are required" >&2; exit 2; }
[[ -d "$dir" ]] || { echo "codex-job: no such dir: $dir" >&2; exit 2; }
task="$(abs_in_dir "$task")"
[[ -f "$task" ]] || { echo "codex-job: no such task file: $task" >&2; exit 2; }
out="$(abs_in_dir "${out:-$task.out.md}")"
log="$(abs_in_dir "${log:-$task.log}")"
mkdir -p "$(dirname "$out")" "$(dirname "$log")" || exit 2

# 需要代理时由 CODEX_PROXY 提供
proxy="${CODEX_PROXY:-}"
if [[ -n "$proxy" ]]; then export HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" ALL_PROXY="$proxy"; fi

cd "$dir" || exit 2
if [[ -n "$resume" ]]; then
  # resume 子命令没有 -s，用 config 覆盖同样的沙箱策略，否则默认只读
  codex exec resume "$resume" --skip-git-repo-check -m "$model" -c "sandbox_mode=\"$sandbox\"" -o "$out" - < "$task" > "$log" 2>&1
else
  codex exec --skip-git-repo-check -s "$sandbox" -m "$model" -o "$out" - < "$task" > "$log" 2>&1
fi
rc=$?
sid="$(sed -n 's/^session id: //p' "$log" | head -1)"
echo "codex-job: exit=$rc session=${sid:-?} result=$out"
if (( rc != 0 )); then
  echo "--- tail of log ---"
  tail -n 8 "$log"
  # 额度窗口提示（月度订阅按 5 小时滚动）
  if grep -Eiq 'usage limit|rate limit|rate_limit|usageLimitExceeded|quota exceeded' "$log"; then
    echo "codex-job: 疑似撞上 Codex 额度窗口，等 5 小时窗口重置后再派，或先跑小任务。"
  fi
fi
exit "$rc"
