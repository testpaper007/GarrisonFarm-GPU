$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$UTF8 = New-Object System.Text.UTF8Encoding($false)

$HERE = (Get-Location).Path
$MODE = if ($args.Count -ge 1 -and $args[0]) { [string]$args[0] } else { 'install' }
$TARGET_ARG = if ($args.Count -ge 2) { [string]$args[1] } else { '' }

function Write-Head($text) {
    Write-Host ''
    Write-Host ('=' * 56) -ForegroundColor DarkGray
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 56) -ForegroundColor DarkGray
}

function Test-AppDir($dir) {
    if (-not $dir) { return $false }
    if (-not (Test-Path (Join-Path $dir 'GarrisonFarm.exe'))) { return $false }
    return (Test-Path (Join-Path $dir '_internal\onnxruntime\capi\onnxruntime_pybind11_state.pyd'))
}

function Get-Candidates {
    $roots = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents'),
        'D:\', 'E:\'
    )
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $depth = if ($r.Length -le 4) { 3 } else { 4 }
        try {
            Get-ChildItem -Path $r -Filter 'GarrisonFarm.exe' -Recurse -Depth $depth -File -ErrorAction SilentlyContinue |
                ForEach-Object { $d = $_.DirectoryName; if ((Test-AppDir $d) -and -not $all.Contains($d)) { $all.Add($d) } }
        } catch { }
    }
    return $all.ToArray()
}

$dir = ''

if ($TARGET_ARG -and (Test-AppDir $TARGET_ARG)) {
    $dir = (Resolve-Path $TARGET_ARG).Path
} elseif (Test-AppDir $HERE) {
    $dir = $HERE
} else {
    Write-Head 'GarrisonFarm GPU 加速补丁'
    Write-Host '正在查找 GarrisonFarm 程序目录…' -ForegroundColor Yellow
    $cands = Get-Candidates
    if ($cands.Count -eq 0) {
        Write-Host '没有自动找到程序目录。' -ForegroundColor Yellow
        $manual = Read-Host '请把 GarrisonFarm 文件夹拖到这里（或粘贴路径）后回车'
        $manual = $manual.Trim().Trim('"').Trim("'")
        if (Test-AppDir $manual) { $dir = (Resolve-Path $manual).Path }
    } elseif ($cands.Count -eq 1) {
        Write-Host "找到：$($cands[0])" -ForegroundColor Green
        $dir = $cands[0]
    } else {
        Write-Host '找到多个安装目录，请选择要打补丁的那一个：' -ForegroundColor Yellow
        for ($i = 0; $i -lt $cands.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $cands[$i]) }
        $pick = Read-Host '输入序号后回车（直接回车退出）'
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $cands.Count) {
            $dir = $cands[[int]$pick - 1]
        }
    }
}

if (-not $dir) {
    Write-Host ''
    Write-Host '未选定程序目录，已退出。' -ForegroundColor Red
    exit 1
}

$internal   = Join-Path $dir '_internal'
$ortDir     = Join-Path $internal 'onnxruntime'
$ortCapi    = Join-Path $ortDir 'capi'
$ortBackup  = Join-Path $internal 'onnxruntime_cpu_backup'
$cfgPath    = Join-Path $internal 'rapidocr_onnxruntime\config.yaml'
$cfgBackup  = Join-Path $internal 'rapidocr_onnxruntime\config.yaml.cpu_backup'
$srcFiles   = Join-Path $HERE 'gpu_files\onnxruntime\capi'

# 运行中不允许改动：文件被占用会写坏
$proc = Get-Process GarrisonFarm -ErrorAction SilentlyContinue
if ($proc -and $env:GF_FORCE -ne '1') {
    Write-Host ''
    Write-Host '检测到 GarrisonFarm 正在运行（PID: ' -NoNewline -ForegroundColor Red
    Write-Host (($proc | ForEach-Object { $_.Id }) -join ', ') -NoNewline -ForegroundColor Red
    Write-Host '）。' -ForegroundColor Red
    Write-Host '请先关闭它的黑色命令行窗口（或按 Ctrl+C 停止），再重新运行本补丁。' -ForegroundColor Yellow
    exit 1
}

Write-Head 'GarrisonFarm GPU 加速补丁'
Write-Host "程序目录：$dir" -ForegroundColor Green

switch ($MODE) {

    'install' {
        if (-not (Test-Path (Join-Path $srcFiles 'DirectML.dll'))) {
            Write-Host "补丁文件缺失：$srcFiles" -ForegroundColor Red
            Write-Host '请保持本补丁文件夹完整（gpu_files 不能被删）。' -ForegroundColor Yellow
            exit 1
        }

        Write-Host ''
        Write-Host '[1/3] 备份原版 CPU 推理库…' -ForegroundColor Cyan
        if (Test-Path $ortBackup) {
            Write-Host '      已存在备份，跳过（如需重建请先删除 _internal\onnxruntime_cpu_backup）' -ForegroundColor DarkGray
        } else {
            Copy-Item -Path $ortDir -Destination $ortBackup -Recurse -Force
            Write-Host '      完成 -> _internal\onnxruntime_cpu_backup' -ForegroundColor DarkGray
        }

        Write-Host '[2/3] 替换为 DirectML(GPU) 推理库…' -ForegroundColor Cyan
        Get-ChildItem -Path $srcFiles -File | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination (Join-Path $ortCapi $_.Name) -Force
            Write-Host ("      " + $_.Name) -ForegroundColor DarkGray
        }

        Write-Host '[3/3] 打开 DirectML 开关…' -ForegroundColor Cyan
        if (-not (Test-Path $cfgPath)) {
            Write-Host "      找不到 $cfgPath" -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path $cfgBackup)) { Copy-Item $cfgPath $cfgBackup -Force }
        $text = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
        $new = $text -replace 'use_dml:\s*false', 'use_dml: true'
        if ($new -notmatch 'use_dml:\s*true') {
            Write-Host '      配置里没有 use_dml 字段，这个版本可能不支持，已停止。' -ForegroundColor Red
            exit 1
        }
        [IO.File]::WriteAllText($cfgPath, $new, $UTF8)
        Write-Host ("      已开启 use_dml：共 " + ([regex]::Matches($new, 'use_dml: true')).Count + ' 处（检测/方向/识别）') -ForegroundColor DarkGray

        # 顺手把 CPU 线程数设为固定值，万一 GPU 不可用回落到 CPU 也不至于占满全部核心
        $sess = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
        $sess = $sess -replace 'intra_op_num_threads: &intra_nums -1', 'intra_op_num_threads: &intra_nums 4'
        [IO.File]::WriteAllText($cfgPath, $sess, $UTF8)

        Write-Host ''
        Write-Host '补丁安装完成。' -ForegroundColor Green
        Write-Host ''
        Write-Host '怎么确认真的在用 GPU：' -ForegroundColor Yellow
        Write-Host '  正常运行「开始刷角标.bat」，启动日志里出现下面这行就说明生效：'
        Write-Host '      try to use DirectML as primary provider' -ForegroundColor White
        Write-Host '  同时任务管理器里 GarrisonFarm.exe 的 CPU 应该只有 1 个核心上下。'
        Write-Host ''
        Write-Host '想改回原样：运行「还原CPU版.bat」。' -ForegroundColor DarkGray
    }

    'restore' {
        Write-Host ''
        if (Test-Path $ortBackup) {
            Write-Host '[1/2] 还原 CPU 推理库…' -ForegroundColor Cyan
            Get-ChildItem -Path $ortBackup -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($ortBackup.Length).TrimStart('\')
                $dst = Join-Path $ortDir $rel
                $dstDir = Split-Path -Parent $dst
                if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
                Copy-Item $_.FullName $dst -Force
            }
            $directml = Join-Path $ortCapi 'DirectML.dll'
            if (Test-Path $directml) { Remove-Item $directml -Force }
            Write-Host '      完成' -ForegroundColor DarkGray
        } else {
            Write-Host '没有找到备份，无法自动还原。' -ForegroundColor Red
            Write-Host '可以重新下载 Release 覆盖 _internal 文件夹。' -ForegroundColor Yellow
            exit 1
        }

        Write-Host '[2/2] 还原配置…' -ForegroundColor Cyan
        if (Test-Path $cfgBackup) {
            Copy-Item $cfgBackup $cfgPath -Force
            Remove-Item $cfgBackup -Force
            Write-Host '      完成' -ForegroundColor DarkGray
        } else {
            $text = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
            $text = $text -replace 'use_dml:\s*true', 'use_dml: false'
            $text = $text -replace 'intra_op_num_threads: &intra_nums 4', 'intra_op_num_threads: &intra_nums -1'
            [IO.File]::WriteAllText($cfgPath, $text, $UTF8)
            Write-Host '      按默认值改写完成' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '已还原为纯 CPU 模式。' -ForegroundColor Green
    }

    'threads' {
        Write-Host ''
        Write-Host '把 CPU 推理线程数限制住：GPU 不可用时的备用方案。' -ForegroundColor Yellow
        Write-Host '  1 = 2 线程（省 CPU，识别变慢）'
        Write-Host '  2 = 4 线程（折中，推荐）'
        Write-Host '  3 = 6 线程'
        Write-Host '  4 = 恢复默认（不限制，占满核心）'
        $pick = Read-Host '请输入 1~4'
        $val = switch ($pick) { '1' { 2 } '2' { 4 } '3' { 6 } '4' { -1 } default { $null } }
        if ($null -eq $val) { Write-Host '输入无效，已退出。' -ForegroundColor Red; exit 1 }
        if (-not (Test-Path $cfgBackup)) { Copy-Item $cfgPath $cfgBackup -Force }
        $text = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
        $text = $text -replace 'intra_op_num_threads: &intra_nums -?\d+', "intra_op_num_threads: &intra_nums $val"
        [IO.File]::WriteAllText($cfgPath, $text, $UTF8)
        Write-Host "已设置为 $val（-1 表示不限制）。" -ForegroundColor Green
    }

    default {
        Write-Host "未知模式：$MODE" -ForegroundColor Red
        exit 1
    }
}
