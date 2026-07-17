param(
  [string]$Mode = "list",
  [string]$Hwnd = "",
  [string]$TextFile = "",
  [int]$Quality = 55,
  [int]$MaxWidth = 900
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Drawing;

public class WinApi {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@

function Get-WindowsList {
  $items = New-Object System.Collections.Generic.List[object]
  $fg = [WinApi]::GetForegroundWindow().ToInt64().ToString()
  [WinApi]::EnumWindows({
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if (-not [WinApi]::IsWindowVisible($hWnd)) { return $true }
    $len = [WinApi]::GetWindowTextLength($hWnd)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [void][WinApi]::GetWindowText($hWnd, $sb, $sb.Capacity)
    $title = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { return $true }
    $rect = New-Object WinApi+RECT
    if (-not [WinApi]::GetWindowRect($hWnd, [ref]$rect)) { return $true }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -lt 80 -or $h -lt 60) { return $true }
    [uint32]$processId = 0
    [void][WinApi]::GetWindowThreadProcessId($hWnd, [ref]$processId)
    $process = ""
    try { $process = (Get-Process -Id ([int]$processId) -ErrorAction Stop).ProcessName } catch {}
    $items.Add([pscustomobject]@{
      hwnd = $hWnd.ToInt64().ToString()
      title = $title
      process = $process
      pid = [int]$processId
      x = $rect.Left
      y = $rect.Top
      width = $w
      height = $h
      foreground = ($hWnd.ToInt64().ToString() -eq $fg)
    }) | Out-Null
    return $true
  }, [IntPtr]::Zero) | Out-Null
  $items | Sort-Object -Property @{Expression='foreground';Descending=$true}, title
}

function Get-JpegCodec {
  [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
}

function Convert-BitmapToBase64Jpeg([System.Drawing.Bitmap]$Bitmap, [int]$Quality) {
  $codec = Get-JpegCodec
  $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
  $ms = New-Object System.IO.MemoryStream
  $Bitmap.Save($ms, $codec, $params)
  $bytes = $ms.ToArray()
  $ms.Dispose()
  [Convert]::ToBase64String($bytes)
}

function Capture-Window([string]$HwndText) {
  if ([string]::IsNullOrWhiteSpace($HwndText)) { throw "hwnd is required" }
  $ptr = [IntPtr]::new([Int64]$HwndText)
  $rect = New-Object WinApi+RECT
  if (-not [WinApi]::GetWindowRect($ptr, [ref]$rect)) { throw "GetWindowRect failed" }
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -lt 1 -or $h -lt 1) { throw "invalid window size" }

  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = [WinApi]::PrintWindow($ptr, $hdc, 2)
  $g.ReleaseHdc($hdc)
  $g.Dispose()

  if (-not $ok) {
    $bmp.Dispose()
    throw "PrintWindow failed"
  }

  $outBmp = $bmp
  if ($w -gt $MaxWidth) {
    $ratio = $MaxWidth / $w
    $newW = [int]$MaxWidth
    $newH = [int]($h * $ratio)
    $resized = New-Object System.Drawing.Bitmap $newW, $newH
    $rg = [System.Drawing.Graphics]::FromImage($resized)
    $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $rg.DrawImage($bmp, 0, 0, $newW, $newH)
    $rg.Dispose()
    $outBmp = $resized
  }

  $b64 = Convert-BitmapToBase64Jpeg $outBmp $Quality
  if ($outBmp -ne $bmp) { $outBmp.Dispose() }
  $bmp.Dispose()

  $win = Get-WindowsList | Where-Object { $_.hwnd -eq $HwndText } | Select-Object -First 1
  [pscustomobject]@{
    hwnd = $HwndText
    title = if ($win) { $win.title } else { "窗口 $HwndText" }
    imageBase64 = $b64
    width = $w
    height = $h
    capturedAt = (Get-Date).ToUniversalTime().ToString("o")
  }
}

function Send-TextToWindow([string]$HwndText, [string]$TextFilePath) {
  if ([string]::IsNullOrWhiteSpace($HwndText)) { throw "hwnd is required" }
  if ([string]::IsNullOrWhiteSpace($TextFilePath) -or -not (Test-Path -LiteralPath $TextFilePath)) { throw "text file is required" }
  $text = [System.IO.File]::ReadAllText($TextFilePath, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($text)) { throw "text is empty" }

  $ptr = [IntPtr]::new([Int64]$HwndText)
  $rect = New-Object WinApi+RECT
  if (-not [WinApi]::GetWindowRect($ptr, [ref]$rect)) { throw "GetWindowRect failed" }
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -lt 200 -or $h -lt 200) { throw "invalid window size" }

  [void][WinApi]::ShowWindow($ptr, 9)
  [void][WinApi]::SetForegroundWindow($ptr)
  Start-Sleep -Milliseconds 350

  $x = [int]($rect.Left + ($w / 2))
  $y = [int]($rect.Bottom - 72)
  [void][WinApi]::SetCursorPos($x, $y)
  [WinApi]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [WinApi]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120

  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 120
  $wshell = New-Object -ComObject WScript.Shell
  [void]$wshell.SendKeys("^v")
  Start-Sleep -Milliseconds 200
  [void]$wshell.SendKeys("{ENTER}")

  [pscustomobject]@{
    ok = $true
    hwnd = $HwndText
    pastedChars = $text.Length
    sentAt = (Get-Date).ToUniversalTime().ToString("o")
  }
}

try {
  if ($Mode -eq "list") {
    Get-WindowsList | ConvertTo-Json -Depth 5 -Compress
  } elseif ($Mode -eq "capture") {
    Capture-Window $Hwnd | ConvertTo-Json -Depth 5 -Compress
  } elseif ($Mode -eq "sendText") {
    Send-TextToWindow $Hwnd $TextFile | ConvertTo-Json -Depth 5 -Compress
  } else {
    throw "unknown mode: $Mode"
  }
} catch {
  [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json -Compress
  exit 1
}
