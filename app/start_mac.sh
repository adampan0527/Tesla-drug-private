#!/usr/bin/env bash
# start_mac.sh — macOS 版一键部署 / 启停 / 状态脚本
#
# 用法：
#   ./start_mac.sh setup [--mirror]   # 创建 venv 并安装 macOS 依赖（首次运行）
#   ./start_mac.sh [start] [--ip IP]  # 启动 443 拦截 + DNS 53 + 看板 8900
#   ./start_mac.sh status             # 查看各组件状态
#   ./start_mac.sh stop               # 停止所有组件

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$ROOT/venv"
LOGS="$ROOT/logs"
REQ_MAC="$ROOT/requirements-mac.txt"

CMD="start"
OUR_IP=""
PANEL_PORT="8900"
REDIRECT_DOMAIN="api-prd.vn.cloud.tesla.cn"
USE_MIRROR=0

while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|status|setup)
      CMD="$1"
      shift
      ;;
    --ip)
      OUR_IP="${2:-}"
      shift 2
      ;;
    --port)
      PANEL_PORT="${2:-8900}"
      shift 2
      ;;
    --redirect)
      REDIRECT_DOMAIN="${2:-api-prd.vn.cloud.tesla.cn}"
      shift 2
      ;;
    --mirror)
      USE_MIRROR=1
      shift
      ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$LOGS"

detect_mac_ip() {
  local iface ip=""
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [ -n "$iface" ]; then
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    for i in en0 en1 en2; do
      ip="$(ipconfig getifaddr "$i" 2>/dev/null || true)"
      [ -n "$ip" ] && break
    done
  fi
  echo "$ip"
}

find_python() {
  local cand
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    [ -x "$cand" ] || continue
    if "$cand" -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

port_listening_tcp() {
  local port="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

proc_running() {
  local pattern="$1"
  pgrep -f "$pattern" >/dev/null 2>&1
}

do_setup() {
  local py
  py="$(find_python || true)"
  if [ -z "$py" ]; then
    echo "[FAIL] 未找到 Python >= 3.10（mitmproxy 需要 3.10+）。" >&2
    echo "       请先用 Homebrew 安装：brew install python@3.12" >&2
    exit 1
  fi
  echo "[setup] 使用 Python: $py ($("$py" --version))"
  if [ ! -d "$VENV" ]; then
    "$py" -m venv "$VENV"
  fi
  local pip_args=(-r "$REQ_MAC")
  if [ "$USE_MIRROR" -eq 1 ]; then
    pip_args+=(-i https://pypi.tuna.tsinghua.edu.cn/simple)
  fi
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/pip" install "${pip_args[@]}"
  echo "[OK] macOS 环境安装完成：$VENV"
}

do_status() {
  local ip s443 s53 s8900
  ip="${OUR_IP:-$(detect_mac_ip)}"
  port_listening_tcp 443 && s443="OK" || s443="DOWN"
  proc_running "dns_sink\.py" && s53="OK" || s53="DOWN"
  port_listening_tcp "$PANEL_PORT" && s8900="OK" || s8900="DOWN"

  echo ""
  echo "===== FSD 拦截环境 · macOS 状态 ====="
  printf "  %-14s %s\n" "443 拦截:" "$s443"
  printf "  %-14s %s\n" "DNS 53:" "$s53"
  printf "  %-14s %s\n" "看板 $PANEL_PORT:" "$s8900"
  printf "  %-14s %s\n" "本机 IP:" "${ip:-未检测到}"
  echo "======================================"
  echo "  看板: http://127.0.0.1:$PANEL_PORT"
  echo "  配置: http://127.0.0.1:$PANEL_PORT/config"
  if [ -n "$ip" ]; then
    echo "  车机 Wi-Fi DNS 请设为: $ip"
  fi
  echo ""
}

stop_pid_file() {
  local pid_file="$1"
  local label="$2"
  [ -f "$pid_file" ] || return 0
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || sudo kill "$pid" 2>/dev/null || true
    echo "[stop] 已停止 $label (pid=$pid)"
  elif [ -n "$pid" ] && sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill "$pid" 2>/dev/null || true
    echo "[stop] 已停止 $label (pid=$pid)"
  fi
  rm -f "$pid_file"
}

do_stop() {
  stop_pid_file "$LOGS/mitm-443.pid" "443 拦截"
  stop_pid_file "$LOGS/dns-53.pid" "DNS 53"
  stop_pid_file "$LOGS/panel-$PANEL_PORT.pid" "看板 $PANEL_PORT"

  # 兜底清理没有 pid 文件的残留进程
  local pat pids p
  for pat in "fsd_mock\.py" "dns_sink\.py" "fsd_panel\.py"; do
    pids="$(pgrep -f "$pat" 2>/dev/null || true)"
    for p in $pids; do
      kill "$p" 2>/dev/null || sudo kill "$p" 2>/dev/null || true
      echo "[stop] 清理残留进程 pid=$p ($pat)"
    done
  done
  echo "[OK] 已停止。"
}

do_start() {
  local mitm="$VENV/bin/mitmdump"
  local py="$VENV/bin/python"

  if [ ! -x "$mitm" ] || [ ! -x "$py" ]; then
    echo "[info] 未检测到 macOS venv，先执行安装..."
    do_setup
  fi

  if [ -z "$OUR_IP" ]; then
    OUR_IP="$(detect_mac_ip)"
  fi
  if [ -z "$OUR_IP" ]; then
    echo "[FAIL] 无法自动检测本机局域网 IP，请通过 --ip <IP> 指定。" >&2
    exit 1
  fi

  # 443 与 53 均为 macOS 特权端口，提前获取 sudo 凭据
  if [ "$(id -u)" -ne 0 ]; then
    if ! port_listening_tcp 443 || ! proc_running "dns_sink\.py"; then
      echo "[auth] 监听 443/53 端口需要管理员权限（sudo）："
      sudo -v || exit 1
    fi
  fi

  # 1) 443 反向拦截
  if port_listening_tcp 443; then
    echo "[skip] 443 端口已在监听"
  else
    local extra_args=()
    if "$mitm" --help 2>&1 | grep -q -- '--emudhra'; then
      extra_args+=(--emudhra)
    fi
    echo "[start] 启动 443 拦截..."
    sudo env \
      FSD_MOCK_JSON="$ROOT/payload.json" \
      FSD_MOCK_LOG_DIR="$LOGS" \
      FSD_MOCK_LOG_ALL=1 \
      FSD_MOCK_MODE_FILE="$ROOT/mode.json" \
      nohup "$mitm" \
        -s "$ROOT/fsd_mock.py" \
        --set "confdir=$ROOT/certs2" \
        --set "ssl_insecure=true" \
        --set "connection_strategy=lazy" \
        --set "block_global=false" \
        "${extra_args[@]}" \
        --mode "reverse:https://$REDIRECT_DOMAIN@443" \
        >"$LOGS/mitm-443.log" 2>&1 </dev/null &
    echo $! >"$LOGS/mitm-443.pid"
    sleep 3
  fi

  # 2) DNS 53 劫持
  if proc_running "dns_sink\.py"; then
    echo "[skip] dns_sink.py 已在运行"
  else
    if sudo lsof -nP -iUDP:53 >/dev/null 2>&1; then
      echo "[WARN] UDP 53 端口已被其他进程占用（如 macOS 互联网共享的 DNS 代理），dns_sink.py 可能启动失败。"
      sudo lsof -nP -iUDP:53 || true
    fi
    echo "[start] 启动 DNS 53 ($REDIRECT_DOMAIN -> $OUR_IP)..."
    sudo nohup "$py" "$ROOT/dns_sink.py" \
      --ip "$OUR_IP" \
      --redirect "$REDIRECT_DOMAIN" \
      >"$LOGS/dns-53.log" 2>&1 </dev/null &
    echo $! >"$LOGS/dns-53.pid"
    sleep 2
  fi

  # 3) 看板 8900
  if port_listening_tcp "$PANEL_PORT"; then
    echo "[skip] 看板 $PANEL_PORT 已在运行"
  else
    echo "[start] 启动看板 $PANEL_PORT..."
    nohup "$py" "$ROOT/web/fsd_panel.py" --port "$PANEL_PORT" \
      >"$LOGS/panel-$PANEL_PORT.log" 2>&1 </dev/null &
    echo $! >"$LOGS/panel-$PANEL_PORT.pid"
    sleep 2
  fi

  do_status
}

case "$CMD" in
  setup)  do_setup ;;
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
esac
