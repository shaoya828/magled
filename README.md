# MagLED

**MagSafe 3 充电指示灯控制工具**（菜单栏 App + 后台守护 + 命令行）

充电时 MagSafe 3 接口的 LED 常亮（绿灯/橙灯），夜里一宿刺眼。MagLED 让你一键把灯关掉、强制改色，或设定"夜间关灯计划"——**灯是纯装饰，关掉不影响充电**。

- 🌑 **一键关灯** / 常亮绿 / 常亮橙 / 常亮+闪烁
- 🌗 **跟随系统**：默认状态，LED 行为交还给系统（省电暗灯逻辑）
- 🕐 **夜间计划**：比如 23:00 自动关灯、07:00 恢复跟随系统，插电过夜不再被灯亮着
- 🔁 **后台守护**：重启、插拔充电线、睡眠唤醒后依然保持你设的状态
- 🔋 **固件信息**：菜单栏直接查看 MagSafe 3 线缆固件版本（只读；电源口/驱动版本作为参考行一并列出）
- 🖥️ **命令行**：`ledctl`（关灯/开灯/探测）、`probe`（开发用 SMC 只读探测）

> 仅支持 **Apple Silicon** 且带 **MagSafe 3 接口** 的 Mac（macOS 13+）。Intel 机器、纯 USB-C 机器会显示"不支持"，不会做任何事。

---

## ⚠️ 风险与安全说明（请先读）

MagLED 通过 Apple 未公开文档的 **SMC（System Management Controller）密钥** 控制 LED。它不是 Apple 官方工具，使用前请了解以下事实：

### 1. 它到底改了什么？
- **只写一个密钥**：`ACLC`（4 字符 SMC key），1 个字节，含义是 MagSafe 3 接口的 LED 显示模式。
- **不碰**电源管理、电池、散热、充电协议、电源按钮等任何其他 SMC 密钥。
- 写入白名单只有 7 个合法值（关/绿/橙/闪烁变体/跟随系统），非法输入一律拒绝。

### 2. 最坏情况会怎样？
- LED 指示灯是**纯装饰**。实测确认：关灯后充电、充电状态显示、合盖/充电行为**全部正常**。
- 如果未来 macOS 更新改变了该密钥的语义，最坏结果是"写入失败"或灯显示异常——**不影响充电安全**。程序会明确提示"设置失败"。
- 随时可一键恢复"跟随系统"，把控制权交回。

### 3. root 后台守护
- Apple Silicon 上写 SMC **必须 root**，所以安装"后台守护"需要输入一次管理员密码。
- 守护进程（`magled-helper`）是几十行的极简 C 风格程序，**源码就在本仓库，可自行审计**：
  - 只监听本机 Unix socket（`/var/run/magled.sock`，权限 `660 root:wheel`，仅管理员可访问）；
  - 每 20 秒**读**一次 LED 状态，**发现漂移才写**，不持续写；
  - 状态持久化在 `/var/root/.magled_mode`，日志在 `/var/log/magled.log`。
- **如果你介意 root 程序，可以不装守护**：菜单栏"一键关灯"依然能用，只是重启/插拔充电线后灯会恢复系统默认，需要再点一次。

### 4. 隐私
- **零网络**：无网络请求、无遥测、无数据收集、无任何账号体系。代码里没有任何联网调用，可自行验证。

### 5. 签名与 Gatekeeper
- 仓库提供的预编译包（Release 附件）是 **ad-hoc 签名**，没有 Apple 开发者账号公证。从 GitHub 下载后 macOS 会拦截（提示"已损坏"或"无法验证开发者"）。
- 两种解法：
  1. **右键 MagLED.app → 打开**（推荐，首次一次即可）；
  2. **从源码自己构建**（见下文）——本机构建的包不带隔离标记，永远不会弹警告。

### 6. 免责声明
本项目仅供技术研究使用，非 Apple 产品。作者对任何直接或间接的使用后果不承担责任。使用即代表你已阅读并理解上述风险。

---

## 使用方法

### A. 菜单栏 App

1. 获取：下载 [Release](../../releases) 里的 `MagLED.dmg`，或从源码构建（见下）。
2. 解压后把 **MagLED** 拖进"应用程序"。首次启动：
   - **右键 → 打开**（ad-hoc 签名需要这一步，系统提示后点"打开"即可）；
   - 自己构建的版本直接双击。
3. 点菜单栏图标，菜单说明：
   | 菜单项 | 效果 |
   |---|---|
   | 一键关灯 | LED 熄灭（充电正常） |
   | 常亮绿 / 常亮橙 / 常亮+闪烁 | 强制改色 |
   | 跟随系统 | 恢复系统默认 LED 行为（推荐用这个"还原"） |
   | 夜间计划 | 设定"几点关灯、几点恢复"，可开关 |
   | 安装/卸载后台守护 | 需要一次管理员密码 |
   | 固件版本 | 主显示线缆固件（★）；电源口固件、驱动版本作为参考行（只读，ioreg 原始格式） |
4. **要让"关灯"在重启后依然生效，必须安装后台守护**（菜单 → 安装后台守护 → 输密码）。状态会跨重启保持。

> 菜单顶部会显示当前机器是否支持。如果你的 Mac 没有 MagSafe 3 接口（如 13" M1 MacBook Air/Pro、Studio 等），会显示"不支持"，其余菜单项置灰。

### B. 命令行（适合脚本/自动化）

```bash
# 从源码构建后（build/bin/）：
./ledctl off           # 关灯
./ledctl on            # 恢复系统默认
./ledctl probe         # 打印 SMC 密钥支持情况（只读）

# 或一次性命令行关灯（需要先装后台守护）：
sudo sh install.sh
```

### C. 故障排查

| 现象 | 处理 |
|---|---|
| 菜单显示"不支持" | 你的 Mac 没有 MagSafe 3 接口，本工具不适用 |
| 点了关灯没反应 | ① 装后台守护了吗？② 确认插的是 MagSafe 3 线（苹果原装或 MFi 认证的磁吸口线）③ 菜单栏"固件版本"能否读到线缆信息 |
| 重启后灯又亮了 | 没装后台守护，或安装时没输对密码（见 `/var/log/magled.log`） |
| 系统更新后失效 | 新版 macOS 可能改了 SMC 密钥，更新日志里会说明；一般重新执行一次"跟随系统→关灯"即可 |

### D. 卸载

```bash
sudo sh uninstall.sh   # 或 菜单 → 卸载后台守护
```

会移除：守护进程、`/usr/local/lib/magled`、`/Library/LaunchDaemons/com.atstudio.magled.plist`、socket、状态文件、日志、`/Applications/MagLED.app`。卸载后 LED 自动交还系统控制。
彻底清理（可选）：`defaults delete com.atstudio.magled`

---

## 从源码构建

要求：Apple Silicon Mac + macOS 13+ + Xcode Command Line Tools。

```bash
xcode-select --install        # 如未安装
git clone https://github.com/<你的用户名>/magled.git
cd magled
./build.sh
```

产物：

| 文件 | 说明 |
|---|---|
| `build/MagLED.app` | 菜单栏 App（本机构建，无 Gatekeeper 警告） |
| `build/bin/ledctl` | 命令行控制 |
| `build/bin/magled-helper` | root 后台守护 |
| `build/bin/probe` | 开发用 SMC/IOKit 只读探测 |

安装后台守护：`sudo sh install.sh`（或从 App 菜单里装）。

### 目录结构

```
src/
  SMC.swift        # AppleSMC IOKit 客户端（改自 MagSleep，MIT）
  Fw.swift         # 固件/线缆信息发现（只读 ioreg 扫描）
  Sock.swift       # Unix socket 协议客户端
  app/             # 菜单栏 App（AppKit）
  cli/             # ledctl 命令行
  helper/          # magled-helper root 守护
```

---

## 工作原理（简述）

1. **SMC 密钥 `ACLC`**：MagSafe 3 接口的 LED 模式寄存器（1 字节）。读取用 `SMCUserClient` 的 `SMCKeyData` 结构体调用；Apple Silicon 上写操作需要 root。
2. **状态持久化**：守护进程把目标模式写在 `/var/root/.magled_mode`，开机/唤醒/插拔时重新断言。
3. **漂移看门狗**：守护进程每 20 秒读一次当前值，与期望值不同才写（系统会在重新插电时把灯改回默认色）。
4. **App ↔ 守护**：Unix socket（`/var/run/magled.sock`），协议为单行请求/单行响应：`ping` / `get` / `set <hex>` → `OK <hex>` 或 `ERR <原因>`。

### Sock 协议参考

| 请求 | 响应 |
|---|---|
| `ping` | `OK 1.0` |
| `get` | `OK <当前模式hex>` |
| `set 00` | `OK 00`（关灯）|
| `set 01` / `set 06` / `set 07` | 绿 / 橙 / 橙+闪烁 |
| `set 19` | 跟随系统（25 = 0x19）|

---

## 致谢

- SMC 客户端结构改编自 [MagSleep](https://github.com/realAbitbol/MagSleep)（MIT License），感谢原作者。
- MagSafe 3 LED 行为的公开研究与社区讨论。

## 许可

[MIT](LICENSE)。
