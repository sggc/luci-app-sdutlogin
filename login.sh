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

STATE_FILE="/tmp/sdutlogin.state"
COOKIE_FILE="/tmp/sdut_cookies"

HOST="111.17.200.130"
PORTAL_PORT="801"
AESKEY_HEX="35633164356164346465613065386464"   # "5c1d5ad4dea0e8dd" 的 hex
UA_LC="mozilla/5.0 (windows nt 10.0; win64; x64) appwebkit/537.36 (khtml, like gecko) chrome/152.0.0.0 safari/537.36 edg/152.0.0.0"
UA_HTTP="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Edg/152.0.0.0"

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="."

# 从 uci 读配置
enable=$(uci -q get sdutlogin.@login[0].enable 2>/dev/null)
USERNAME=$(uci -q get sdutlogin.@login[0].username 2>/dev/null)
PASSWORD=$(uci -q get sdutlogin.@login[0].password 2>/dev/null)
interval=$(uci -q get sdutlogin.@login[0].interval 2>/dev/null)
[ -z "$interval" ] && interval=5
interval=$((interval * 60))
quiet_start=$(uci -q get sdutlogin.@login[0].quiet_start 2>/dev/null)
quiet_end=$(uci -q get sdutlogin.@login[0].quiet_end 2>/dev/null)
logout_time=$(uci -q get sdutlogin.@login[0].logout_time 2>/dev/null)
wifi_off_start=$(uci -q get sdutlogin.@login[0].wifi_off_start 2>/dev/null)
wifi_off_end=$(uci -q get sdutlogin.@login[0].wifi_off_end 2>/dev/null)

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
    wget -q -T 6 -O - \
        --header="User-Agent: $UA_HTTP" \
        --header="Referer: http://$HOST/" \
        --load-cookies="$COOKIE_FILE" \
        --save-cookies="$COOKIE_FILE" \
        --keep-session-cookies \
        "$1" 2>/dev/null
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
    # chkstatus（老协议状态查询，与 Python page_init 一致，失败可继续）
    fetch "http://$HOST/drcom/chkstatus?callback=dr$$_chk&v=$$_&lang=zh" >/dev/null 2>&1
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
        "$USERNAME" "$pesc" "$IP" "$(( ($$ + $(date +%s)) % 10000 + 500 ))" "$rcn")
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

# 退避机制（从 uci 读，可自定义）
BACKOFF_FILE="/tmp/.sdut_backoff"
backoff_max=$(uci -q get sdutlogin.@login[0].backoff_max 2>/dev/null)
[ -z "$backoff_max" ] && backoff_max=5
backoff_secs=$(uci -q get sdutlogin.@login[0].backoff_secs 2>/dev/null)
[ -z "$backoff_secs" ] && backoff_secs=1800
backoff_stop=$(uci -q get sdutlogin.@login[0].backoff_stop 2>/dev/null)
[ -z "$backoff_stop" ] && backoff_stop=0

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
            # 永不重试检查
            if [ "$backoff_stop" -gt 0 ] && [ "${cnt:-0}" -ge "$backoff_stop" ]; then
                log "已连续失败 ${cnt} 次，达到上限 $backoff_stop，停止重试（需手动重新启用）"
                return 1
            fi
            # 退避检查
            if [ "$backoff_max" -gt 0 ] && [ "${cnt:-0}" -ge "$backoff_max" ] && [ $((now - ts)) -lt "$backoff_secs" ]; then
                log "已连续失败 ${cnt} 次，退避中（每 $((backoff_secs / 60)) 分钟重试一次）"
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

# 工作时段判断（支持跨午夜，如 20:00-07:00）
# 在工作时段内返回 1（不静默），在工作时段外返回 0（静默）
is_quiet() {
    [ -z "$quiet_start" ] || [ -z "$quiet_end" ] && return 1
    [ "$quiet_start" = "$quiet_end" ] && return 1
    local now_h now_m cur start_h start_m end_h end_m start end
    now_h=$(date +%H); now_m=$(date +%M)
    cur=$((now_h * 60 + now_m))
    start_h=${quiet_start%:*}; start_m=${quiet_start#*:}
    end_h=${quiet_end%:*}; end_m=${quiet_end#*:}
    start=$((start_h * 60 + start_m))
    end=$((end_h * 60 + end_m))
    if [ $start -le $end ]; then
        [ $cur -ge $start ] && [ $cur -lt $end ] && return 1
    else
        { [ $cur -ge $start ] || [ $cur -lt $end ]; } && return 1
    fi
    return 0
}

# 注销（踢出账号）：与 Python 版完全一致，AES 加密后作为 params 发送
do_logout() {
    get_state
    [ -n "$IP" ] || { log "注销失败：无法获取 IP"; return 1; }
    [ -n "$CRYPTO" ] || { log "注销需要加密支持 (openssl/lua)"; return 1; }
    local payload enc resp
    payload=$(printf '{"login_method":1,"user_account":"drcom","user_password":"123","ac_logout":0,"register_mode":0,"wlan_user_ip":"%s","wlan_user_ipv6":"","wlan_vlan_id":1,"wlan_user_mac":"000000000000","wlan_ac_ip":"","wlan_ac_name":"","jsVersion":"4.2.1"}' "$IP")
    enc=$(aes_b64 "$payload")
    [ -n "$enc" ] || { log "注销 AES 加密失败"; return 1; }
    resp=$(fetch "http://$HOST:$PORTAL_PORT/eportal/portal/logout?callback=dr$$_lo&params=$(urlencode "$enc")&jsVersion=4.2.1&v=$$_&lang=zh")
    log "注销响应: $(printf '%s' "$resp" | head -c 200)"
    case "$resp" in
        *'"result":1'*|*'"result":"1"'*)
            log "注销成功（已踢出账号）"
            return 0
            ;;
        *)
            log "注销失败"
            return 1
            ;;
    esac
}

# 定时退出检查：到点踢出账号，当天不重复
check_logout() {
    [ -z "$logout_time" ] && return
    local now_h now_m cur tgt_h tgt_m tgt today done_day
    now_h=$(date +%H); now_m=$(date +%M)
    cur=$((now_h * 60 + now_m))
    tgt_h=${logout_time%:*}; tgt_m=${logout_time#*:}
    tgt=$((tgt_h * 60 + tgt_m))
    [ $cur -lt $tgt ] && return
    today=$(date +%Y%m%d)
    done_day=""
    [ -f "$STATE_FILE" ] && done_day=$(grep -o "^logout_done=.*" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ "$today" = "$done_day" ] && return
    log "到达定时退出时间 $logout_time，执行注销"
    do_logout
    sed -i "/^logout_done=/d" "$STATE_FILE" 2>/dev/null
    echo "logout_done=$today" >> "$STATE_FILE"
}

# WiFi 定时关闭：在指定时段关闭 WiFi，时段外开启
WIFI_OFF_FLAG="/tmp/sdut_wifi_off"
check_wifi() {
    [ -z "$wifi_off_start" ] || [ -z "$wifi_off_end" ] && {
        if [ -f "$WIFI_OFF_FLAG" ]; then
            uci set wireless.radio0.disabled=0
            uci set wireless.radio1.disabled=0
            uci commit wireless
            wifi reload
            rm -f "$WIFI_OFF_FLAG"
            log "WiFi 已重新开启（未设置关闭时段）"
        fi
        return
    }
    [ "$wifi_off_start" = "$wifi_off_end" ] && return
    local now_h now_m cur start_h start_m end_h end_m start end in_range
    now_h=$(date +%H); now_m=$(date +%M)
    cur=$((now_h * 60 + now_m))
    start_h=${wifi_off_start%:*}; start_m=${wifi_off_start#*:}
    end_h=${wifi_off_end%:*}; end_m=${wifi_off_end#*:}
    start=$((start_h * 60 + start_m))
    end=$((end_h * 60 + end_m))
    in_range=0
    if [ $start -le $end ]; then
        [ $cur -ge $start ] && [ $cur -lt $end ] && in_range=1
    else
        { [ $cur -ge $start ] || [ $cur -lt $end ]; } && in_range=1
    fi
    if [ $in_range -eq 1 ]; then
        if [ ! -f "$WIFI_OFF_FLAG" ]; then
            uci set wireless.radio0.disabled=1
            uci set wireless.radio1.disabled=1
            uci commit wireless
            wifi reload
            touch "$WIFI_OFF_FLAG"
            log "WiFi 定时关闭（$wifi_off_start-$wifi_off_end）"
        fi
    else
        if [ -f "$WIFI_OFF_FLAG" ]; then
            uci set wireless.radio0.disabled=0
            uci set wireless.radio1.disabled=0
            uci commit wireless
            wifi reload
            rm -f "$WIFI_OFF_FLAG"
            log "WiFi 定时开启（关闭时段 $wifi_off_start-$wifi_off_end 外）"
        fi
    fi
}

# 状态文件读写
last_login_ts=0
load_state() {
    [ -f "$STATE_FILE" ] || return
    local v
    v=$(grep -o "^last_login=.*" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ -n "$v" ] && last_login_ts=$v
}

write_state() {
    local online=$1
    local today done_day
    today=$(date +%Y%m%d)
    done_day=""
    [ -f "$STATE_FILE" ] && done_day=$(grep -o "^logout_done=.*" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    cat > "$STATE_FILE" <<EOF
online=$online
last_check=$(date +%s)
last_login=$last_login_ts
logout_done=$done_day
EOF
}

reducelog() {
    [ -f "$logfile" ] && local logrow=$(grep -c "" "$logfile") || local logrow="0"
    [ "$logrow" -gt 500 ] && sed -i '1,100d' "$logfile" && log "日志超出上限(500行)，删除前 100 条"
}

# ---- 入口 ----
# logout 子命令：只执行注销，不进入主循环
case "$1" in
    logout)
        log "手动执行注销"
        do_logout
        exit $?
        ;;
    login)
        log "手动执行登录"
        do_login
        if is_online; then
            log "手动登录成功"
            exit 0
        fi
        log "手动登录失败"
        exit 1
        ;;
esac

[ "$enable" != "1" ] && {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未启用,停止运行..." > "$logfile"
    rm -f "$STATE_FILE"
    exit 0
}


load_state
log "进程已启动 pid:$$ [加密: ${CRYPTO:-无}]"

# 主循环
last_online=-1
while true; do
    # WiFi 定时关闭检查
    check_wifi

    # 定时退出检查（即使静默时段也执行，到点就踢）
    check_logout

    # 检查今天是否已踢出（踢出后当天不再登录）
    today=$(date +%Y%m%d)
    done_day=""
    [ -f "$STATE_FILE" ] && done_day=$(grep -o "^logout_done=.*" "$STATE_FILE" 2>/dev/null | cut -d= -f2)

    if [ "$today" = "$done_day" ]; then
        [ "$last_online" != "0" ] && log "今天已执行定时退出，暂停登录"
        write_state 0
        last_online=0
    elif is_quiet; then
        [ "$last_online" != "-2" ] && log "非工作时段（$quiet_start-$quiet_end 外），跳过检测"
        write_state 0
        last_online=-2
    else
        do_check
        if is_online; then
            [ "$last_online" != "1" ] && log "网络正常，已在线"
            last_login_ts=$(date +%s)
            write_state 1
            last_online=1
        else
            [ "$last_online" != "0" ] && log "网络异常，离线"
            write_state 0
            last_online=0
        fi
    fi

    reducelog
    # 分段 sleep，每分钟检查 enable 变化
    slept=0
    while [ $slept -lt $interval ]; do
        sleep 60
        slept=$((slept + 60))
        enable=$(uci -q get sdutlogin.@login[0].enable 2>/dev/null)
        [ "$enable" != "1" ] && {
            log "运行中被禁用，停止"
            rm -f "$STATE_FILE"
            exit 0
        }
    done
done
