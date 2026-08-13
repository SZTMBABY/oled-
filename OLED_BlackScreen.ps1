Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows 11 DWM 属性 API
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
"@

# 电源管理：阻止系统休眠/睡眠
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class PowerHelper {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS        = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED   = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED  = 0x00000002;
}
"@

# DPI 感知（Per-Monitor V2）：高缩放屏幕下窗口与文字不再模糊
try { [DpiHelper]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null }
catch { try { [DpiHelper]::SetProcessDPIAware() | Out-Null } catch {} }

# === MD3 缓动曲线：cubic-bezier(x1,y1,x2,y2) 求值（牛顿迭代解 t，再求 y） ===
function Get-Bezier([double]$x1, [double]$y1, [double]$x2, [double]$y2, [double]$x) {
    $cx = 3.0 * $x1; $bx = 3.0 * ($x2 - $x1) - $cx; $ax = 1.0 - $cx - $bx
    $cy = 3.0 * $y1; $by = 3.0 * ($y2 - $y1) - $cy; $ay = 1.0 - $cy - $by
    $t = $x
    for ($i = 0; $i -lt 10; $i++) {
        $xCur = (($ax * $t + $bx) * $t + $cx) * $t
        if ([Math]::Abs($xCur - $x) -lt 1e-6) { break }
        $dxdt = (3.0 * $ax * $t + 2.0 * $bx) * $t + $cx
        if ($dxdt -eq 0.0) { break }
        $t -= ($xCur - $x) / $dxdt
    }
    if ($t -lt 0.0) { $t = 0.0 }; if ($t -gt 1.0) { $t = 1.0 }
    return (($ay * $t + $by) * $t + $cy) * $t
}

# === 倒计时窗口：原生 Win32 对话框样式 ===
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ShowIcon = $false
$form.Text = "黑屏保护"
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(0x21, 0x1F, 0x26)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.DoubleBuffered = $true

# === DPI 缩放：布局按 96dpi 基准设计，随屏幕缩放整体放大，避免文字重叠 ===
$g0 = $form.CreateGraphics()
$dpiX = $g0.DpiX
$g0.Dispose()
$script:scale = $dpiX / 96.0

# 逻辑布局（96dpi 基准尺寸），统一乘以缩放系数
$script:winW  = [int](300 * $script:scale)
$script:winH  = [int](246 * $script:scale)
$script:lblW  = [int](284 * $script:scale)
$script:cx    = [int](150 * $script:scale)   # 数字中心
$script:cy    = [int](70  * $script:scale)
$script:drawRect = New-Object System.Drawing.Rectangle(0, 0, $script:winW, [int](140 * $script:scale))

$form.Size = New-Object System.Drawing.Size($script:winW, $script:winH)

$script:number      = 3
$script:blacked     = $false
$countdownFont = New-Object System.Drawing.Font("Segoe UI", 56.0, [System.Drawing.FontStyle]::Bold)

# === 窗口打开动画：MD3 Standard decelerate 淡入（250ms） ===
$fadeSW = [System.Diagnostics.Stopwatch]::StartNew()
$fadeTimer = New-Object System.Windows.Forms.Timer
$fadeTimer.Interval = 15
$fadeTimer.Add_Tick({
    $t = $fadeSW.Elapsed.TotalMilliseconds / 250.0
    if ($t -ge 1.0) {
        $form.Opacity = 1.0
        $fadeTimer.Stop()
    } else {
        $e = Get-Bezier 0 0 0 1 $t
        $form.Opacity = 0.0 + 1.0 * $e
    }
})

# 窗口显示后：深色标题栏 + 白色标题文字 + 深色边框 + 播放动画
$form.Add_Shown({
    $captionColor = 0x00211F26
    [DwmHelper]::DwmSetWindowAttribute($form.Handle, 35, [ref]$captionColor, 4)
    $textColor = 0x00FFFFFF
    [DwmHelper]::DwmSetWindowAttribute($form.Handle, 36, [ref]$textColor, 4)
    $borderColor = 0x00333333
    [DwmHelper]::DwmSetWindowAttribute($form.Handle, 37, [ref]$borderColor, 4)

    $fadeSW.Restart()
    $fadeTimer.Start()

    # 淡入淡出计时
    $script:secondSW.Restart()
    $animTimer.Start()
})

# === 倒计时数字：Paint 绘制（AntiAlias + alpha 淡入淡出） ===
$form.Add_Paint({
    if ($script:blacked) { return }
    $g = $_.Graphics
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    $cx = $script:cx
    $cy = $script:cy
    $text = [string]$script:number
    $sz = $g.MeasureString($text, $countdownFont)

    # 基于秒内进度计算 alpha：前 25% 淡入，后 25% 淡出，中间全显
    $t = $script:secondSW.Elapsed.TotalMilliseconds / 1000.0
    if ($t -lt 0.0) { $t = 0.0 }; if ($t -gt 1.0) { $t = 1.0 }
    $alpha = 0.0
    if ($t -lt 0.25) { $alpha = $t / 0.25 }
    elseif ($t -lt 0.75) { $alpha = 1.0 }
    else { $alpha = (1.0 - $t) / 0.25 }
    $ab = [int](255 * $alpha)
    if ($ab -lt 0) { $ab = 0 }; if ($ab -gt 255) { $ab = 255 }

    # 橙黄色 #FFE199 + alpha 透明度
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ab, 0xFF, 0xE1, 0x99))
    $g.DrawString($text, $countdownFont, $brush, [single]($cx - $sz.Width / 2), [single]($cy - $sz.Height / 2))
    $brush.Dispose()
})

# === 数字淡入淡出动画（15ms 定时器，每帧重绘） ===
$script:secondSW = [System.Diagnostics.Stopwatch]::StartNew()
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 15
$animTimer.Add_Tick({ $form.Invalidate($script:drawRect) })

# 主提示
$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = "即将进入黑屏保护"
$lblTip.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$lblTip.ForeColor = [System.Drawing.Color]::FromArgb(0xCA, 0xC4, 0xD0)
$lblTip.TextAlign = 'MiddleCenter'
$lblTip.AutoSize = $false
$lblTip.Location = New-Object System.Drawing.Point(0, [int](125 * $script:scale))
$lblTip.Size = New-Object System.Drawing.Size($script:lblW, [int](28 * $script:scale))
$form.Controls.Add($lblTip)

# 副提示
$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "移动鼠标或按任意键可取消"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(0x93, 0x8F, 0x99)
$lblSub.TextAlign = 'MiddleCenter'
$lblSub.AutoSize = $false
$lblSub.Location = New-Object System.Drawing.Point(0, [int](151 * $script:scale))
$lblSub.Size = New-Object System.Drawing.Size($script:lblW, [int](24 * $script:scale))
$form.Controls.Add($lblSub)

# Github 署名
$lblGithub = New-Object System.Windows.Forms.Label
$lblGithub.Text = "Github:SZTMBABY"
$lblGithub.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblGithub.ForeColor = [System.Drawing.Color]::FromArgb(0x6E, 0x6A, 0x74)
$lblGithub.TextAlign = 'MiddleCenter'
$lblGithub.AutoSize = $false
$lblGithub.Location = New-Object System.Drawing.Point(0, [int](176 * $script:scale))
$lblGithub.Size = New-Object System.Drawing.Size($script:lblW, [int](18 * $script:scale))
$form.Controls.Add($lblGithub)

# 倒计时逻辑
$script:counter = 3
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$timer.Add_Tick({
    try {
        $script:counter--
        if ($script:counter -le 0) {
            $timer.Stop()
            $animTimer.Stop()
            $fadeTimer.Stop()
            $script:blacked = $true

            # 切换为全屏纯黑：无边框 + 方角 + 手动覆盖全屏
            $form.Controls.Clear()
            $form.FormBorderStyle = 'None'
            $noCorner = 0
            # 忽略返回值：DWM 不可用时不影响核心功能
            [DwmHelper]::DwmSetWindowAttribute($form.Handle, 33, [ref]$noCorner, 4) | Out-Null
            $form.WindowState = 'Normal'

            $screen = [System.Windows.Forms.Screen]::FromControl($form)
            if ($null -eq $screen) {
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen
            }
            $form.Location = New-Object System.Drawing.Point($screen.Bounds.X, $screen.Bounds.Y)
            $form.Size = New-Object System.Drawing.Size($screen.Bounds.Width, $screen.Bounds.Height)
            $form.BackColor = [System.Drawing.Color]::Black
            [System.Windows.Forms.Cursor]::Hide()

            $script:startX = [System.Windows.Forms.Cursor]::Position.X
            $script:startY = [System.Windows.Forms.Cursor]::Position.Y
            $script:listening = $false

            $script:wakeTimer = New-Object System.Windows.Forms.Timer
            $script:wakeTimer.Interval = 1000
            $script:wakeTimer.Add_Tick({
                $script:listening = $true
                $script:wakeTimer.Stop()
            })
            $script:wakeTimer.Start()

            $form.Add_KeyDown({ $form.Close() })
            $form.Add_Click({ $form.Close() })
            $form.Add_MouseMove({
                if ($script:listening) {
                    $p = [System.Windows.Forms.Cursor]::Position
                    if ([Math]::Abs($p.X - $script:startX) -gt 5 -or [Math]::Abs($p.Y - $script:startY) -gt 5) {
                        $form.Close()
                    }
                }
            })
        } else {
            $script:number = $script:counter
            $script:secondSW.Restart()
            $animTimer.Start()
        }
    } catch {
        # 异常时确保清理：关闭窗口触发 FormClosed → 释放电源锁
        $form.Close()
    }
})

# 倒计时期间也可取消
$form.Add_KeyDown({ $form.Close() })
$form.Add_Click({ $form.Close() })

# 退出清理：停止所有计时器 + 恢复光标 + 释放电源锁（所有退出路径统一处理）
$form.Add_FormClosed({
    $timer.Stop()
    $animTimer.Stop()
    $fadeTimer.Stop()
    if ($null -ne $script:wakeTimer) { $script:wakeTimer.Stop() }
    [System.Windows.Forms.Cursor]::Show()
    [PowerHelper]::SetThreadExecutionState([PowerHelper]::ES_CONTINUOUS)
})

# 初始透明，配合 Shown 时启动的 MD3 淡入
$form.Opacity = 0.0

# 启动时阻止系统休眠/睡眠 + 阻止显示器自动关闭
[PowerHelper]::SetThreadExecutionState([PowerHelper]::ES_CONTINUOUS -bor [PowerHelper]::ES_SYSTEM_REQUIRED -bor [PowerHelper]::ES_DISPLAY_REQUIRED) | Out-Null

$timer.Start()
$form.ShowDialog()
