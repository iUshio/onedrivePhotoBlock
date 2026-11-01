# onedrivePhotoBlock

**OneDrive 照片守卫**：自动清理 OneDrive 照片伴随程序的 Windows 后台脚本，支持目录监听、开机自启和同目录日志。

> Event-driven removal of the OneDrive Photos companion executable, with startup persistence and rotating logs beside the script.

清理目标固定为：

```text
C:\Program Files\Microsoft OneDrive\OneDrive.App.exe
```

项目版本：`0.1.0`。GitHub 仓库名：`onedrivePhotoBlock`。

## 功能

- **出现后自动删除**：启动时检查已有文件，运行中响应文件创建、写入和重命名事件。
- **后台等待通知**：空闲时阻塞等待，每 60 秒只补查目标文件并修复监听。
- **处理文件占用**：核验进程的完整可执行文件路径后，结束目标进程并重试删除。
- **有限重试**：失败后按 0.5、1、2、5 秒间隔重试；仍失败则等待 60 秒，避免高频循环。
- **自动恢复监听**：目录消失、被重建或监听异常时重新绑定。
- **开机自启**：通过 Windows 计划任务以 SYSTEM 身份运行，无需登录、无交互窗口。
- **同目录日志**：日志跟随实际运行的脚本，默认最多三份，每份约 1 MiB。
- **单实例运行**：计划任务和目标路径互斥锁共同限制重复启动。

范围限定为上述机器级安装路径。用户目录中的安装副本和开始菜单快捷方式不属于清理范围。

**这是发现后删除，文件可能短暂存在或先启动；程序不会阻止下载流量。** 路径变更后需要相应修改脚本。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | 64 位 Windows 10 / Windows 11 |
| 运行环境 | 系统自带的 64 位 Windows PowerShell 5.1 和 .NET Framework |
| 安装、更新、卸载 | 管理员权限 |
| 常驻运行账户 | SYSTEM，由计划任务启动 |
| 额外依赖 | 无需安装 Python、PowerShell 7 或第三方模块 |

启动时会在本机编译内嵌的少量 C# 事件通知代码。运行依赖本机文件系统与 Windows 计划任务，不访问外部服务。

## 快速安装

1. 下载并解压项目，或者将仓库克隆到本地。
2. 以管理员身份打开 **64 位 Windows PowerShell**，进入项目根目录。
3. 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

`-ExecutionPolicy Bypass` 只作用于这次 PowerShell 进程，不修改系统的持久执行策略。

安装成功后会显示 `Installed and started: OneDriveAppGuard`。安装器会等待监听脚本完成首次清理，再报告成功。

### 安装结果

| 项目 | 默认值 |
| --- | --- |
| 安装目录 | `%ProgramFiles%\OneDriveAppGuard`，通常为 `C:\Program Files\OneDriveAppGuard` |
| 计划任务名称 | `OneDriveAppGuard` |
| 启动时机 | 系统启动；安装完成时也会立即启动 |
| 运行账户 | SYSTEM |
| 执行时限 | 不限制 |
| 异常退出重启 | 每隔一分钟重试，最多三次 |
| 电池供电 | 允许启动和继续运行 |
| 目录权限 | 管理员与 SYSTEM 可修改，普通用户可读取 |

项目名为 **onedrivePhotoBlock**；脚本、任务和安装目录使用 `OneDriveAppGuard` 标识。

安装文件独立于下载的源码目录。安装后可以移动源码目录；运行中的安装目录需要保持原位。

## 日志

日志路径由 `$PSScriptRoot` 确定，始终位于**实际运行的监听脚本所在目录**，不依赖当前工作目录。

默认安装后：

```text
C:\Program Files\OneDriveAppGuard\
├── Watch-OneDriveApp.ps1
├── Uninstall.ps1
├── README.md
├── OneDriveAppGuard.log
├── OneDriveAppGuard.log.1
└── OneDriveAppGuard.log.2
```

`.log` 是当前日志，`.log.1` 和 `.log.2` 是较早的记录。仅记录启动、监听状态变化、删除成功和异常，正常补查不写日志。

查看最近 30 行：

```powershell
Get-Content "$env:ProgramFiles\OneDriveAppGuard\OneDriveAppGuard.log" -Tail 30
```

日志中的 `Ready.` 表示首次检查与清理已完成。日志写入失败时，删除流程仍会继续；写入失败提示会限频。

## 查看状态、暂停与恢复

以下命令在管理员 Windows PowerShell 中执行。

查看任务：

```powershell
Get-ScheduledTask -TaskName OneDriveAppGuard -TaskPath '\' |
    Select-Object TaskName, State
```

正常运行时 `State` 为 `Running`。查看最近的任务执行结果：

```powershell
Get-ScheduledTaskInfo -TaskName OneDriveAppGuard -TaskPath '\'
```

暂停监听并取消下次开机启动：

```powershell
Disable-ScheduledTask -TaskName OneDriveAppGuard -TaskPath '\'
Stop-ScheduledTask -TaskName OneDriveAppGuard -TaskPath '\'
```

恢复监听和开机自启：

```powershell
Enable-ScheduledTask -TaskName OneDriveAppGuard -TaskPath '\'
Start-ScheduledTask -TaskName OneDriveAppGuard -TaskPath '\'
```

## 更新

取得新版本后，在新版本的源码根目录重新执行安装命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

安装器会停止原任务、更新安装文件、保留已有日志，并重新注册和启动任务。若同名任务的运行命令与本项目不符，安装器会停止更新并报告冲突。

## 卸载

在管理员 Windows PowerShell 中执行，默认保留日志：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramFiles\OneDriveAppGuard\Uninstall.ps1"
```

同时删除日志：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramFiles\OneDriveAppGuard\Uninstall.ps1" -RemoveLogs
```

卸载会停止并移除本项目的计划任务，按明确文件名移除安装文件。已删除的 OneDrive 照片程序不会由卸载脚本恢复。

## 工作原理

监听脚本使用 .NET [`FileSystemWatcher`](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher) 接收通知。事件回调只合并状态并唤醒处理流程；文件检查、进程核验和删除操作由同一个流程串行完成。

1. 建立目标目录与其父目录的监听，再检查目标文件。
2. 文件出现或被改名为目标文件时，尝试删除。
3. 遇到占用错误时，核验进程完整路径，再尝试结束进程并删除。
4. 失败时有限重试，持续失败时进入 60 秒等待。
5. 每 60 秒重新绑定监听并补查，处理目录替换和通知遗漏。

对目标及其上级路径检测到符号链接或目录联接时，会拒绝处理并记录原因；目标名称对应文件夹时也会拒绝删除。脚本不会为删除目标而自动接管 OneDrive 目录权限。

### 资源占用

本机一次 10 秒空闲样本中，CPU 读数约为单个逻辑核心的 `0.00%`，工作集约 `100 MiB`，包含 PowerShell 与 .NET 运行时。结果随环境变化，不代表固定上限。

## 测试

在项目源码根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Guard.ps1
```

完整测试需要允许创建 NTFS 目录联接；权限不足时，请使用管理员终端。测试只在项目内的 `.test-artifacts/` 创建独立目录和测试进程，不安装计划任务，也不操作真实 OneDrive 安装目录。

覆盖内容包括：

- 启动清理、创建和重命名触发。
- 文件占用后的重试，以及运行中目标进程的结束与删除。
- 其他路径的同名进程仍正常运行。
- 目录改名、删除、重建后的监听恢复。
- 文件夹与目录联接保护。
- 单实例、连续失败后的等待和异常结束后的重新启动。
- 日志目录、轮换数量、大小和空闲 CPU 占用。

结果保存在本次测试目录的 `results.json`。测试产物已加入 `.gitignore`。

监听脚本提供以下测试参数；安装任务使用默认值：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `-TestDirectory` | 不设置 | 在指定测试目录中处理固定文件名 `OneDrive.App.exe` |
| `-CheckIntervalSeconds` | `60` | 周期补查间隔，允许 2–3600 秒 |
| `-LogMaxBytes` | `1048576` | 单份日志轮换阈值，允许 1024–10485760 字节 |

## 构建发布包

在源码根目录执行，无需管理员权限：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1
```

脚本读取 `VERSION`，仅打包明确列出的源码、文档和测试文件，输出：

```text
dist/
├── onedrivePhotoBlock-v0.1.0.zip
└── onedrivePhotoBlock-v0.1.0.zip.sha256
```

重复构建会替换同版本的发布包。构建过程不会包含运行日志、测试产物或 Git 元数据。

`.github/workflows/verify.yml` 提供 Windows 上的自动测试与打包检查，在仓库收到 push、pull request 或手动触发时执行。工作流只进行验证，不发布 Release，也不部署到用户电脑。

## 项目结构

```text
onedrivePhotoBlock/
├── .github/workflows/verify.yml  # Windows 自动验证
├── .editorconfig               # 编辑器格式约定
├── .gitattributes              # Git 文本与换行规则
├── .gitignore                  # 排除日志和构建产物
├── CHANGELOG.md                # 版本记录
├── VERSION                     # 构建版本号
├── Install.ps1                 # 安装与更新
├── Watch-OneDriveApp.ps1        # 监听与清理
├── Uninstall.ps1               # 卸载
├── tests/Test-Guard.ps1         # 隔离测试
├── tools/Build-Release.ps1      # 生成发布包与校验值
└── README.md
```

## 常见问题

**安装提示需要管理员权限**

关闭当前终端，使用“以管理员身份运行”重新打开 64 位 Windows PowerShell，然后执行安装命令。

**安装器已经创建任务，但没有确认启动清理成功**

先查看安装目录中的日志，再查看计划任务状态。这个错误可能表示文件仍被占用、路径存在联接、权限不足，或启动超过了安装器的等待时间。修正原因后重新执行安装命令。

**目录不存在时是否会持续扫描磁盘？**

不会。脚本等待父目录通知，并定期检查指定路径；没有全盘扫描。

**为什么日志不在下载的源码文件夹？**

安装器把脚本复制到了安装目录。日志写在实际运行的脚本旁边，因此安装后的默认位置是 `%ProgramFiles%\OneDriveAppGuard`。

**能否保证文件一瞬间都不出现？**

不能。目录通知在文件系统操作发生后到达，删除也可能遇到占用。这个项目提供持续清理，而非执行前拦截。

## 参考与说明

清理思路参考 [nickydewestelinck / MicrosoftIntune 的 Remove-OneDrivePhotos](https://github.com/nickydewestelinck/MicrosoftIntune/tree/main/Scripts/Remove-OneDrivePhotos)。本项目独立实现持续监听、有限重试、同目录轮换日志和计划任务。

本项目由用户自行部署和管理，与 Microsoft 无隶属关系。OneDrive 是 Microsoft 的产品名称。
