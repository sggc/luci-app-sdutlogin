require("luci.sys")

m = Map("sdutlogin", translate("山理工校园网认证"), translate("加密 portal 协议自动登录，与网页登录完全一致"))

s = m:section(TypedSection, "login", "")
s.addremove = false
s.anonymous = true

-- 运行状态显示
stat = s:option(DummyValue, "_status", translate("运行状态"))
stat.rawhtml = true
stat.cfgvalue = function(self, section)
	local running = luci.sys.call("pgrep -f /usr/lib/sdutlogin/login.sh >/dev/null 2>&1") == 0
	local online = "unknown"
	local last_check = ""
	local f = io.open("/tmp/sdutlogin.state", "r")
	if f then
		for line in f:lines() do
			local k, v = line:match("^(%w+)=(.*)$")
			if k == "online" then online = v
			elseif k == "last_check" and v ~= "" then
				last_check = os.date("%H:%M:%S", tonumber(v) or 0)
			end
		end
		f:close()
	end
	local html = ""
	if not running then
		html = '<span style="color:#999;font-weight:bold">&#9679; 已停止</span>'
	elseif online == "1" then
		html = '<span style="color:#5cb85c;font-weight:bold">&#9679; 已启动 &#183; 在线</span>'
	elseif online == "0" then
		html = '<span style="color:#d9534f;font-weight:bold">&#9679; 已启动 &#183; 离线</span>'
	else
		html = '<span style="color:#999;font-weight:bold">&#9679; 已启动 &#183; 未知</span>'
	end
	if last_check ~= "" then
		html = html .. ' <span style="color:#999;font-size:12px">(检测于 ' .. last_check .. ')</span>'
	end
	return html
end

enable = s:option(Flag, "enable", translate("启用"), translate("启用后即会检测上网状态，并尝试自动拨号"))
enable.rmempty = false

name = s:option(Value, "username", translate("用户名(手机号)"))
name.rmempty = false
pass = s:option(Value, "password", translate("密码"))
pass.password = true
pass.rmempty = false

interval = s:option(Value, "interval", translate("检测间隔"), translate("每隔多少分钟检测一次网络状态，离线则自动登录"))
interval.default = 5
interval.datatype = "min(1)"

-- 静默时段（时间段停止检测）
quiet_start = s:option(Value, "quiet_start", translate("静默开始"), translate("在此时间段内停止检测和登录，留空=不启用。格式 HH:MM，如 23:00"))
quiet_start.placeholder = "HH:MM"
quiet_end = s:option(Value, "quiet_end", translate("静默结束"), translate("静默时段结束时间，支持跨午夜（如开始 23:00 结束 06:00）"))
quiet_end.placeholder = "HH:MM"

-- 定时退出（踢出账号）
logout_time = s:option(Value, "logout_time", translate("定时退出"), translate("每天到此时间自动注销账号（踢出登录），当天不再重新登录，留空=不启用。格式 HH:MM"))
logout_time.placeholder = "HH:MM"

-- 退避机制
o1 = s:option(Value, "backoff_max", translate("退避阈值"), translate("连续失败几次后进入退避模式，0=永不退避"))
o1.default = 5
o1.datatype = "min(0)"

o2 = s:option(Value, "backoff_secs", translate("退避间隔(秒)"), translate("退避模式下每次重试的间隔秒数"))
o2.default = 1800
o2.datatype = "min(60)"

o3 = s:option(Value, "backoff_stop", translate("停止重试"), translate("连续失败几次后永不重试（需手动重新启用），0=永不停止"))
o3.default = 0
o3.datatype = "min(0)"

-- 快捷链接（修复灰色按钮 + 排版）
links = s:option(DummyValue, "_links", translate("快捷链接"))
links.rawhtml = true
links.cfgvalue = function(self, section)
	return '<div style="margin:8px 0">'
		.. '<input type="button" class="btn cbi-button cbi-button-apply" style="margin-right:12px" value="打开认证页" onclick="window.open(\'http://111.17.200.130/\')" />'
		.. '<input type="button" class="btn cbi-button cbi-button-apply" value="打开自助服务" onclick="window.open(\'http://111.17.200.130:8081/Self/login\')" />'
		.. '</div>'
		.. '<div style="color:#888;font-size:12px">可查看认证状态和管理在线设备</div>'
end

local apply = luci.http.formvalue("cbi.apply")
if apply then
	luci.sys.call("/etc/init.d/sdutlogin restart; sleep 2")
end

return m
