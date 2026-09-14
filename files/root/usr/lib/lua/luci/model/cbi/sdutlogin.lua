require("luci.sys")

m = Map("sdutlogin", translate("山理工校园网认证"), translate("加密 portal 协议自动登录，与网页登录完全一致"))

s = m:section(TypedSection, "login", "")
s.addremove = false
s.anonymous = true

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

o1 = s:option(Value, "backoff_max", translate("退避阈值"), translate("连续失败几次后进入退避模式，0=永不退避"))
o1.default = 5
o1.datatype = "min(0)"

o2 = s:option(Value, "backoff_secs", translate("退避间隔(秒)"), translate("退避模式下每次重试的间隔秒数"))
o2.default = 1800
o2.datatype = "min(60)"

o3 = s:option(Value, "backoff_stop", translate("停止重试"), translate("连续失败几次后永不重试（需手动重新启用），0=永不停止"))
o3.default = 0
o3.datatype = "min(0)"

success = s:option(DummyValue,"opennewwindow",translate("认证页面"))
success.description = translate("<input type=\"button\" class=\"cbi-button cbi-button-save\" value=\"打开认证页\" onclick=\"window.open('http://111.17.200.130/')\" /><input type=\"button\" class=\"cbi-button cbi-button-save\" value=\"打开自助服务\" onclick=\"window.open('http://111.17.200.130:8081/Self/login')\" /><br />可查看认证状态和管理在线设备")

local apply = luci.http.formvalue("cbi.apply")
if apply then
	io.popen("/etc/init.d/sdutlogin restart")
end

return m
