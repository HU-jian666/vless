# VLESS + REALITY 一键安装脚本

> 全自动、零交互、3 秒完成 · Fully automated, zero-interaction, done in ~3s

## 一键安装 / Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install.sh)
```

## 带参数运行 / With Parameters

```bash
# 自定义端口和伪装域名
bash install.sh --port 443 --domain www.bing.com

# 自定义 UUID
bash install.sh --uuid xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# 卸载
bash install.sh --uninstall
# 或
bash uninstall.sh
```

## 功能特性 / Features

| 功能 | 说明 |
|------|------|
| 零交互 | 全自动完成，无需手动输入 |
| 低内存适配 | ≤256MB RAM 自动创建 Swap |
| 多防火墙支持 | 自动识别 ufw / firewalld / iptables |
| BBR 加速 | 自动开启 TCP BBR 拥塞控制 |
| 随机端口 | 默认随机生成安全端口 |
| 密钥自动生成 | x25519 私钥/公钥 + Short ID 全自动 |
| 分享链接 | 安装完成输出 vless:// 链接 |
| 可重复运行 | 幂等设计，重装不留垃圾 |

## 系统要求 / Requirements

- **OS**: Debian / Ubuntu / CentOS / Alpine
- **权限**: root
- **内存**: 64MB+ (低内存自动 Swap)
- **网络**: 可访问 GitHub（或使用代理）

## 文件结构 / File Structure

```
.
├── install.sh      # 主安装脚本
├── uninstall.sh    # 卸载脚本
└── README.md
```

## 客户端配置 / Client Config

安装完成后复制输出的 `vless://` 链接，导入以下客户端：

- [v2rayN](https://github.com/2dust/v2rayN) (Windows)
- [v2rayNG](https://github.com/2dust/v2rayNG) (Android)  
- [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) (iOS)
- [Hiddify](https://github.com/hiddify/hiddify-next) (全平台)

## 免责声明 / Disclaimer

本项目仅供学习和研究网络技术使用，请遵守所在地区的法律法规。

---

*live free or die hard*
