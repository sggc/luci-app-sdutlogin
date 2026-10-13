-- Copyright 2020 BlackYau <blackyau426@gmail.com>
-- Copyright 2026 sggc
-- GNU General Public License v3.0


module("luci.controller.sdutlogin", package.seeall)

function index()
	entry({"admin", "network", "sdutlogin"}, firstchild(), _("SDUT 登录"), 100).dependent = false
	entry({"admin", "network", "sdutlogin", "general"}, cbi("sdutlogin"), _("基本设置"), 1)
	entry({"admin", "network", "sdutlogin", "log"}, form("sdutloginlog"), _("运行日志"), 2)
	entry({"admin", "services", "sdutlogin", "status"}, call("act_status")).leaf = true
end

function act_status()
	local s = {}
	s.running = luci.sys.call("pgrep -f /usr/lib/sdutlogin/login.sh >/dev/null 2>&1") == 0
	s.online = "unknown"
	s.last_check = ""
	local f = io.open("/tmp/sdutlogin.state", "r")
	if f then
		for line in f:lines() do
			local k, v = line:match("^(%w+)=(.*)$")
			if k == "online" then s.online = v
			elseif k == "last_check" and v ~= "" then
				s.last_check = os.date("%H:%M:%S", tonumber(v) or 0)
			end
		end
		f:close()
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json(s)
end