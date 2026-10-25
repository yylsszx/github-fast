# GitHub Fast — Windows 一键 GitHub 全套加速

直连 GitHub 时好时坏（页面转圈、`git clone` 卡死、push 超时），而手头已有的本地 socks5 代理
（wireproxy/WARP、clash、v2ray 等）访问 GitHub 却很稳。这个工具把差距补上：**让所有 GitHub 流量
自动走你本地的 socks5 代理，其它网站和 git 服务完全不受影响**。

## 覆盖通道

| 通道 | 方式 |
|---|---|
| 浏览器（Edge/Chrome 等 Chromium 系） | 系统级 PAC 分流，仅 GitHub 域名走 socks5 |
| git https（clone / push / release 下载） | `git config --global http.https://github.com.proxy` 等 4 条 |
| git ssh（`git@github.com`） | `~/.ssh/config` 自动改为 ssh.github.com:443 + socks5 |
| gh / curl / wget | 终端 `ghfast on` / `ghfast off` 开关（PowerShell + Git Bash） |

外加两个保活机制：

- **开机自启**（HKCU Run，隐藏窗口）拉起 wireproxy，代理不再"重启电脑就没了"；
- **隧道自愈**：WARP 隧道会静默断流（端口还在监听但流量黑洞），`on` / `install`
  会做真实健康探测，发现断流自动重启 wireproxy，失败自动重试。

## 安装

```powershell
git clone https://github.com/yylsszx/github-fast.git
cd github-fast
.\install.bat        # 或: powershell -ExecutionPolicy Bypass -File gh-fast.ps1 -Action install
```

`install` 做的事（全部幂等，可重复执行）：

1. 探测本地 socks5 代理（默认 `127.0.0.1:25344`，也自动尝试 7890/7897/1080/10808/10809/2080）；
   探测不到且存在 wireproxy（WARP）时自动拉起并做健康检查；
2. 生成 `github.pac` 并设为系统代理（仅 GitHub 域名分流）；
3. 配置 git 全局代理（仅 4 个 GitHub 域名）；
4. 修改 `~/.ssh/config`：github.com 走 ssh.github.com:443 + socks5（带标记注释，4 行，易删）；
5. 向 `.bashrc` / PowerShell profile 追加 `ghfast` 开关函数（带标记块）；
6. 注册 wireproxy 开机自启 + 创建桌面快捷方式「GitHub Fast」。

## 日常使用

- 双击桌面 **GitHub Fast**（或 `GitHub-Fast-On.bat`）：确保代理健康 → 启用分流 → 打开 github.com
- `GitHub-Fast-Status.bat`：全套通道状态 + 直连/代理延迟对比
- `GitHub-Fast-Off.bat`：临时关闭浏览器分流
- `uninstall.bat`：一键回滚以上所有改动（不动代理进程本身）

## 卸载

```powershell
.\uninstall.bat
```

## 已知边界

- 需要 Windows 10+ 自带的 PowerShell 5.1 与 curl.exe；无需管理员权限。
- git 的 https/ssh 代理是常驻配置：若哪天 git 报 `Failed to connect to 127.0.0.1 port xxxx`，
  说明本地代理进程没在跑——双击 GitHub Fast 即可自动拉起/自愈。
- 浏览器 PAC 对 Chromium 系（Edge/Chrome/WebView2）效果最好；PowerShell 的
  `Invoke-WebRequest`（WinINET）对 PAC 里的 SOCKS5 支持较差，测速请用浏览器或 `curl -x`。
- git ssh 通道要求公钥已添加到 GitHub 账户（`gh ssh-key add ~/.ssh/id_ed25519.pub`）；
  未添加也不影响 https 方式。
- 本工具只做流量分流，不提供代理本体；请确保你使用代理的行为符合当地法规。

## License

[MIT](LICENSE)
