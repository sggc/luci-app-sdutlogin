#!/bin/sh

# =============================================================================
# 山东理工大学校园网 Dr.COM 自动登录 - LuCI 插件版
# 加密 portal 协议（AES-128-ECB + loadConfig rcn），与网页登录完全一致
# 在线检测走外部 generate_204 端点，不碰认证服务器
#
# Copyright 2020 BlackYau <blackyau426@gmail.com>
# Copyright 2026 sggc
# GNU General Public License v3.0
# =============================================================================

dir="/tmp/log/sdutlogin/"
mkdir -p "$dir"
logfile="${dir}sdutlogin.log"
pidpath="${dir}run.pid"

HOST="111.17.200.130"
PORTAL_PORT="801"
AESKEY_HEX="35633164356164346465613065386464"   # "5c1d5ad4dea0e8dd" 的 hex
UA_LC="mozilla/5.0 (windows nt 10.0; win64; x64) applewebkit/537.36 (khtml, like gecko) chrome/120.0.0.0 safari/537.36"

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="."

# 从 uci 读配置
enable=$(uci -q get sdutlogin.@login[0].enable 2>/dev/null)
USERNAME=$(uci -q get sdutlogin.@login[0].username 2>/dev/null)
PASSWORD=$(uci -q get sdutlogin.@login[0].password 2>/dev/null)
interval=$(uci -q get sdutlogin.@login[0].interval 2>/dev/null)
[ -z "$interval" ] && interval=5
interval=$((interval * 60))

# 加密实现自动探测: openssl -> lua(同目录 aes.lua)
CRYPTO=""
LUA_BIN=""
if command -v openssl >/dev/null 2>&1; then
    CRYPTO="openssl"
else
    LUA_BIN=$(command -v lua5.1 2>/dev/null) || LUA_BIN=$(command -v lua 2>/dev/null) || LUA_BIN=""
    if [ -n "$LUA_BIN" ] && [ -f "$SCRIPT_DIR/aes.lua" ]; then
        CRYPTO="lua"
    fi
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$logfile"
}

fetch() {
    wget -q -T 6 -O - "$1" 2>/dev/null
}

urlencode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' -e 's/&/%26/g' -e 's/=/%3D/g' -e 's/?/%3F/g' \
        -e 's/#/%23/g' -e 's/+/%2B/g' -e 's|/|%2F|g' -e 's/ /%20/g' -e 's/"/%22/g'
}

b64() {
    case "$CRYPTO" in
        openssl) printf '%s' "$1" | openssl base64 -A 2>/dev/null | tr -d '\r\n\t ' ;;
        lua)     "$LUA_BIN" "$SCRIPT_DIR/aes.lua" b64 "$1" 2>/dev/null ;;
    esac
}

aes_b64() {
    case "$CRYPTO" in
        openssl) printf '%s' "$1" | openssl enc -aes-128-ecb -K "$AESKEY_HEX" -a 2>/dev/null | tr -d '\r\n' ;;
        lua)     "$LUA_BIN" "$SCRIPT_DIR/aes.lua" encrypt "$1" 2>/dev/null ;;
    esac
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 在线检测：外部 generate_204 端点，多 fallback（不碰认证服务器）
is_online() {
    local url body rc
    for url in \
        "http://connect.rom.miui.com/generate_204" \
        "http://connectivitycheck.platform.hicloud.com/generate_204" \
        "http://wifi.vivo.com.cn/generate_204"; do
        body=$(wget -q -T 5 -O - "$url" 2>/dev/null); rc=$?
        [ $rc -eq 0 ] && [ -z "$body" ] && return 0
    done
    return 1
}

# 抓认证服务器根页面取状态和 IP（仅在离线时调用，低频）
STATE=""
IP=""
get_state() {
    STATE="unreachable"; IP=""
    local page
    page=$(fetch "http://$HOST/")
    [ -z "$page" ] && return
    case "$(printf '%s' "$page" | grep -o 'Dr.COMWebLoginID_[0-9]\.htm' | head -n1)" in
        *1.htm) STATE=online ;;
        *0.htm) STATE=offline ;;
        *)      STATE=unknown; return ;;
    esac
    IP=$(printf '%s' "$page" | grep -o "v4ip='[0-9.]*'" | head -n1 | cut -d"'" -f2)
    case "$IP" in ""|"0.0.0.0"|"000.000.000.000")
        local chk
        chk=$(fetch "http://$HOST/drcom/chkstatus?callback=dr$$_ip&v=$$_&lang=zh")
        IP=$(printf '%s' "$chk" | grep -o '"ss5":"[0-9.]*"\|"v46ip":"[0-9.]*"' | head -n1 | sed 's/.*:"//; s/"$//')
        ;;
    esac
}

# 加密 portal 登录（openssl 或 lua；rcn 必须来自 loadConfig 签发）
try_portal() {
    [ -n "$CRYPTO" ] || { log "需要 openssl-util 或 lua(aes.lua) 加密，未找到"; return 1; }
    [ -n "$IP" ] || return 1
    local ipb64 cfg rcn inner enc resp pesc payload
    ipb64=$(b64 "$IP")
    [ -n "$ipb64" ] || return 1
    cfg=$(fetch "http://$HOST:$PORTAL_PORT/eportal/portal/page/loadConfig?callback=dr$$_cfg&program_index=&wlan_vlan_id=1&wlan_user_ip=$ipb64&wlan_user_ipv6=&wlan_user_ssid=&wlan_user_areaid=&wlan_ac_ip=&wlan_ap_mac=&gw_id=&jsVersion=4.2.1&v=$$_&lang=zh")
    rcn=$(printf '%s' "$cfg" | grep -o '"rcn":"[A-Za-z0-9]*"' | head -n1 | cut -d'"' -f4)
    [ -n "$rcn" ] || rcn=$(printf '%08d' $(( ($$ + $(date +%s)) % 100000000 )))
    inner=$(printf '{"account":"%s","wlan_user_ip":"%s","wlan_user_mac":"%s","user_agent":"%s","login_t":"%s"}' \
        "$(aes_b64 "$USERNAME")" "$(aes_b64 "$IP")" "$(aes_b64 '000000000000')" \
        "$(aes_b64 "$UA_LC")" "$(aes_b64 '0')")
    if [ -n "$inner" ]; then
        enc=$(aes_b64 "$inner")
        [ -n "$enc" ] && fetch "http://$HOST:$PORTAL_PORT/eportal/portal/duodian/queryPageSet?callback=dr$$_qps&params=$(urlencode "$enc")&jsVersion=4.2.1&v=$$_&lang=zh" >/dev/null
    fi
    pesc=$(json_escape "$PASSWORD")
    payload=$(printf '{"login_method":1,"user_account":",0,%s","user_password":"%s","wlan_user_ip":"%s","wlan_user_ipv6":"","wlan_user_mac":"000000000000","wlan_ac_ip":"","wlan_ac_name":"","jsVersion":"4.2.1","login_t":"0","js_status":"0","is_page":"1","is_page_new":%s,"terminal_type":1,"lang":"zh-cn","rcn":"%s"}' \
        "$USERNAME" "$pesc" "$IP" "$(( ($$ + $(date +%s)) % 9000 + 500 ))" "$rcn")
    enc=$(aes_b64 "$payload")
    [ -n "$enc" ] || { log "AES 加密失败"; return 1; }
    resp=$(fetch "http://$HOST:$PORTAL_PORT/eportal/portal/login?callback=dr$$_li&params=$(urlencode "$enc")&jsVersion=4.2.1&v=$$_&lang=zh")
    log "portal 响应: $(printf '%s' "$resp" | head -c 200)"
    case "$resp" in
        *'"result":1'*|*'"result":"1"'*) return 0 ;;
    esac
    return 1
}

do_login() {
    [ -n "$USERNAME" ] || { log "请先在 LuCI 界面填写用户名和密码"; return 1; }
    get_state
    if [ "$STATE" = "online" ]; then
        log "已在线（IP: $IP），跳过登录"
        return 0
    fi
    if [ "$STATE" != "offline" ]; then
        log "认证服务器不可达或状态异常: $STATE"
        return 1
    fi
    log "检测到离线（IP: $IP），开始登录 [加密: ${CRYPTO:-无}]"
    if try_portal && is_online; then
        log "登录成功"
        return 0
    fi
    log "登录失败"
    return 1
}

# 退避机制
BACKOFF_FILE="/tmp/.sdut_backoff"
BACKOFF_MAX=5
BACKOFF_SECS=1800

do_check() {
    if is_online; then
        return 0
    fi
    get_state
    case "$STATE" in
        online)
            : # 外部网站误报，实际在线
            ;;
        offline)
            local now cnt ts
            now=$(date +%s); cnt=0; ts=0
            [ -f "$BACKOFF_FILE" ] && read cnt ts < "$BACKOFF_FILE" 2>/dev/null
            if [ "${cnt:-0}" -ge "$BACKOFF_MAX" ] && [ $((now - ts)) -lt "$BACKOFF_SECS" ]; then
                log "已连续失败 ${cnt} 次，退避中（每 30 分钟重试一次）"
                return 1
            fi
            do_login
            if is_online; then
                rm -f "$BACKOFF_FILE"
            else
                echo "$((cnt + 1)) $now" > "$BACKOFF_FILE"
            fi
            ;;
        *)
            log "认证服务器不可达 ($STATE)"
            return 1
            ;;
    esac
}

reducelog() {
    [ -f "$logfile" ] && local logrow=$(grep -c "" "$logfile") || local logrow="0"
    [ "$logrow" -gt 500 ] && sed -i '1,100d' "$logfile" && log "日志超出上限(500行)，删除前 100 条"
}

# ---- 入口 ----
[ "$enable" != "1" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未启用,停止运行..." > "$logfile" && exit 0

# 进程管理：终止之前的实例
if [ -f "$pidpath" ]; then
    kill -9 "$(cat "$pidpath")" >/dev/null 2>&1
    rm -rf "$pidpath"
    sleep 1
fi
echo $$ > "$pidpath"
log "进程已启动 pid:$$ [加密: ${CRYPTO:-无}]"

# 主循环
while true; do
    do_check
    reducelog
    sleep "$interval"
done
