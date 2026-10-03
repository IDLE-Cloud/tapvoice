# tapvoice

macOS 触控板手势 → 按键事件的开源守护进程。Swift 编写，无第三方依赖，一个二进制即全部。

## 功能

| 手势 | 动作（键位可自定义） |
|---|---|
| N 指轻点（默认 4 指） | 发送指定按键（默认：左⌘），立即触发 |
| M 指双击（默认 3 指，间隔 <450ms） | 发送指定按键（默认：回车） |

两套手势使用不同指数量（N≠M），互不干扰：N 指单击无需等待双击判定、零延迟触发；
M 指需两次轻点且每次接触持续 ≥60ms（区分拖移与触点过渡噪声）。

## 实现说明

- **触控数据**：通过 macOS 私有框架 MultitouchSupport 读取原始触点帧。该接口未公开但长期稳定；读取数据不需要任何系统权限。
- **手势判定**：跟踪触点数量。候选手势从"指数量达到设定值"开始，到"全部抬起（count=0）"时判决；接触总时长须在 30~500ms 窗口内。落指/抬指过程中的 1~(N-1) 指过渡帧不取消候选。
- **按键注入**：CGEvent 以 HID 级别系统级投递。此步骤需要"辅助功能"权限（在系统设置 → 隐私与安全性 → 辅助功能中开启）。
- **权限稳定性**：程序以 `.app` 形式分发并用自签名证书签名，授权绑定证书而非单次编译产物，重新编译不会丢失权限。

## 安装

要求：macOS + Swift 工具链（`xcode-select --install`）。

```bash
git clone https://github.com/IDLE-Cloud/tapvoice.git && cd tapvoice

./make-tapvoice-cert.sh    # 一次性：在登录钥匙串创建自签名代码签名证书
./build-tapvoice.sh        # 编译 → 打包 TapVoice.app → 签名

# 注册开机自启服务
launchctl bootstrap gui/$(id -u) com.user.tapvoice.plist
```

安装后前往 系统设置 → 隐私与安全性 → 辅助功能，将 **TapVoice** 开关打开。

常用命令：

```bash
launchctl kickstart -k gui/$(id -u)/com.user.tapvoice   # 重启服务（改配置后）
tail -f ~/Library/Logs/tapvoice.log                     # 查看日志
```

## 配置

通过 LaunchAgent plist（`com.user.tapvoice.plist`）的 `EnvironmentVariables` 段设置：

| 变量 | 默认 | 说明 |
|---|---|---|
| `TAP_FINGERS` | `4` | 单击手势的指数量 |
| `TAP_KEYCODE` | `55` | 单击发送的键码 |
| `TAP_FLAGS` | `0x100008` | 单击的修饰标志（十六进制；默认值 = ⌘ + 左键设备标记） |
| `DOUBLE_FINGERS` | `3` | 双击手势的指数量（与单击不同，避免误触） |
| `DOUBLE_KEYCODE` | `36` | 双击发送的键码 |
| `TAP_DEBUG` | 关 | 设为 `1` 记录所有触点帧，用于调试判定 |

虚拟键码对照表见 Apple 文档《Virtual Key Codes》。修改后重启服务生效。

## 注意

- 依赖未公开的 MultitouchSupport 框架，macOS 大版本升级后请验证可用性。
- 快速四指滑动（<500ms）可能被判定为轻点；可在源码中调整时间窗常量。

## License

MIT
