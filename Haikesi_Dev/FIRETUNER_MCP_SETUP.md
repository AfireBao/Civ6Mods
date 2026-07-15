# 文明 6 FireTuner + civ6-mcp 手动环境配置

本文用于配置「外部大模型读取文明 6 局势，并通过 FireTuner 向游戏下发操作」的单机开发环境。

## 一、当前电脑检查结果

| 项目 | 当前状态 |
|---|---|
| 文明 6 | 已安装：`F:\SteamLibrary\steamapps\common\Sid Meier's Civilization VI` |
| Python | 已安装：`3.12.7` |
| Git | 已安装：`2.54.0.windows.1` |
| 窗口模式 | 已开启：`FullScreen 0` |
| FireTuner 接口 | 已开启：`EnableTuner 1` |
| `uv` | 未安装 |
| 文明 6 Development Tools | 未安装 |
| civ6-mcp 仓库 | 未下载 |

当前配置文件位置：

```text
C:\Users\Administrator\AppData\Local\Firaxis Games\Sid Meier's Civilization VI\AppOptions.txt
```

其中已经设置：

```text
FullScreen 0
EnableTuner 1
```

修改该文件后必须完全退出并重新启动文明 6。

## 二、安装文明 6 Development Tools

### 推荐：通过 AppID 直接安装

1. 保持 Steam 客户端正在运行。
2. 按 `Win + R` 打开“运行”窗口。
3. 输入以下地址并回车：

   ```text
   steam://install/404350
   ```

4. Steam 应弹出 Development Tools 的安装确认窗口。

如果没有反应，可先按 `Win + R` 打开 Steam 控制台：

```text
steam://open/console
```

然后在 Steam 的 `CONSOLE` 页面输入：

```text
app_install 404350
```

### 通过 Steam 库查找

新版 Steam 的“动态收藏筛选条件”中没有“工具”选项。不要使用截图中的“库筛选条件”窗口。

如果客户端仍提供应用类型下拉菜单，应在库左侧列表顶部选择“游戏和软件”或“工具”，然后搜索：

   ```text
   Sid Meier's Civilization VI Development Tools
   ```

对应 Steam AppID 为 `404350`。

不需要安装体积较大的 `Sid Meier's Civilization VI Development Assets`（AppID `597260`）。

安装完成后，在 Steam 安装目录中搜索并确认存在：

   ```text
   FireTuner2.exe
   ```

本机已确认实际路径为：

```text
F:\SteamLibrary\steamapps\common\Sid Meier's Civilization VI SDK\FireTuner\FireTuner2.exe
```

> civ6-mcp 会独占 FireTuner TCP 连接。使用 civ6-mcp 时不要同时启动 `FireTuner2.exe`。

## 三、安装 uv

推荐使用 uv 官方安装脚本。打开新的 PowerShell：

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

关闭并重新打开 PowerShell，然后验证：

```powershell
uv --version
```

如果仍提示找不到 `uv`，先尝试：

```powershell
& "$env:USERPROFILE\.local\bin\uv.exe" --version
```

若绝对路径可用，可把该目录临时加入 PATH：

```powershell
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
uv --version
```

也可以使用 pip 安装，但网络较慢时可能等待较久：

```powershell
py -m pip install --upgrade uv --timeout 300
```

如果官方安装脚本无法访问 GitHub/Astral Release，改用国内 PyPI 镜像：

```powershell
py -m pip install --upgrade uv `
  -i https://pypi.tuna.tsinghua.edu.cn/simple `
  --timeout 300 --retries 10
```

若清华镜像不可用，可改用阿里云：

```powershell
py -m pip install --upgrade uv `
  -i https://mirrors.aliyun.com/pypi/simple/ `
  --timeout 300 --retries 10
```

安装后如果当前 PowerShell 仍找不到 `uv`，获取 Python Scripts 目录并直接执行：

```powershell
$scripts = py -c "import sysconfig; print(sysconfig.get_path('scripts'))"
& "$scripts\uv.exe" --version
```

也可以将其加入当前终端 PATH：

```powershell
$env:Path = "$scripts;$env:Path"
uv --version
```

如果所有 uv 下载方式都不可用，可以不用 uv，改用 Python 原生虚拟环境：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip `
  -i https://pypi.tuna.tsinghua.edu.cn/simple
.\.venv\Scripts\python.exe -m pip install -e . `
  -i https://pypi.tuna.tsinghua.edu.cn/simple `
  --timeout 300 --retries 10
```

此时 civ6-mcp 可直接通过以下文件启动：

```text
G:\Civ6Mods\civ6-mcp-haikesi\.venv\Scripts\civ-mcp.exe
```

## 四、下载并安装 civ6-mcp

在 PowerShell 中执行：

```powershell
Set-Location "G:\Civ6Mods"
git clone https://github.com/lmwilki/civ6-mcp.git civ6-mcp-haikesi
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
$env:UV_DEFAULT_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple"
$env:UV_HTTP_TIMEOUT = "300"
uv sync
```

如果 `uv` 尚未加入 PATH：

```powershell
$env:UV_DEFAULT_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple"
$env:UV_HTTP_TIMEOUT = "300"
& "$env:USERPROFILE\.local\bin\uv.exe" sync
```

清华 PyPI 镜像地址：

```text
https://pypi.tuna.tsinghua.edu.cn/simple
```

上述环境变量只对当前 PowerShell 生效。如果希望以后执行 `uv` 时默认使用清华源，可写入当前用户环境变量：

```powershell
[Environment]::SetEnvironmentVariable(
  "UV_DEFAULT_INDEX",
  "https://pypi.tuna.tsinghua.edu.cn/simple",
  "User"
)
[Environment]::SetEnvironmentVariable("UV_HTTP_TIMEOUT", "300", "User")
```

设置后需要重新打开 PowerShell。`uv sync` 第一次会下载 Python 依赖，所需时间取决于网络速度。

## 五、启动游戏并验证 FireTuner

1. 完全退出文明 6。
2. 确认 `FireTuner2.exe` 没有运行：

   ```powershell
   Get-Process FireTuner2 -ErrorAction SilentlyContinue
   ```

3. 重新启动文明 6。
4. 进入一局单机游戏并等待地图加载完成。
5. 检查 TCP 4318 端口：

   ```powershell
   Get-NetTCPConnection -LocalPort 4318 -ErrorAction SilentlyContinue
   ```

6. 在 civ6-mcp 目录测试握手：

   ```powershell
   Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
   uv run python scripts/test_connection.py
   ```

正常情况下会显示连接成功，并列出类似以下 Lua 状态：

```text
GameCore_Tuner
InGame
```

## 六、配置 Cursor MCP

可在以下任一位置创建 `mcp.json`：

- 全局：`C:\Users\Administrator\.cursor\mcp.json`
- 项目：`G:\Civ6Mods\.cursor\mcp.json`

内容：

```json
{
  "mcpServers": {
    "civ6": {
      "command": "uv",
      "args": [
        "run",
        "--directory",
        "G:\\Civ6Mods\\civ6-mcp-haikesi",
        "civ-mcp"
      ]
    }
  }
}
```

如果 Cursor 找不到 `uv`，把 `command` 改为绝对路径：

```json
"command": "C:\\Users\\Administrator\\.local\\bin\\uv.exe"
```

保存后重启 Cursor 或重新加载窗口。civ6-mcp 由 Cursor 按需启动，不需要另外打开长期运行的终端。

## 七、验证 MCP

确保：

1. 文明 6 已进入单机地图。
2. `FireTuner2.exe` 没有运行。
3. 没有另一个 civ6-mcp 进程占用连接。
4. Cursor 已加载 `civ6` MCP 服务。

然后让 Cursor Agent 调用 civ6 工具获取游戏概览。如果能读取当前回合、玩家、城市和单位，说明基础环境配置完成。

## 八、常见问题

### 4318 端口不存在

- 确认 `EnableTuner 1`。
- 修改后必须重启文明 6。
- 确认 Development Tools 已安装。
- 进入实际游戏地图后再检查。

### test_connection.py 一直等待

- 关闭 `FireTuner2.exe`。
- 关闭其他 civ6-mcp 实例。
- 完全重启文明 6；FireTuner 握手失败后经常无法自行恢复。

### version.py 报 UnicodeDecodeError / GBK

Windows 中文区域设置下，上游 `version.py` 可能使用 GBK 读取 UTF-8 的 `pyproject.toml`。打开：

```text
G:\Civ6Mods\civ6-mcp-haikesi\src\civ_mcp\version.py
```

将：

```python
pyproject.read_text()
```

改为：

```python
pyproject.read_text(encoding="utf-8")
```

### uv 命令不存在

使用：

```powershell
& "$env:USERPROFILE\.local\bin\uv.exe" --version
```

或重新打开 PowerShell，使安装程序写入的 PATH 生效。

### 成就被禁用

这是启用 Tuner 的正常结果。测试结束后将：

```text
EnableTuner 1
```

改回：

```text
EnableTuner 0
```

### 是否需要大模型 API Key

civ6-mcp 本身不调用模型 API，因此不需要保存 API Key。模型由 Cursor、Claude Code、Codex 或其他 MCP 客户端提供。

## 九、当前验证范围

已验证基础链路：

```text
文明6 → FireTuner → civ6-mcp → Cursor Agent
```

海克斯外部 AI 决策工具已实现（见第十节）。

**验证范围：单机 PVE + 联机 PVE（主机权威）。**

- 仅在**主机**连接 FireTuner / civ6-mcp 并提交决策。
- 客机不要开 FireTuner 提交（避免双端 Stage）。
- `submit_haikesi_ai_choices` 成功返回 `OK:staged`：只在主机暂存，由已加载的 `Haikesi_TriTrade_Bridge`（内含 ExtAI 广播）经 `EXECUTE_SCRIPT` 下发 `ExtAIApply`，各端同参落地。
- **仅主机人类确认海克斯**会推进 AI 轮次（`TriggerAIRelicRound`）；客机选卡只给自己发牌，不触发 AI。

## 十、海克斯外部 AI 决策验证

### 10.1 游戏内开关

开局高级选项中同时开启：

1. **AI 可选海克斯**（`NW_HAIKESI_AI_RELIC`）
2. **外部大模型 AI 海克斯**（`NW_HAIKESI_EXTERNAL_AI`）

> 修改 Mod 代码后需**重新开局或重载存档**，FireTuner 才能看到新的 `Haikesi_GetExternalAIRequest` 等函数。

### 10.2 civ6-mcp 新增工具

| 工具 | 作用 |
|------|------|
| `get_haikesi_ai_request` | 轮询是否有待处理的 AI 海克斯决策请求 |
| `submit_haikesi_ai_choices` | 主机校验并 Stage；游戏内桥接再广播落地 |

也可使用 `run_lua`，`context="haikesi"` 在 `Haikesi_GamePlay_Script` 状态执行调试代码。

### 10.2.1 联机 PVE（主机权威）

```text
人类选卡(EXECUTE_SCRIPT)
  → 各端同建 pending + options（确定性 salt）
  → 仅主机人类确认带 TriggerAIRelicRound
  → 仅主机 FireTuner/MCP：get → submit（OK:staged）
  → 主机 UI 桥接：EXECUTE_SCRIPT ExtAIApply
  → 各端同参 Apply + ClearPending
```

- 联机时 **只在主机** 运行 civ6-mcp / DeepSeek watch。
- **只有主机选海克斯**才让 AI 跟一轮；客机选卡不触发。
- 客机开启「外部大模型」开关即可（与主机同配置），但不要连接 FireTuner 提交。
- 超时未提交时，各端仍按确定性规则同步回退（与单机相同）。

### 10.3 命令行烟测（可选）

确认 FireTuner 已连接且游戏已加载 Haikesi Mod 后：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/test_haikesi_ai.py
```

- 无待处理请求时：输出 `status: none`（正常）
- 人类确认海克斯后：输出 `status: pending` 及每个 AI 的 `options` 列表（至多 3 张随机候选卡）
- 若报 `function expected instead of nil`：说明游戏内仍是旧版 Mod，需重载

### 10.4 Cursor Agent 端到端流程

1. 确保 `mcp.json` 已配置 civ6-mcp，游戏运行且 `EnableTuner=1`
2. 开局并开启上述两个开关
3. 人类玩家选海克斯并确认
4. 在 Cursor 中对 Agent 说：

```text
检查是否有海克斯 AI 待决策请求。若有，先调用 get_game_overview 了解局势，
再为每个 AI 从其 options 三张候选中选一个海克斯，并为每位 AI 写 1-2 句中文决策理由，
最后通过 submit_haikesi_ai_choices 提交 choices 与 reasons。
注意 NW_AI_BARBARIAN_INVASION 每轮最多给一个 AI。
追踪面板将显示：[领袖名]觉得[reason]，故选择[海克斯名称]
```

5. Agent 应依次调用：
   - `get_haikesi_ai_request`
   - `get_game_overview` / `get_cities`（了解局势）
   - `submit_haikesi_ai_choices`（`request_id` + `choices` + `reasons` 字典）
6. 提交成功应见 `OK:staged` / JSON `staged: true`；随后 Lua 出现 `ExtAIApply applied` 与 `AI PlayerX gained AI relic`
7. 打开海克斯追踪面板，确认 AI 卡片下方为决策理由句式

### 10.5 DeepSeek 全自动 AI 决策（推荐）

在 [DeepSeek 开放平台](https://platform.deepseek.com/api_keys) 申请 API Key，写入 **`G:\Civ6Mods\civ6-mcp-haikesi\.env`**：

```ini
DEEPSEEK_API_KEY=sk-...
DEEPSEEK_MODEL=deepseek-chat
HAIKESI_WATCH_INTERVAL_SEC=3
```

模型可选：
- `deepseek-chat` — 速度快，适合每回合决策（默认）
- `deepseek-reasoner` — 推理更强，稍慢

#### 监听脚本会不会随游戏自动启动？

**不会。** `haikesi_deepseek_watch.py` 是独立的 Python 进程，与文明6 **没有挂钩**：

| 步骤 | 谁负责 |
|------|--------|
| 启动文明6、开档、EnableTuner=1 | 玩家 |
| **另开 PowerShell 运行 watch 脚本** | **玩家手动** |
| 人类确认海克斯 → 脚本检测 pending → DeepSeek 决策 → 提交 | watch 脚本自动 |

推荐流程：

1. 先启动文明6并进入存档
2. 再开一个 PowerShell 窗口，常驻运行：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/haikesi_deepseek_watch.py
```

3. 正常游玩；每次你确认人类海克斯后，数秒内 AI 会自动获得海克斯 + 决策理由
4. 关游戏或不用时在该窗口按 `Ctrl+C` 停止脚本

若先开 watch、后开游戏，脚本会每 10 秒重连 FireTuner，游戏就绪后自动连上。

**单次测试（不常驻）：**

```powershell
uv run python scripts/haikesi_deepseek_decide.py
```

#### 其他 LLM 后端

通用脚本仍支持任意 OpenAI 兼容网关 / Anthropic，见 `.env.example`。DeepSeek 专用脚本：`haikesi_deepseek_decide.py` / `haikesi_deepseek_watch.py`。

#### 为什么不能靠 Cursor Agent 自动监听？

Cursor Agent **没有后台常驻进程**，只在你在 Cursor 里发消息时才会运行一次。它无法像 Windows 服务那样每隔几秒轮询 FireTuner，因此**不能**在人类确认海克斯后「自动弹出并决策」。

推荐做法：

| 方式 | 自动程度 | 说明 |
|------|----------|------|
| **`haikesi_deepseek_watch.py`（推荐）** | 全自动 | 玩家手动启动脚本后，轮询 FireTuner + DeepSeek 决策 |
| `haikesi_deepseek_decide.py` | 手动一次 | 人类确认后手动跑一条命令 |
| `haikesi_llm_watch.py` | 全自动 | 通用 OpenAI 兼容 / Anthropic，需自行配 `.env` |
| Cursor Agent + MCP | 半自动 | 每次需你在 Cursor 里发一句「检查待决策请求」 |

**DeepSeek 监听**（先开游戏，再另开 PowerShell 常驻）：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/haikesi_deepseek_watch.py
```

人类确认海克斯后，watch 脚本会在数秒内检测到 pending、调用大模型、提交 choices + reasons，追踪面板显示决策理由。按 `Ctrl+C` 停止。

> Cursor Agent 仍可用于**调试**（手动 `get_haikesi_ai_request` / 改 prompt），但生产环境的「无人值守自动决策」请用 watch 脚本。

### 10.6 示例 submit 参数

```json
{
  "request_id": "2_1_0",
  "choices": {
    "1": "NW_AI_ECHO_BUILDER",
    "2": "NW_AI_ECHO_RANGED"
  },
  "reasons": {
    "1": "城市数量领先但改良不足，复制建造者可加速铺基础设施",
    "2": "与邻国关系紧张，远程单位翻倍有助于防守边境"
  }
}
```

`reasons` 与 `choices` 的 key 必须一致（均为 AI 的 player_id 字符串）。reason 最长 200 字符。

### 10.7 超时回退

若 1 回合内未通过 MCP 提交，Gameplay 自动使用确定性规则补发 AI 海克斯（`External AI timeout, fallback deterministic`），理由显示为「外部决策超时，依规则自动选定」。

### 10.8 常见问题

| 现象 | 原因 | 处理 |
|------|------|------|
| `Haikesi_GetExternalAIRequest` 为 nil | 游戏未加载新版 Mod | 重开游戏或重载存档 |
| `status: none` | 尚未人类确认 / 已提交 / 已超时回退 | 人类再选一次海克斯 |
| 提交后 `request_id mismatch` | 使用了过期的 request_id | 重新 `get_haikesi_ai_request` |
| 端口 4318 无监听 | EnableTuner 未开或游戏未运行 | 检查 AppOptions.txt |
