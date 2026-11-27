# 防傻鱼紫砂工具

**The Silly-Fish Anti-Unalive Fence** · `dsh-pwsh-guard`

给 DeepSeek Harness（DSH）的 `pwsh` 工具装一道**删除前的围栏**：不看你写了什么命令，只看这次操作**真正要删的路径**。删你点名的文件/子目录 → 放行；删用户目录、workspace 本身、盘根、或者一次扫掉一堆没点名的东西 → 拒绝，并且用自然语言告诉触发围栏的智能体"为什么"和"该怎么做"。

> 名字里的「紫砂」是「自杀」的谐音梗：2026-11-23，一个智能体把 `$home` 赋成了只读的 `$HOME`，随后 `Remove-Item -Recurse -Force` 删掉了整个 `~/.dsh`。

## 原理

DSH 的 `pwsh` 工具不直接调 PowerShell：`dsh-pwsh-sandbox` → `dsh-pwsh-local`，argv 固定为 `<pwshPath> -NoLogo -NoProfile -NonInteractive -Command <命令>`，而 `pwshPath` 是插件配置项。所以：

```
-Command "<用户命令>"          ← DSH 本来要交给 PowerShell 的东西
   ↓  exe 改写
-Command ". 'guard.shim.ps1'; <用户命令>"
   ↓
真正的 PowerShell 7：由它把变量、通配符、管道解析成真实路径
   ↓
shim 里的 Remove-Item 替身（rm/del/erase/rd/rmdir/ri 都是它的别名）
   ↓  判目标 → 放行 / 退出码 86 中止
```

判定发生在**会话内**，所以 `$home`、`.`、`*`、`Get-ChildItem x | Remove-Item`、以及藏进 `.ps1` 的删除，全都以真实路径的形式被看到。

## 三条判据（只判目标，不判命令）

| # | 判据 | 拒绝时的说法 |
|---|---|---|
| 1 | 目标表达式含 `*` / `?` | `the target expression '…\*' contains a wildcard, so it can delete files that were never named.` |
| 2 | 目标是受保护根、其上层、或盘根 | `the target 'C:\Users\Neus117' is a protected root …` |
| 3 | 单次目标数 > `maxTargets`（默认 20） | `this one call would delete 25 paths at once …` |

受保护根在会话内计算：`%USERPROFILE%`、`%APPDATA%`、`%LOCALAPPDATA%`、`%DSH_HOME%`、**当前工作目录本身**（DSH 里就是 workspace 根）、任何盘根。

## 被拦时智能体收到什么

```
[pwsh-guard] REFUSED Remove-Item: the target 'C:\Users\Neus117' is a protected root (user home, AppData, DSH home,
             or the session's working directory). Deleting it would destroy everything under it.
[pwsh-guard] Nothing was deleted, and every later statement of this command was skipped (exit code 86).
[pwsh-guard] Targets that were resolved: C:\Users\Neus117
[pwsh-guard] What to do instead: name the file or sub-folder inside it that you actually want gone.
[pwsh-guard] If the user really asked for this, tell them what was refused and let them decide.
```

退出码 `86`，且**命令后半截不再执行**（`$host.SetShouldExit(86)` + `throw`）。

## 特性

- **无黑名单、无正则**：判据只有目标属性；判定层是 7.6 KB 的 `guard.shim.ps1`，exe 只负责注入和转发。
- **脚本里藏不住**：同一会话内 `.ps1` 里的 `Remove-Item` 一样受管。
- **放行不需要标记**：点名的删除直接过，不打扰正常工作。
- **审计按目标记**：`logs\guard.jsonl` 记录解析后的路径和决定，不是命令原文。
- **只影响 DSH**：系统 `pwsh.exe` / `powershell.exe`、PATH、PowerShell profile 一律不动。
- **fail-closed**：exe / shim / 配置任一损坏时，pwsh 命令整体失败并说明原因，不会静默裸奔。

## 安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-guard.ps1     # 12 条行为矩阵
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Exe dist\pwsh-guard-1.0.0.exe
```

`install.ps1` 自带 preflight（放行/拒绝各验一次）、改前备份 `cordis.patch.yml`。换 exe 即时生效，无需重启 DSH；用 `scripts\uninstall.ps1` 摘除 `pwshPath`（需重启 DSH 才彻底关闭）。

## 边界

1. 只管 PowerShell 的 `Remove-Item` 及其别名；`cmd /c del`、`node -e`、`[IO.File]::Delete()`、`Move-Item` 看不到。
2. `Remove-Item *` 一律拒绝——清理目录请点名路径。
3. 注入让 PowerShell 报错行号偏移约 1 行。
4. 不替代备份：它压的是手滑，数据层兜底仍是快照轮转。

## 文件

```
src\PwshGuard.cs      入口 exe：注入 shim、转发 argv（无策略）
guard.shim.ps1        判定层：Remove-Item 替身、解析目标、三条判据、日志
guard.config.json     受保护根追加、maxTargets、denyWildcard、日志路径、pwsh 候选
scripts\              build / test-guard / install / uninstall
dist\                 本机构建产物（git 忽略）
```
