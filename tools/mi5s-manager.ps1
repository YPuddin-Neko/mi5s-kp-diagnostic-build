# Mi5s reusable APatch tester / local Android Boot builder.
# Windows PowerShell 5.1+, GitHub CLI + kptools, adb/fastboot.
# No unattended flashing, booting, or upload of secrets / diagnostic logs.
$ToolVersion = '1.2.1'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = 'YPuddin-Neko/mi5s-kp-diagnostic-build'
$BootFile = Join-Path $BaseDir 'boot.img'
$ExpectedBootHash = 'd426cc8761e84fdfafcce2cd77899a2b9439d12b0c2807bf17f9c5962a518d97'
$CacheDir = Join-Path $BaseDir 'cache'
$ImageDir = Join-Path $BaseDir 'images'
$ReportDir = Join-Path $BaseDir 'reports'
$ConfigPath = Join-Path $BaseDir 'mi5s-local-config.json'
New-Item -ItemType Directory -Force -Path $CacheDir, $ImageDir, $ReportDir | Out-Null

$Config = @{ AdbFolder='D:\搞机\ADB'; LastImage=''; LastRunId=''; LastArtifact='' }
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $saved = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($k in @('AdbFolder','LastImage','LastRunId','LastArtifact')) {
            $property = $saved.PSObject.Properties[$k]
            if ($property -and $null -ne $property.Value) { $Config[$k] = [string]$property.Value }
        }
    } catch { Write-Host '配置文件无法读取，使用默认配置。' -ForegroundColor Yellow }
}
function Save-Config {
    $Config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
function Print-Step([string]$Label) {
    Write-Host ("`n==> " + $Label) -ForegroundColor Cyan
}
function Get-Tool([string]$Name, [string[]]$Candidates = @()) {
    foreach ($item in $Candidates) {
        if ($item -and (Test-Path -LiteralPath $item -PathType Leaf)) { return $item }
    }
    $hit = Get-Command ($Name + '.exe') -ErrorAction SilentlyContinue
    if ($hit) { return $hit.Source }
    $hit = Get-Command $Name -ErrorAction SilentlyContinue
    if ($hit) { return $hit.Source }
    throw "找不到 $Name。请安装或在工具菜单里设置 ADB 文件夹。"
}
function Capture([string]$Exe, [string[]]$Arguments, [switch]$AllowFailure) {
    $data = & $Exe @Arguments 2>$null | Out-String
    $exitcode = $LASTEXITCODE
    if (($exitcode -ne 0) -and (-not $AllowFailure)) {
        throw ("命令执行失败 (" + $exitcode + "): " + [IO.Path]::GetFileName($Exe))
    }
    return [string]$data
}
function Execute([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    $exitcode = $LASTEXITCODE
    if ($exitcode -ne 0) { throw ("命令执行失败 (" + $exitcode + "): " + [IO.Path]::GetFileName($Exe)) }
}
function Find-File([string]$Folder, [string]$Name) {
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($files.Count -eq 0) { throw "没有找到文件 $Name" }
    return $files[0].FullName
}
function Unpack-7z([string]$Archive, [string]$Destination) {
    $tools = @()
    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if ($tar) { $tools += ,@($tar.Source,'tar') }
    $seven = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($seven) { $tools += ,@($seven.Source,'7z') }
    foreach ($p in @('C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe')) {
        if (Test-Path -LiteralPath $p) { $tools += ,@($p,'7z') }
    }
    foreach ($t in $tools) {
        try {
            if ($t[1] -eq 'tar') {
                & $t[0] '-xf' $Archive '-C' $Destination | Out-Null
            } else {
                & $t[0] 'x' '-y' ('-o' + $Destination) $Archive | Out-Null
            }
            if (($LASTEXITCODE -eq 0) -and @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter 'kptools.exe').Count -gt 0) { return }
        } catch { }
    }
    throw '7z 解压失败。安装 7-Zip 后重试。'
}
function Get-Kptools([string]$GitHub) {
    $dir = Join-Path $CacheDir 'kptools-0139'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existing = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'kptools.exe' -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) { return $existing[0].FullName }
    $arc = Join-Path $dir 'kptools-msys2-win.7z'
    if (-not (Test-Path -LiteralPath $arc)) {
        Print-Step '下载 KernelPatch 0.13.9 官方 Windows kptools（仅首次）'
        Execute $GitHub @('release','download','0.13.9','--repo','bmax121/KernelPatch','--pattern','kptools-msys2-win.7z','--dir',$dir)
    }
    Unpack-7z $arc $dir
    return Find-File $dir 'kptools.exe'
}
function Get-RecentRuns([string]$GitHub) {
    $raw = Capture $GitHub @('api',("repos/" + $Repo + "/actions/runs?per_page=60"))
    $list = (ConvertFrom-Json -InputObject $raw).workflow_runs
    return @($list | Where-Object { $_.status -eq 'completed' -and $_.conclusion -eq 'success' -and $_.name -match '^Mi5s\b' } | Sort-Object -Property id -Descending)
}
function Select-Run([string]$GitHub, [bool]$Ask) {
    $runs = @(Get-RecentRuns $GitHub | Select-Object -First 15)
    if ($runs.Count -eq 0) { throw 'GitHub 尚无成功的 Mi5s 构建。' }
    if ($Ask) {
        Write-Host "`n最近成功的 GitHub Actions 构建："
        for ($i=0; $i -lt $runs.Count; $i++) {
            Write-Host ('  [' + ($i + 1) + '] ' + $runs[$i].id + '  ' + $runs[$i].name)
        }
        Write-Host '回车=最新成功版本；也可输入序号或完整 Run ID。'
        $answer = (Read-Host '选择').Trim()
    } else { $answer = '' }
    if (-not $answer) { return $runs[0] }
    if ($answer -match '^\d+$' -and [int64]$answer -ge 1 -and [int64]$answer -le $runs.Count) {
        return $runs[[int]$answer - 1]
    }
    if ($answer -notmatch '^\d{8,20}$') { throw 'Run ID/序号不合法。' }
    $raw = Capture $GitHub @('api',("repos/" + $Repo + "/actions/runs/" + $answer))
    $run = ConvertFrom-Json -InputObject $raw
    if ($run.status -ne 'completed' -or $run.conclusion -ne 'success') { throw '此 Run 尚未成功完成。' }
    return $run
}
function Get-RunArtifact([string]$GitHub, [string]$Id) {
    $raw = Capture $GitHub @('api',("repos/" + $Repo + "/actions/runs/" + $Id + "/artifacts?per_page=100"))
    $all = (ConvertFrom-Json -InputObject $raw).artifacts
    $matches = @($all | Where-Object { (-not $_.expired) -and $_.name -match '^mi5s-kpimg-' } )
    if ($matches.Count -eq 0) { throw ('Run ' + $Id + ' 没有找到未过期的 mi5s-kpimg 工件。') }
    if ($matches.Count -gt 1) { throw '同一 Run 中发现多个 kpimg 工件，停止以防下载错误。' }
    return $matches[0]
}
function Test-AndroidHeader([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('没有找到 Boot 镜像：' + $Path) }
    $f = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 8
        if ($f.Read($bytes,0,8) -ne 8 -or [Text.Encoding]::ASCII.GetString($bytes) -ne 'ANDROID!') {
            throw '不是 Android Boot 镜像，拒绝继续。'
        }
    } finally { $f.Dispose() }
}
function Build-Image([bool]$AskRun) {
    if (-not (Test-Path -LiteralPath $BootFile)) { throw '缺少与工具放在同一目录的 boot.img。' }
    Test-AndroidHeader $BootFile
    $hash = (Get-FileHash -LiteralPath $BootFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $ExpectedBootHash) { throw '纯净 Boot SHA-256 不匹配，停止操作（不支持其他 ROM）。' }
    $gh = Get-Tool 'gh'
    Print-Step '查询你 GitHub 仓库的成功构建'
    $run = Select-Run $gh $AskRun
    $id = [string]$run.id
    $artifact = Get-RunArtifact $gh $id
    $artifactName = [string]$artifact.name
    Write-Host ('选择: ' + $run.name + ' | Run ' + $id + ' | ' + $artifactName) -ForegroundColor Green
    $dir = Join-Path $CacheDir ('run-' + $id)
    $artifactDir = Join-Path $dir 'artifact'
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $kpimage = @(Get-ChildItem -LiteralPath $artifactDir -Recurse -File -Filter 'kpimg' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($kpimage.Count -eq 0) {
        Print-Step '下载已编译的 kpimg（同一版本仅下载一次）'
        Execute $gh @('run','download',$id,'--repo',$Repo,'--name',$artifactName,'--dir',$artifactDir)
    }
    $kpimg = Find-File $artifactDir 'kpimg'
    if ((Get-Item -LiteralPath $kpimg).Length -lt 100000) { throw '下载的 kpimg 文件异常，已停止。' }
    $kptools = Get-Kptools $gh
    $secure = $null
    $key = $null
    Print-Step '输入 SuperKey（仅本地用于打包，工具不会保存或上传）'
    $secure = Read-Host 'SuperKey' -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    if ($key.Length -lt 8 -or $key.Length -gt 63 -or $key -notmatch '^[\x21-\x7e]+$' -or
        $key.Contains([char]34) -or $key.Contains([char]92)) {
        $key = $null
        throw 'SuperKey 须为 8~63 个可打印 ASCII 字符，不含空格、双引号和反斜杠。'
    }
    $slug = $artifactName -replace '^mi5s-kpimg-', ''
    $slug = $slug -replace '[^A-Za-z0-9_\-]', '_'
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0,60) }
    $output = Join-Path $ImageDir ('mi5s-' + $slug + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.img')
    Print-Step '本地修补纯净 Boot（此步骤不会操作手机）'
    try {
        # kptools accepts the SuperKey as a process argument. Avoid running
        # this tool with process-command-line logging or shell transcripts.
        Execute $kptools @('-p','-i',$BootFile,'-k',$kpimg,'-s',$key,'-o',$output)
    } finally { $key = $null; $secure = $null }
    Test-AndroidHeader $output
    $file = Get-Item -LiteralPath $output
    if ($file.Length -lt 18000000 -or $file.Length -gt 30000000) { throw '镜像大小不在预期范围内。' }
    $newHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    $Config.LastImage = $output
    $Config.LastRunId = $id
    $Config.LastArtifact = $artifactName
    Save-Config
    Write-Host "`n生成成功：" -ForegroundColor Green
    Write-Host $output -ForegroundColor Green
    Write-Host ('SHA-256: ' + $newHash)
    Write-Host '注意：未自动重启/启动/刷机。新版本只能先使用 fastboot boot 临时测试。' -ForegroundColor Yellow
}
function Get-AndroidTools {
    $folder = $Config.AdbFolder
    $adb = Get-Tool 'adb' @((Join-Path $folder 'adb.exe'),(Join-Path $BaseDir 'platform-tools\adb.exe'))
    $fastboot = $null
    try { $fastboot = Get-Tool 'fastboot' @((Join-Path $folder 'fastboot.exe'),(Join-Path $BaseDir 'platform-tools\fastboot.exe')) }
    catch { }
    return @{ adb=$adb; fastboot=$fastboot }
}
function Get-DeviceSerial([string]$adb) {
    $txt = Capture $adb @('devices')
    $ids = @([regex]::Matches($txt,'(?m)^([^\s]+)\s+device\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($ids.Count -ne 1) { throw ('ADB 已连接设备数不是 1（当前 ' + $ids.Count + '）。检查授权/USB/多设备。') }
    return [string]$ids[0]
}
function Adb-Shell([string]$adb, [string]$serial, [string]$script) {
    # In Windows PowerShell 5.1, native stderr can become a terminating error
    # when the session has ErrorActionPreference=Stop. A missing virtual su
    # is a DIAGNOSTIC RESULT, not a reason to abandon the rest of the report.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $adb '-s' $serial 'shell' $script 2>$null | Out-String
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { return '' }
        return ([string]$output).Trim()
    } catch {
        # Never print raw native stderr: init or other log lines may contain keys.
        return ''
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}
function Get-TestResult {
    $tools = Get-AndroidTools
    $adb = $tools.adb
    $serial = Get-DeviceSerial $adb
    Print-Step '检查 Android / APatch / Root / 内核异常'

    # Device commands here contain no grep pipelines or quote-sensitive regex.
    # Filter raw output LOCALLY in PowerShell instead of passing regex through
    # Windows -> adb.exe -> /system/bin/sh. Do not persist raw logs.
    $time = Adb-Shell $adb $serial 'cat /proc/uptime'
    $booted = Adb-Shell $adb $serial 'getprop sys.boot_completed'
    $apd = Adb-Shell $adb $serial 'pidof apd'
    $su = Adb-Shell $adb $serial '/system/bin/su -c id'
    if ([string]::IsNullOrWhiteSpace($su)) { $su = '(unavailable)' }
    $selinux = Adb-Shell $adb $serial 'getenforce'
    $rom = Adb-Shell $adb $serial 'getprop ro.product.device'
    $apdInfo = Adb-Shell $adb $serial 'ls -lZ /data/adb/apd'

    # Security: raw dmesg/logcat are only processed in RAM. They are NEVER
    # dumped to files, printed, or copied to clipboard. Even init command
    # lines may carry the SuperKey.
    $dmesgRaw = Adb-Shell $adb $serial 'dmesg'
    $dmesgAvailable = -not [string]::IsNullOrWhiteSpace($dmesgRaw)
    $errorsSafe = @()
    $versionSafe = @()
    foreach ($line in ($dmesgRaw -split "`r?`n")) {
        if ($line -match 'MI5S_V[0-9]+_[A-Za-z0-9_]+') {
            $versionSafe += $Matches[0]
        }
        $issue = $null
        if ($line -match '(?i)rcu.{0,160}stall') { $issue = 'RCU stall' }
        elseif ($line -match '(?i)kernel panic') { $issue = 'kernel panic' }
        elseif ($line -match '(?i)kernel BUG') { $issue = 'kernel BUG' }
        elseif ($line -match '(?i)hung task') { $issue = 'hung task' }
        elseif ($line -match '(?i)use.after.free') { $issue = 'use-after-free warning' }
        if ($issue) {
            $tm = [regex]::Match($line, '^\[\s*\d+(?:\.\d+)?\]')
            $errorsSafe += (($tm.Value + ' ' + $issue).Trim())
        }
    }
    $errorsSafe = @($errorsSafe | Select-Object -Last 20)
    $versionSafe = @($versionSafe | Select-Object -Unique -Last 20)
    $dmesgRaw = $null

    $execFails = 0
    $status127 = 0
    # Full logcat is read locally and immediately discarded after counting
    # anchored init errors. Never include the init service's command string.
    $logcatRaw = Adb-Shell $adb $serial 'logcat -b all -d -v brief'
    $logcatAvailable = -not [string]::IsNullOrWhiteSpace($logcatRaw)
    foreach ($line in ($logcatRaw -split "`r?`n")) {
        if ($line -match '^E/init\s*\(\s*0\): cannot execv') { $execFails++ }
        if ($line -match '^I/init\s*\(\s*0\): Service .*exited with status 127') { $status127++ }
    }
    $logcatRaw = $null

    # PASS checks only APD bootstrap + shell root; it does not verify third-party authorization.
    $healthy = $booted -eq '1' -and -not [string]::IsNullOrWhiteSpace($apd) -and
        $su -match 'uid=0\(root\)' -and $su -match 'u:r:magisk:s0' -and
        $errorsSafe.Count -eq 0 -and $dmesgAvailable -and $logcatAvailable
    $status = if ($healthy) { 'PASS' } elseif ($booted -ne '1') { 'BOOT_INCOMPLETE' }
        elseif (-not $dmesgAvailable -or -not $logcatAvailable) { 'INCOMPLETE' }
        else { 'FAIL' }
    $result = [ordered]@{
        timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        status=$status
        device=$rom
        uptime=$time
        boot_completed=$booted
        apd_pid=$apd
        su_id=$su
        selinux=$selinux
        apd_file=$apdInfo
        kernel_issue_lines=$errorsSafe
        dmesg_collected=$dmesgAvailable
        logcat_collected=$logcatAvailable
        version_markers=$versionSafe
        init_execv_failures_seen=$execFails
        init_status_127_seen=$status127
        last_built_run=$Config.LastRunId
        last_built_artifact=$Config.LastArtifact
    }
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $base = Join-Path $ReportDir ('mi5s-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($base+'.json') -Encoding UTF8
    $lines = @(
        ('Status: ' + $status),
        ('Device: ' + $rom),
        ('Uptime: ' + $time),
        ('Boot completed: ' + $booted),
        ('APD PID: ' + $(if ($apd) { $apd } else { '(none)' })),
        ('SU: ' + $su),
        ('SELinux: ' + $selinux),
        ('APD file: ' + $apdInfo),
        ('Kernel problems: ' + $errorsSafe.Count),
        ('Kernel log collected: ' + $dmesgAvailable),
        ('Android log collected: ' + $logcatAvailable),
        ('Init execv failures seen: ' + $execFails),
        ('Init status 127 seen: ' + $status127),
        ('Version markers:'),
        ($versionSafe -join "`r`n"),
        ('Kernel issue lines:'),
        ($errorsSafe -join "`r`n")
    )
    $lines | Set-Content -LiteralPath ($base+'.txt') -Encoding UTF8
    Write-Host "`n------------------------------------------"
    Write-Host ('Result: ' + $status) -ForegroundColor $(if ($healthy) { 'Green' } else { 'Yellow' })
    Write-Host ('Uptime: ' + $time + ' | Android boot: ' + $booted)
    Write-Host ('APD: ' + $(if ($apd) { $apd } else { '(not running)' }))
    Write-Host ('Root: ' + $su)
    Write-Host ('Kernel problems: ' + $errorsSafe.Count + ' | init execv errors: ' + $execFails + ' | status 127: ' + $status127)
    Write-Host ('Diagnostics collected: dmesg=' + $dmesgAvailable + ', logcat=' + $logcatAvailable)
    Write-Host ('Version marker(s): ' + ($versionSafe -join ' ; '))
    Write-Host ('Report: ' + $base + '.txt') -ForegroundColor Cyan
    Write-Host '------------------------------------------'
    $summary = ('Mi5s ' + $status + ' | uptime=' + $time + ' | boot=' + $booted + ' | apd=' + $apd + ' | su=' + $su + ' | kernelProblems=' + $errorsSafe.Count + ' | execvFailures=' + $execFails + ' | status127=' + $status127 + ' | logs=' + [string]$dmesgAvailable + '/' + [string]$logcatAvailable + ' | versions=' + ($versionSafe -join ' ; '))
    try { Set-Clipboard -Value $summary -ErrorAction Stop; Write-Host '精简结果已复制到剪贴板，可直接粘贴给 ChatGPT。' -ForegroundColor Green }
    catch { Write-Host '未能复制剪贴板，请手动复制上面的精简结果。' -ForegroundColor Yellow }
    return $result
}
function Boot-Temporarily {
    $image = $Config.LastImage
    if (-not $image -or -not (Test-Path -LiteralPath $image)) {
        $image = Read-Host '输入已有 Boot 镜像完整路径'
    } else {
        Write-Host ('上次生成：' + $image)
        $picked = (Read-Host '回车使用上次镜像，或输入其他完整路径').Trim()
        if ($picked) { $image = $picked.Trim([char]34) }
    }
    Test-AndroidHeader $image
    Write-Host "`n临时启动可能造成重启/卡开机。必须事先有纯净 Boot、Fastboot 恢复手段。" -ForegroundColor Yellow
    Write-Host '本功能仅执行 fastboot boot，绝不会执行 fastboot flash。' -ForegroundColor Yellow
    $ok = Read-Host '确认临时启动？输入 BOOT（其他任何输入取消）'
    if ($ok -cne 'BOOT') { Write-Host '已取消。'; return }
    $tools = Get-AndroidTools
    if (-not $tools.fastboot) { throw '没有找到 fastboot.exe。请设置 ADB 文件夹。' }
    $fastboot = $tools.fastboot
    $ftext = Capture $fastboot @('devices') -AllowFailure
    $fids = @([regex]::Matches($ftext,'(?m)^([^\s]+)\s+fastboot\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($fids.Count -eq 0) {
        $serial = Get-DeviceSerial $tools.adb
        Print-Step '通过 ADB 进入 Bootloader'
        Execute $tools.adb @('-s',$serial,'reboot','bootloader')
        for ($i=0; $i -lt 35; $i++) {
            Start-Sleep -Seconds 2
            $ftext = Capture $fastboot @('devices') -AllowFailure
            $fids = @([regex]::Matches($ftext,'(?m)^([^\s]+)\s+fastboot\s*$') | ForEach-Object { $_.Groups[1].Value })
            if ($fids.Count -gt 0) { break }
        }
    }
    if ($fids.Count -ne 1) { throw ('Fastboot 设备数量异常：' + $fids.Count + '。不执行启动。') }
    Print-Step '执行 fastboot boot（临时、不刷写）'
    Execute $fastboot @('-s',[string]$fids[0],'boot',$image)
    Print-Step '等待系统启动后自动检查（最多约 4 分钟）'
    $connected = $false
    for ($i=0; $i -lt 55; $i++) {
        Start-Sleep -Seconds 4
        $devices = Capture $tools.adb @('devices') -AllowFailure
        $ids = @([regex]::Matches($devices,'(?m)^([^\s]+)\s+device\s*$') | ForEach-Object { $_.Groups[1].Value })
        if ($ids.Count -eq 1) {
            $booted = Adb-Shell $tools.adb ([string]$ids[0]) 'getprop sys.boot_completed'
            if ($booted -eq '1') { $connected = $true; break }
        }
    }
    if (-not $connected) { throw '设备未在规定检查窗口内完成启动；请手动检查手机并使用纯净 Boot 恢复。' }
    Start-Sleep -Seconds 8
    $null = Get-TestResult
}
function Update-Manager {
    # Fetch the update from the user's GitHub repository. It is deliberately
    # opt-in: never execute downloaded code without an explicit confirmation.
    $gh = Get-Tool 'gh'
    Print-Step '检查 GitHub 上的自动化工具更新'
    $api = 'repos/' + $Repo + '/contents/tools/mi5s-manager.ps1?ref=main'
    $raw = Capture $gh @('api',$api)
    $data = ConvertFrom-Json -InputObject $raw
    if (-not $data.content -or $data.encoding -ne 'base64') { throw 'GitHub 返回了异常的脚本内容。' }
    $bytes = [Convert]::FromBase64String(($data.content -replace '\s', ''))
    $incoming = [Text.Encoding]::UTF8.GetString($bytes)
    $incoming = $incoming.TrimStart([char]0xFEFF)
    if ($incoming -notmatch '(?m)^# Mi5s reusable APatch tester') { throw '脚本标识验证失败，拒绝更新。' }
    $m = [regex]::Match($incoming, "(?m)^\`$ToolVersion = '([0-9]+\.[0-9]+\.[0-9]+)'$")
    if (-not $m.Success) { throw '新版本缺少 ToolVersion 标识。' }
    $newVersion = $m.Groups[1].Value
    Write-Host ('当前版本：' + $ToolVersion + '；GitHub 版本：' + $newVersion)
    if ([version]$newVersion -le [version]$ToolVersion) { Write-Host '已经是最新版本。'; return }
    $ok = Read-Host '是否更新工具脚本？输入 UPDATE 确认'
    if ($ok -cne 'UPDATE') { Write-Host '已取消更新。'; return }
    $path = Join-Path $BaseDir 'mi5s-manager.ps1'
    $tmp = Join-Path $BaseDir 'mi5s-manager.update.tmp'
    # Windows PowerShell 5.1 reads UTF-8 without BOM as an ANSI code page.
    # Validate the downloaded script before replacing the active installation.
    $parseTokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        $incoming, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'GitHub 脚本语法验证失败，拒绝覆盖当前工具。' }
    [IO.File]::WriteAllText($tmp, $incoming, (New-Object System.Text.UTF8Encoding($true)))
    try {
        Copy-Item -LiteralPath $tmp -Destination $path -Force
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    Write-Host ('更新完成：v' + $newVersion + '。关闭窗口重新双击 RUN.cmd 后生效。') -ForegroundColor Green
}
function Set-AdbFolder {
    $path = (Read-Host '输入包含 adb.exe 和 fastboot.exe 的文件夹完整路径').Trim([char]34)
    if (-not (Test-Path -LiteralPath (Join-Path $path 'adb.exe'))) { throw '此文件夹没有 adb.exe。' }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'fastboot.exe'))) { throw '此文件夹没有 fastboot.exe。' }
    $Config.AdbFolder = $path
    Save-Config
    Write-Host ('已保存 ADB 目录：' + $path) -ForegroundColor Green
}
function Main {
    Write-Host ('Mi 5s / APatch 可复用自动化工具 v' + $ToolVersion) -ForegroundColor Cyan
    Write-Host ('GitHub：' + $Repo)
    Write-Host '本工具不会自动刷入任何 Boot，也不会上传任何日志或密钥。'
    while ($true) {
        Write-Host "`n============ 功能菜单 ============"
        Write-Host '[1] 自动下载 GitHub 最新成功版本并生成 Boot'
        Write-Host '[2] 选择已有 GitHub 版本（Run ID）生成 Boot'
        Write-Host '[3] 一键检查当前手机并保存报告（自动复制精简结果）'
        Write-Host '[4] 临时 fastboot boot + 自动检查（须输入 BOOT 确认）'
        Write-Host ('[5] 修改 ADB 目录（当前：' + $Config.AdbFolder + '）')
        Write-Host '[6] 从 GitHub 检查并更新工具本身（不替换 Boot）'
        Write-Host '[0] 退出'
        $choice = (Read-Host '选择').Trim()
        try {
            switch ($choice) {
                '1' { Build-Image $false; break }
                '2' { Build-Image $true; break }
                '3' { $null = Get-TestResult; break }
                '4' { Boot-Temporarily; break }
                '5' { Set-AdbFolder; break }
                '6' { Update-Manager; break }
                '0' { return }
                default { Write-Host '请输入菜单序号。' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host ('FAILED: ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host '如果是临时启动失败，请不要尝试 flash；使用原始 Boot 恢复。' -ForegroundColor Yellow
        }
    }
}
Main