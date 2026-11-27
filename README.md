# dsh-pwsh-guard

给 DeepSeek Harness（DSH）的 `pwsh` 工具加一道**执行前的命令闸**：删库、镜像覆盖、强杀进程树、把删除藏进脚本文件这类命令在门内被拒，PowerShell 根本不会启动；同时把每条命令的决定写进审计日志。

它是 2026-11-23 `~/.dsh` 被清空事故的补丁的推广版本（初版在 `D:\Coding\deepseek-harness-guard`，`pwsh-safe.exe` / `pwsh-safe-v2.exe`）。初版能拦，但有两处代价：**用全文匹配**（连"在文件里搜索 `Remove-Item` 这几个字"也会被拒），以及**完全不留记录**。v3 改掉这两点，并且可配置、可安装、可自测。

- 当前版本：`3.0.2`
- 只在 DSH 里生效；系统 `pwsh.exe` / `powershell.exe`、PATH、PowerShell profile 一律不动，用户自己的终端不受影响。

---

## 1. 它凭什么能拦住 DSH 的命令（原理）

DSH 的 `pwsh` 工具**不直接调 PowerShell**，链路是：

```
dsh 工具层  →  @deepseek-ai/dsh-pwsh-sandbox（沙箱执行器）
            →  @deepseek-ai/dsh-pwsh-local（本地执行器）
            →  ctx.subprocess 启动 argv
```

`dsh-pwsh-local` 的 argv 是固定的：

```
<pwshPath> -NoLogo -NoProfile -NonInteractive -Command "<UTF-8 编码前置> + <命令>"
```

其中 `pwshPath` 是插件配置项（`Config.pwshPath`），`resolvePwshPath()` 对**显式配置值原样采用，不做存在性校验**。所以只要在 profile 的 `cordis.patch.yml` 里给 `pwsh-sandbox` 这个插件加一条 `pwshPath`，DSH 的每一次 pwsh 调用都会先启动我们这个小程序。

本工具做的事：

1. 收到与 DSH 本会交给 PowerShell 完全相同的 argv；
2. 取出 `-Command` 后面那段命令文本，按规则判定；
3. 命中 → 向 stderr 写一行结论，**退出码 3**，不创建任何子进程；
4. 未命中 → 用 Windows 引号规则把 argv 原样转给真正的 PowerShell 7，stdout/stderr/退出码照原样返回。

也就是说：拦截发生在**任何进程被创建之前**，`$home` 那类命令连删的机会都没有；放行的命令行为与没有这层包装时逐字节一致。

### 为什么改 profile 立即生效

profile 的 patch 层由 loader 监视并重新应用（`dsh-pwsh-local` 的 `pwshPath` getter 每次读当前配置）。2026-11-27 实测：把 `pwshPath` 从 v2 切到 v3.0.2，**没有重启 DSH**，下一条命令的父进程就变成了 `pwsh-guard-3.0.2.exe`（`Win32_Process` 读数）。11-23 初版切换时同样是热生效。

---

## 2. 判定逻辑

默认 7 条规则（`guard.rules.json`，改 JSON 即可生效，无需重新编译）：

| 规则 id | 拦截内容 |
|---|---|
| `delete-cmdlet` | `Remove-Item` / `Remove-ItemProperty` / `Clear-Content` / `Clear-RecycleBin` |
| `delete-alias` | `del` / `erase` / `rd` / `rmdir` / `rm` / `ri` |
| `move-cmdlet` | `Move-Item` / `mv` |
| `git-clean` | `git clean` |
| `robocopy-mirror` | `robocopy ... /MIR` `/MOV` `/PURGE` |
| `taskkill-tree` | `taskkill ... /T` |
| `script-bypass` | `powershell|pwsh ... -File` / `-EncodedCommand` / `-enc`（防把删除藏进脚本） |

关键差异：**破坏性动词按"命令位置"锚定**，不是全文匹配。位置 = 文本开头，或 `;` `|` `&&` `{` 换行之后。代价与收益：

- 2026-11-23 那条事故命令里 `Remove-Item` 独占一行 —— 一样被拦；
- `Select-String -Path x -Pattern 'Remove-Item'`、`$removeItem = 1` 这类"只是提到这个词"的命令**不再被误拦**（v2 会拦）。

### 保护根（连 allow marker 也压不住）

命令里出现 `$home` / `$env:USERPROFILE` / `$env:APPDATA` / `$env:LOCALAPPDATA` / `$env:ProgramData` / `%USERPROFILE%` 之类"整个用户目录"的记号，且同时命中删除规则 → **无条件拒绝**。11-23 的写法是 `$home = ...` 撞上只读 `$HOME`，这一层让它即使带了放行标记也过不去。

### 放行标记（例外通道）

命令里含 `dsh-guard:allow-destructive` 时，被规则命中的命令放行，日志记为 `allowed-by-marker`。用途：清理临时目录、跑一次性迁移这类**需要删除**的正经工作。

- 标记**故意不写进拒绝信息的提示里**：模型被拦后应先问用户，而不是自己补一个标记继续删。
- 它防的是**误操作**，不是对抗：任何能写字符的东西都能写这个标记。真正的兜底仍然是快照备份。
- 保护根命中时标记无效。

### 退出码

| 码 | 含义 |
|---|---|
| 子进程退出码 | 放行，原样透传 |
| `3` | 被守卫拒绝（PowerShell 未启动） |
| `4` | 找不到可用的 PowerShell 7 / 启动失败 |
| `5` | 守卫自身异常（配置坏了也不会静默放行） |

---

## 3. 审计日志

默认写到 **exe 同目录** `logs\guard.jsonl`（超过 5 MB 轮转成 `.1`），一行一条：

```json
{"time":"2026-11-27T18:42:48.156+08:00","decision":"blocked","rule":"delete-cmdlet","reason":"deletes files, keys, content or the recycle bin","pid":3296,"cwd":"D:\\Coding\\workspace","command":"...前 4000 字符..."}
```

`decision` 取值：`run`（放行）/ `blocked` / `allowed-by-marker`。

这是 11-23 事故里最缺的东西：当时"到底删了什么、谁删的"完全无从查证（`Remove-Item` 不进回收站）。日志**始终记录执行前的命令原文**，所以即使守卫被绕过（见第 6 节），事后也有据可查。

---

## 4. 安装 / 验证 / 回滚

```powershell
# 1) 编译（用 Windows 自带的 .NET Framework csc，无需 SDK / 联网）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\build.ps1

# 2) 自测：15 条行为矩阵（放行 / 拦截 / 保护根 / 标记 / UTF-8 / 日志）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\test-guard.ps1

# 3) 装进 profile：备份 cordis.patch.yml，把 pwsh-sandbox.pwshPath 指到本 exe
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\install.ps1 -Exe D:\Coding\dsh-pwsh-guard\dist\pwsh-guard-3.0.2.exe
```

`install.ps1` 自带 preflight：exe 跑不起来、放行不通、拦截不通，任何一项不过都不会改 profile。

在 DSH 里验证（三条命令按顺序发）：

1. `Write-Output guard-live-ok` → 打印 `guard-live-ok`；
2. `Remove-Item -LiteralPath C:\nope -Recurse -Force` → 被拒，`[pwsh-guard] BLOCKED rule=delete-cmdlet`，`error` 码 3；
3. 读 `dist\logs\guard.jsonl` → 两条决定都在。

回滚：

```powershell
# 只摘掉 pwshPath（DSH 回到直接用真 pwsh，守卫关闭）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\uninstall.ps1

# 或者整份恢复安装前的 profile
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Coding\dsh-pwsh-guard\scripts\uninstall.ps1 -Restore
```

**升级时不要覆盖正在用的 exe**：DSH 跑命令时该 exe 是被锁住的（Windows 文件锁），`build.ps1` 会自动改写成带时间戳的新文件名，然后用 `install.ps1 -Exe <新文件>` 切换。这也是初版 README 里记过的坑。

换一台机器 / 换一个 profile：复制整个目录 → `build.ps1` → `install.ps1 -Exe ... -ProfileDir <目标 profile 目录>`。`guard.rules.json` 里的 `pwshCandidates` 按目标机器的 PowerShell 7 位置改。

---

## 5. 文件结构

```
dsh-pwsh-guard\
  guard.rules.json         规则、保护根、日志路径、标记（唯一需要改的配置）
  src\PwshGuard.cs         守卫本体（C# 5，单文件，无第三方依赖）
  scripts\build.ps1        编译 + 暂存 dist\
  scripts\test-guard.ps1   15 条行为矩阵，退出码 0/1
  scripts\install.ps1      preflight + 备份 + 改 profile
  scripts\uninstall.ps1    摘除 pwshPath 或整份恢复
  dist\                    产物：pwsh-guard-3.0.2.exe + guard.rules.json + logs\
```

## 6. 已知限制（务必读完再用）

1. **只看外层命令文本。** 脚本文件内容、`Invoke-Expression`、`node -e`/`python -c` 里的删除、`[IO.File]::Delete()`、`$obj.Delete()` 都看不到。`-File` / `-EncodedCommand` 已被禁，但"写个 .ps1 再 `&` 它"仍可绕过（放行时日志里有原文可追）。
2. **锚定匹配的取舍。** `& 'Remove-Item' x` 这类故意绕过不拦；换来的是不再误拦"搜索这个词"。
3. **保护根只认变量记号，不认字面绝对路径。** `Remove-Item C:\Users\Neus117 -Recurse`（裸路径、无标记）会被规则拦；但若同时写了放行标记，则不会被保护根拦住。
4. **fail-closed。** `pwshPath` 不做存在性校验：exe 被删或损坏时，DSH 的 **所有** pwsh 命令都会失败。这是有意的（宁可不能用，也不要静默变成无守卫）。
5. **不替代备份。** 它压的是"手滑"，不是"备份"。快照轮转（`D:\Coding\DeepSeek Harness Backup`）仍然是数据层的兜底。
6. 规则是黑名单。新的破坏性动词（`Format-Volume`、`Remove-Partition` 等）默认不在里面，需要时往 `guard.rules.json` 加。
7. **exe 与 `guard.rules.json` 必须成对升级。** 规则文件与 exe 同目录共享，新规则若用了旧 exe 不认识的写法，会当场把在用的旧 exe 弄坏（实测：3.0.1 不认识 `%LOCALAPPDATA%` 占位符，读到新规则后直接找不到 PowerShell，所有 pwsh 命令返回 4）。正确顺序：先 `install.ps1 -Exe <新 exe>` 换掉 `pwshPath`，再更新规则文件。

---

## 7. 与 11-23 初版的关系

| | 初版 `deepseek-harness-guard`（v1/v2） | 本工具（v3.0.2） |
|---|---|---|
| 接入方式 | `pwsh-sandbox.pwshPath` | 相同 |
| 匹配 | 全文匹配 | 命令位置锚定（附带 `-File` 规则） |
| 误报 | 搜索该词也被拒 | 已消除 |
| 审计日志 | 无 | `logs\guard.jsonl`（含被拦命令原文） |
| 配置 | 编译进 exe | `guard.rules.json` |
| 放行例外 | 无 | `allow-destructive` 标记 + 保护根兜底 |
| 自测 | 手工 | 15 条矩阵，`test-guard.ps1` |

初版目录保留作回滚，可以删；v3 已接管 profile 的 `pwshPath`。
