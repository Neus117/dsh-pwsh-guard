# dsh-pwsh-guard

给 DeepSeek Harness（DSH）的 `pwsh` 工具加一道**删除前的目标检查**：不看你写了什么命令，只看这次操作**真正要删掉的路径**。删一个你点名的文件/子目录 → 放行；删用户目录、workspace 本身、盘根 → 拒绝，并把"为什么被拦、正确的做法是什么"用自然语言回给触发围栏的智能体。

起因是 2026-11-23 `~/.dsh` 被清空（`$home` 撞上只读 `$HOME`）。初版和 3.x 靠**匹配命令文本**拦，代价是误报（搜这个词也被拦）且拦不住藏进脚本的删除。4.x 换了判据：判目标。

- 当前版本：`4.0.0`
- 只在 DSH 里生效：系统 `pwsh.exe` / `powershell.exe`、PATH、PowerShell profile 一律不动，你自己的终端不受影响。

---

## 1. 它怎么接进 DSH（原理）

DSH 的 `pwsh` 工具不直接调 PowerShell，链路是：

```
dsh 工具层 → @deepseek-ai/dsh-pwsh-sandbox → @deepseek-ai/dsh-pwsh-local → ctx.subprocess
```

`dsh-pwsh-local` 的 argv 固定为：

```
<pwshPath> -NoLogo -NoProfile -NonInteractive -Command "<UTF-8 编码前置> + <命令>"
```

`pwshPath` 是插件配置，`resolvePwshPath()` 对显式配置值**原样采用**。所以把 `pwsh-sandbox.pwshPath` 指向本 exe，DSH 每次调用都会先经过它。

本工具只做一件事：

```
-Command "<preamble><用户命令>"
   ↓ 改写成
-Command ". 'guard.shim.ps1'; <preamble><用户命令>"
   ↓
交给真正的 PowerShell 7，退出码原样透传
```

**判定不在 exe 里，`guard.shim.ps1` 在会话内定义 `Remove-Item` 的替身**（`rm`/`del`/`erase`/`rd`/`rmdir`/`ri` 都是它的别名，自动一并受管）。于是变量、通配符、管道都由 PowerShell 自己解析成**真实路径**，替身拿到目标后再判——`$home`、`.`、`*`、`Get-ChildItem x | Remove-Item` 全都变成具体路径，藏进 `.ps1` 的删除也在同一会话里，同样受管。

这带来两个直接好处：

- **不需要黑名单**：没有动词表、没有正则，判定依据只有一份数据（受保护根清单 + 两个数量型参数）。
- **反馈是精确的**：报的是"`C:\Users\Neus117` 是受保护根"，不是"命令里出现了某个词"。

---

## 2. 三条判据（全部判目标，不判命令）

| # | 判据 | 拒绝时的说法 |
|---|---|---|
| 1 | 目标表达式含 `*` / `?`（会删掉没点名的东西）；`-Filter` 的值不算 | `the target expression '…\*' contains a wildcard, so it can delete files that were never named.` |
| 2 | 目标是受保护根，或受保护根的**上层**，或盘根 | `the target 'C:\Users\Neus117' is a protected root (user home, AppData, DSH home, or the session's working directory). Deleting it would destroy everything under it.` |
| 3 | 一次调用要删的目标超过 `maxTargets`（默认 20） | `this one call would delete 25 paths at once, which is more than the limit of 20.` |

受保护根（运行时在会话里算，不写死盘符）：`%USERPROFILE%`、`%APPDATA%`、`%LOCALAPPDATA%`、`%DSH_HOME%`、**当前工作目录本身**（DSH 里就是 workspace 根）、任何盘根。`extraProtectedRoots` 可追加。

判定顺序是 1 → 3 → 2，任一条命中即拒绝。

### 智能体看到的完整反馈（实测原样）

```
[pwsh-guard] REFUSED Remove-Item: the target 'C:\Users\Neus117' is a protected root (user home, AppData, DSH home,
             or the session's working directory). Deleting it would destroy everything under it.
[pwsh-guard] Nothing was deleted, and every later statement of this command was skipped (exit code 86).
[pwsh-guard] Targets that were resolved: C:\Users\Neus117
[pwsh-guard] What to do instead: name the file or sub-folder inside it that you actually want gone.
[pwsh-guard] If the user really asked for this, tell them what was refused and let them decide.
```

拒绝时 `$host.SetShouldExit(86)` + `throw`：**退出码 86，且命令后半截不会继续执行**（已用 `; Write-Output 'AFTER'` 断言）。每一句"该怎么做"都指向具体动作，智能体不需要猜。

### 放行的样子（无需任何标记）

```powershell
Remove-Item -LiteralPath "$env:TEMP\probe.txt" -Force          # 0
Remove-Item -LiteralPath "$env:TEMP\build" -Recurse -Force      # 0
Get-ChildItem .\dist\*.tmp | Remove-Item -Force                 # 0（目标 ≤ 20 个）
```

---

## 3. 退出码

| 码 | 含义 |
|---|---|
| `0`（或子进程原码） | 放行 / 命令自身结果 |
| `86` | 被守卫拒绝（`Remove-Item` 没执行，命令后半截被跳过） |
| `4` | 守卫自身找不到 PowerShell 或 shim（fail-closed，宁可跑不了也不裸奔） |
| `5` | 守卫内部异常 |

---

## 4. 审计日志

`dist\logs\guard.jsonl`，一行一条，**记解析后的目标而不是命令原文**：

```json
{"t":1795777369910,"decision":"refused","reason":"the target 'C:\\Users\\Neus117' is a protected root …","pid":26152,"cwd":"C:\\Coding\\workspace","targets":["C:\\Users\\Neus117"]}
{"t":1795777300000,"decision":"allowed","reason":"delete of 2 named target(s)","pid":26152,"cwd":"D:\\Coding\\workspace","targets":["…\\a.txt","…\\b.txt"]}
```

超过 5 MB 由 `maxLogBytes` 决定轮转（当前实现为按条追加，轮转留给运维侧，见"已知限制"）。

---

## 5. 安装 / 验证 / 回滚

```powershell
# 1) 编译 + 暂存 dist\（exe + shim + 配置；用系统自带 csc，无需 SDK/联网）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\build.ps1

# 2) 行为矩阵（12 条，允许/拒绝/脚本内删除/通配符/数量/盘根/管道）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\test-guard.ps1

# 3) 装进 profile（preflight 通过才改 cordis.patch.yml，改前自动备份）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\install.ps1 -Exe D:\Coding\dsh-pwsh-guard\dist\pwsh-guard-4.0.0.exe
```

在 DSH 里验证（三条按顺序发）：

1. `Remove-Item -LiteralPath "$env:TEMP\v4.txt" -Force`（先建这个文件）→ 正常删除，无提示；
2. `Remove-Item $env:USERPROFILE -Recurse -Force -WhatIf` → 被拒，看到 5 行反馈，退出码 86；
3. 读 `dist\logs\guard.jsonl` → 两条决定都在，`targets` 里是真实路径。

回滚：

```powershell
# 摘掉 pwshPath（重启 DSH 后彻底关闭；换 exe 是即时生效，见下）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\uninstall.ps1
# 或整份恢复安装前的 profile
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\uninstall.ps1 -Restore
```

**生效时机（实测）**：换 `pwshPath` 指向新 exe → 下一条命令即时生效；改 `guard.shim.ps1` → 下一条命令即时生效；**摘掉 `pwshPath` 的卸载不热生效，要重启 DSH**。

升级注意：exe 与 `guard.shim.ps1`、`guard.config.json` 是**一套**，必须一起换（`build.ps1` 会把三个文件都放进 `dist\`）。运行中的 exe 会被 Windows 锁住，`build.ps1` 会自动改用带时间戳的新文件名，再 `install.ps1 -Exe <新文件>` 切换。

---

## 6. 文件结构

```
dsh-pwsh-guard\
  src\PwshGuard.cs        入口 exe：注入 shim、转发 argv、传环境变量（~200 行，无策略）
  guard.shim.ps1          唯一的判定层：定义 Remove-Item 替身、解析目标、三条判据、日志
  guard.config.json       受保护根追加、maxTargets、denyWildcard、日志路径、pwsh 候选
  scripts\build.ps1       编译 + 暂存 dist\
  scripts\test-guard.ps1  12 条行为矩阵（退出码 0/1）
  scripts\install.ps1     preflight + 备份 + 改 profile
  scripts\uninstall.ps1   摘除 pwshPath 或整份恢复
  dist\                   pwsh-guard-4.0.0.exe + guard.shim.ps1 + guard.config.json + logs\
```

## 7. 已知限制

1. **只管 PowerShell 的 `Remove-Item`（含其别名）**。同会话里的脚本、`ForEach-Object { Remove-Item $_ }` 都覆盖；但 `cmd /c del`、`node -e "fs.rmSync"`、`[IO.File]::Delete()`、`Remove-Volume` 等看不到（已用 `cmd /c del` 在矩阵里固定为"已知盲区"用例）。这类残留风险由日志与快照备份兜底。
2. **只看 `Remove-Item`**：`Move-Item`、`Clear-Content`、`Remove-ItemProperty` 不在判定范围。需要时按同样方式加替身（一次约 5 行）。
3. **`Remove-Item *` 一律拒绝**（判据 1）。清理临时目录请点名路径或用 `-LiteralPath` 传具体文件。
4. **一次最多删 20 个目标**（判据 3，可配置）。批量清理请按目录分次，或调大 `maxTargets`。
5. **注入会改变错误行号**：`-Command` 前多了一段 dot-source，PowerShell 报错里脚本行号会偏移 1 行左右。
6. **fail-closed**：`pwshPath` 不做存在性校验；exe / shim / 配置任一损坏，DSH 的所有 pwsh 命令会失败（退出码 4 并说明原因）。
7. **不替代备份**：它压的是手滑；数据层兜底仍是 `D:\Coding\DeepSeek Harness Backup` 的快照轮转。
8. 日志按条追加，暂未实现按大小轮转（`maxLogBytes` 已进配置，留给后续）。

---

## 8. 版本谱系

| 版本 | 判据 | 反馈 | 结局 |
|---|---|---|---|
| v1 / v2（2026-11-23，`D:\Coding\deepseek-harness-guard`） | 命令文本正则黑名单 | 一行 `blocked …`，退出码 3 | 能拦，但误报多、无日志；保留作回滚 |
| v3.x（2026-11-27 上午） | 命令文本锚定匹配 + 保护根 + 放行标记 | 两行，退出码 3 | 消掉误报、加了审计，但"藏进脚本"仍拦不住 |
| **v4.0.0（现行）** | **解析后的删除目标**（通配符 / 保护根 / 数量） | 五行自然语言 + 退出码 86 | 无黑名单、无正则，脚本内删除同样受管 |
