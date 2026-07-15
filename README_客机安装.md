# 客机安装指南 — 海克斯大乱斗 Dev

联机**客机**只需安装本地模组 `Haikesi_Dev`，**不必**配置 FireTuner / MCP / DeepSeek 等环境（那些只给「主机接外部大模型 AI」用）。

仓库：<https://github.com/AfireBao/Civ6Mods>

---

## 你需要什么

- 《文明 6》及风云变幻（Gathering Storm）
- 本仓库源码（下载 ZIP 或 `git clone`）

---

## 安装步骤

### 1. 拿到模组目录

解压仓库 ZIP 后，找到里面的 **`Haikesi_Dev`** 文件夹（与 `civ6-mcp-haikesi` 同级）。  
客机**只复制 `Haikesi_Dev`**，不要把整个仓库、也不要把 `civ6-mcp-haikesi` 拷进游戏。

### 2. 复制到本地 Mods 目录

本地模组路径（注意：和 Steam 工坊目录**不是**同一个地方）：

```text
%USERPROFILE%\Documents\My Games\Sid Meier's Civilization VI\Mods\Haikesi_Dev\
```

即把 `Haikesi_Dev` **整个文件夹**放到上述 `Mods` 下，最终应存在：

```text
...\Mods\Haikesi_Dev\Haikesi.modinfo
```

PowerShell 一键安装示例（按你的 ZIP 路径改第一行即可）：

```powershell
$ErrorActionPreference = 'Stop'
$zip = 'D:\Downloads\Civ6Mods-main.zip'
$extractRoot = 'D:\Downloads\Civ6Mods-main'
if (-not (Test-Path $zip)) { throw "ZIP not found: $zip" }
if (Test-Path $extractRoot) { Remove-Item $extractRoot -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
$src = Get-ChildItem $extractRoot -Recurse -Directory -Filter 'Haikesi_Dev' |
  Where-Object { $_.FullName -notmatch 'civ6-mcp-haikesi' } |
  Select-Object -First 1
if (-not $src) { throw 'Haikesi_Dev not found' }
$docs = [Environment]::GetFolderPath('MyDocuments')
$modsRoot = Join-Path $docs "My Games\Sid Meier's Civilization VI\Mods"
New-Item -ItemType Directory -Force -Path $modsRoot | Out-Null
$dest = Join-Path $modsRoot 'Haikesi_Dev'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item $src.FullName $dest -Recurse -Force
Write-Host "INSTALL OK"
Write-Host "DEST: $dest"
```

### 3. 在游戏里启用

1. 启动文明 6 → **附加内容**
2. **启用**「海克斯大乱斗」Dev（本地 `Haikesi_Dev`）
3. 若订阅过 Steam 工坊原版「海克斯大乱斗」，请**禁用工坊原版**，只开本地 Dev，**不要两个一起开**

---

## 目录对照（容易搞错）

| 类型 | 典型路径 |
|------|----------|
| 本地模组（本仓库要装这里） | `文档\My Games\Sid Meier's Civilization VI\Mods\` |
| Steam 工坊模组 | `Steam\steamapps\workshop\content\289070\` |
| 游戏本体（不用往这里拷 mod） | `Steam\steamapps\common\Sid Meier's Civilization VI\` |

---

## 客机 vs 主机

| 角色 | 需要做什么 |
|------|------------|
| **客机** | 只装并启用 `Haikesi_Dev` |
| **主机（要接外部大模型帮 AI 选海克斯）** | 另配 FireTuner / `civ6-mcp-haikesi` 等，见仓库主 [README](README.md) 与 [Haikesi_Dev/FIRETUNER_MCP_SETUP.md](Haikesi_Dev/FIRETUNER_MCP_SETUP.md) |

---

## 更新模组

重新解压/拉取仓库后，再次用 `Haikesi_Dev` **覆盖**到同一本地 Mods 路径即可；进游戏确认仍只启用本地 Dev。
