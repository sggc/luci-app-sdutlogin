# luci-app-sdutlogin

山东理工大学（SDUT）校园网 Dr.COM 自动认证 OpenWrt LuCI 插件。

## 特性

- **加密 portal 协议**：AES-128-ECB 加密登录，与网页登录完全一致（非明文直连）
- **在线检测走外部网站**：访问 generate_204 端点判断在线/离线，不碰认证服务器，避免高频访问暴露自动化特征
- **多端点 fallback**：小米 → 华为 → vivo，增强稳定性
- **工作时段**：可设定仅在某时段内检测和登录，其余时间静默（支持跨午夜）
- **定时退出**：每天到指定时间自动注销账号（踢出登录），当天不再重新登录
- **退避机制**：连续登录失败可自定义退避阈值/间隔/停止重试
- **一键登录/下线**：LuCI 界面按钮即时操作
- **加密自动探测**：openssl → lua（aes.lua），双保障
- **WAN 口热插拔**：WAN 口 ifup 时自动触发登录检查
- **procd 进程管理**：自动 respawn，进程异常退出自动重启

## 与原版的区别

| 项 | 原版（BlackYau） | 本版 |
|---|---|---|
| 登录方式 | 明文直连，账号密码裸拼 URL | AES-128-ECB 加密 portal，与网页一致 |
| 在线检测 | curl google.cn/generate_204 | wget 小米/华为/vivo generate_204（多 fallback） |
| 依赖 | curl | openssl-util + luci-compat（或 lua5.1 + aes.lua） |
| 风控 | 在线时也访问认证服务器 | 在线时不碰认证服务器，只访问外部网站 |
| 退避 | 无 | 可配置退避阈值/间隔/停止重试 |
| 工作时段 | 无 | 可设定工作时段，其余静默 |
| 定时退出 | 无 | 每天定时注销，当天不重登 |
| 进程管理 | CGI 后台 `&`（易被杀） | procd respawn（稳定存活） |

## 安装

### 从 Release 下载

前往 [Releases](../../releases) 下载对应格式：

- **ipk**：OpenWrt 23.05 及更早版本（opkg 包管理）
- **apk**：OpenWrt 24.10+（ImmortalWrt/PonWrt 24.10 等，apk 包管理）

在 LuCI → 系统 → 文件传输 上传安装，或 SSH 执行：

```sh
# ipk 系统
opkg update && opkg install luci-app-sdutlogin_*.ipk

# apk 系统
apk add luci-app-sdutlogin-*.apk
```

### 使用

安装后在 LuCI → 网络 → SDUT 登录 → 基本设置：

1. 填入用户名（手机号）和密码
2. 点击启用
3. **工作时段**（可选）：设置后仅在该时段内检测和登录，其余时间静默。留空=全天工作。支持跨午夜（如 20:00-07:00 表示夜间工作）
4. **定时退出**（可选）：每天到此时间自动注销账号，当天不再重新登录
5. **退避机制**（可选）：连续失败 N 次后降低重试频率，避免频繁请求
6. 保存并应用

**快捷操作**：
- **一键登录**：立即执行登录（已在线则跳过）
- **一键下线**：立即注销当前账号
- **打开认证页/自助服务**：查看状态和管理设备

日志：LuCI → 网络 → SDUT 登录 → 运行日志，或 `/tmp/log/sdutlogin/sdutlogin.log`。

## 加密原理

认证服务器 `http://111.17.200.130/` 的前端 JS 使用 AES-128-ECB 加密登录参数：

```
AES-128-ECB，PKCS7 填充，密钥 "5c1d5ad4dea0e8dd"
明文 = JSON.stringify(登录参数)
输出 = base64(密文)，URL 编码后作为 params 参数
```

登录流程（与网页完全一致）：
1. `chkstatus`：老协议状态查询（可选，失败可继续）
2. `loadConfig`：签发 `rcn`（8 位随机码），建立页面会话
3. `queryPageSet`：多网点查询（逐字段加密）
4. `login`：加密登录参数，发送 `/eportal/portal/login?params=<密文>`
5. 响应 `{"result":1}` = 成功

注销流程：
- 构造注销 JSON（`user_account=drcom, user_password=123, ac_logout=0` 等）
- AES 加密后作为 `params` 参数发送 `/eportal/portal/logout`
- 响应 `{"result":1}` = 注销成功

## 依赖

- `openssl-util`（推荐，大多数固件自带）
- `luci-compat`（新版 LuCI ucode 架构需要，提供 CBI 框架 + Lua 运行时）
- 无 openssl 时可装 `lua5.1`（约 100KB），脚本自带 `aes.lua` 作为加密回退

## 从源码编译

```sh
# 在 OpenWrt 源码树中
cd package
git clone https://github.com/sggc/luci-app-sdutlogin.git
cd ..
make menuconfig  # LuCI -> Applications -> luci-app-sdutlogin 选 <M> 或 <*>
make package/luci-app-sdutlogin/compile -j1 V=s
```

## License

GPL-3.0
