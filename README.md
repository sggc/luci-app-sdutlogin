# luci-app-sdutlogin

山东理工大学（SDUT）校园网 Dr.COM 自动认证 OpenWrt LuCI 插件。

## 特性

- **加密 portal 协议**：AES-128-ECB 加密登录，与网页登录完全一致（非明文直连）
- **在线检测走外部网站**：访问 generate_204 端点判断在线/离线，不碰认证服务器，避免高频访问暴露自动化特征
- **多端点 fallback**：小米 → 华为 → vivo，增强稳定性
- **退避机制**：连续登录失败 5 次后自动退避为每 30 分钟一次，不会无限重试
- **加密自动探测**：openssl → lua（aes.lua），双保障
- **WAN 口热插拔**：WAN 口 ifup 时自动触发登录检查

## 与原版的区别

| 项 | 原版（BlackYau） | 本版 |
|---|---|---|
| 登录方式 | 明文直连，账号密码裸拼 URL | AES-128-ECB 加密 portal，与网页一致 |
| 在线检测 | curl google.cn/generate_204 | wget 小米/华为/vivo generate_204（多 fallback） |
| 依赖 | curl | openssl-util（或 lua5.1 + aes.lua） |
| 风控 | 在线时也访问认证服务器 | 在线时不碰认证服务器，只访问外部网站 |
| 退避 | 无 | 连续失败 5 次退避 30 分钟 |

## 安装

### 从 Release 下载

前往 [Releases](../../releases) 下载对应格式：

- **ipk**：OpenWrt 23.05 及更早版本（opkg 包管理）
- **apk**：OpenWrt 24.10+（ImmortalWrt 24.10 等，apk 包管理）

在 LuCI → 系统 → 文件传输 上传安装，或 SSH 执行：

```sh
# ipk 系统
opkg update && opkg install luci-app-sdutlogin_*.ipk

# apk 系统
apk add luci-app-sdutlogin-*.apk
```

### 使用

安装后在 LuCI → 网络 → SDUT Login：
1. 填入用户名（手机号）和密码
2. 点击启用
3. 保存并应用

日志：LuCI → 网络 → SDUT Login → 日志，或 `/tmp/log/sdutlogin/sdutlogin.log`。

## 加密原理

认证服务器 `http://111.17.200.130/` 的前端 JS 使用 AES-128-ECB 加密登录参数：

```
AES-128-ECB，PKCS7 填充，密钥 "5c1d5ad4dea0e8dd"
明文 = JSON.stringify(登录参数)
输出 = base64(密文)，URL 编码后作为 params 参数
```

登录流程：
1. `loadConfig` 签发 `rcn`（8 位随机码）
2. 加密登录参数，发送 `/eportal/portal/login?params=<密文>`
3. 响应 `{"result":1}` = 成功

注销字段固定 `user_account=drcom, user_password=123`，真正起作用的是来源 IP。

## 依赖

- `openssl-util`（推荐，大多数固件自带）
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
