param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class OCUWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public InputUnion u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool IsHungAppWindow(IntPtr hWnd);
}
"@

$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)

function Test-EnvFlagEnabled([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $normalized = $value.Trim().ToLowerInvariant()
    return @("1", "true", "yes", "on") -contains $normalized
}

function New-Frame($x, $y, $width, $height) {
    if ($width -lt 0 -or $height -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = [double]$x
        y = [double]$y
        width = [double]$width
        height = [double]$height
    }
}

function Get-WindowRectFrame([IntPtr]$hwnd) {
    $rect = New-Object OCUWin32+RECT
    if ([OCUWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
    }
    return $null
}

function Get-ElementFrame($element, $windowBounds) {
    try {
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $null
        }
        if ($null -ne $windowBounds) {
            return New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height
        }
        return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
    } catch {
        return $null
    }
}

function Get-ScreenPoint($localFrame, $windowBounds) {
    if ($null -eq $localFrame -or $null -eq $windowBounds) {
        return $null
    }
    [pscustomobject]@{
        x = [int][math]::Round($windowBounds.x + $localFrame.x + ($localFrame.width / 2))
        y = [int][math]::Round($windowBounds.y + $localFrame.y + ($localFrame.height / 2))
    }
}

function Send-MouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    $downFlag = 0x0002
    $upFlag = 0x0004
    if ($button -eq "right") {
        $downFlag = 0x0008
        $upFlag = 0x0010
    } elseif ($button -eq "middle") {
        $downFlag = 0x0020
        $upFlag = 0x0040
    }
    [void][OCUWin32]::SetCursorPos($screenX, $screenY)
    Start-Sleep -Milliseconds 20
    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        [void][OCUWin32]::mouse_event($downFlag, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [void][OCUWin32]::mouse_event($upFlag, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 50
    }
}

function Send-Drag([IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY, [string]$button) {
    $downFlag = 0x0002
    $upFlag = 0x0004
    if ($button -eq "right") {
        $downFlag = 0x0008
        $upFlag = 0x0010
    } elseif ($button -eq "middle") {
        $downFlag = 0x0020
        $upFlag = 0x0040
    }
    [void][OCUWin32]::SetCursorPos($fromX, $fromY)
    Start-Sleep -Milliseconds 30
    [void][OCUWin32]::mouse_event($downFlag, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    $steps = 12
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($fromX + (($toX - $fromX) * $i / $steps))
        $y = [int][math]::Round($fromY + (($toY - $fromY) * $i / $steps))
        [void][OCUWin32]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 20
    }
    Start-Sleep -Milliseconds 30
    [void][OCUWin32]::mouse_event($upFlag, 0, 0, 0, [UIntPtr]::Zero)
}

function Send-Scroll([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages) {
    $delta = [int][math]::Round(120 * $pages)
    $flags = 0x0800
    if ($direction -eq "down") { $delta = -$delta }
    if ($direction -eq "left" -or $direction -eq "right") {
        $flags = 0x1000
        if ($direction -eq "left") { $delta = -$delta }
    }
    [void][OCUWin32]::SetCursorPos($screenX, $screenY)
    Start-Sleep -Milliseconds 15
    [void][OCUWin32]::mouse_event($flags, 0, 0, $delta, [UIntPtr]::Zero)
}

function Send-Text([IntPtr]$hwnd, [string]$text) {
    foreach ($char in $text.ToCharArray()) {
        $code = [int]$char
        $inputs = @(
            [OCUWin32+INPUT]@{
                type = 1
                u = [OCUWin32+InputUnion]@{
                    ki = [OCUWin32+KEYBDINPUT]@{
                        wVk = 0
                        wScan = [uint16]$code
                        dwFlags = 0x0004
                        time = 0
                        dwExtraInfo = [IntPtr]::Zero
                    }
                }
            }
            [OCUWin32+INPUT]@{
                type = 1
                u = [OCUWin32+InputUnion]@{
                    ki = [OCUWin32+KEYBDINPUT]@{
                        wVk = 0
                        wScan = [uint16]$code
                        dwFlags = 0x0004 -bor 0x0002
                        time = 0
                        dwExtraInfo = [IntPtr]::Zero
                    }
                }
            }
        )
        [void][OCUWin32]::SendInput(2, $inputs, [System.Runtime.InteropServices.Marshal]::SizeOf([type][OCUWin32+INPUT]))
        Start-Sleep -Milliseconds 8
    }
}

function Get-VirtualKey([string]$key) {
    $normalized = $key.ToLowerInvariant()
    $map = @{
        "return" = 0x0D; "enter" = 0x0D; "tab" = 0x09; "escape" = 0x1B; "esc" = 0x1B
        "backspace" = 0x08; "back_space" = 0x08; "delete" = 0x2E; "space" = 0x20
        "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28
        "home" = 0x24; "end" = 0x23; "page_up" = 0x21; "prior" = 0x21; "page_down" = 0x22; "next" = 0x22
    }
    if ($map.ContainsKey($normalized)) {
        return $map[$normalized]
    }
    if ($normalized -match "^f([1-9]|1[0-2])$") {
        return 0x70 + [int]$Matches[1] - 1
    }
    if ($normalized -match "^kp_([0-9])$") {
        return 0x60 + [int]$Matches[1]
    }
    if ($normalized.Length -eq 1) {
        $code = [int][char]$normalized.ToUpperInvariant()[0]
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) {
            return $code
        }
    }
    throw "Unsupported key: $key"
}

function Send-Key([IntPtr]$hwnd, [string]$key) {
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = @()
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers += 0x11 }
            "control" { $modifiers += 0x11 }
            "shift" { $modifiers += 0x10 }
            "alt" { $modifiers += 0x12 }
            "super" { $modifiers += 0x5B }
            "win" { $modifiers += 0x5B }
            "cmd" { $modifiers += 0x5B }
        }
    }
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::keybd_event([byte]$modifier, 0, 0, [UIntPtr]::Zero)
    }
    $vk = Get-VirtualKey $main
    [void][OCUWin32]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 25
    [void][OCUWin32]::keybd_event([byte]$vk, 0, 0x0002, [UIntPtr]::Zero)
    [array]::Reverse($modifiers)
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::keybd_event([byte]$modifier, 0, 0x0002, [UIntPtr]::Zero)
    }
}

function Test-IsTargetForeground([IntPtr]$hwnd) {
    try {
        $fg = [OCUWin32]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) {
            return $false
        }
        $fgPid = 0
        $targetPid = 0
        [void][OCUWin32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        [void][OCUWin32]::GetWindowThreadProcessId($hwnd, [ref]$targetPid)
        return ($fgPid -eq $targetPid)
    } catch {
        return $false
    }
}

function Ensure-Foreground([IntPtr]$hwnd) {
    if (Test-IsTargetForeground $hwnd) {
        return $true
    }

    [void][OCUWin32]::ShowWindow($hwnd, 9)

    $fg = [OCUWin32]::GetForegroundWindow()
    $myThread = [OCUWin32]::GetCurrentThreadId()
    $fgThread = [OCUWin32]::GetWindowThreadProcessId($fg, [ref]0)

    $attached = $false
    if ($fgThread -ne $myThread -and -not [OCUWin32]::IsHungAppWindow($fg)) {
        $attached = [OCUWin32]::AttachThreadInput($myThread, $fgThread, $true)
    }

    try {
        [void][OCUWin32]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOMOVE -bor $SWP_NOSIZE)
        [void][OCUWin32]::SetWindowPos($hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP_NOMOVE -bor $SWP_NOSIZE)
        [void][OCUWin32]::SetForegroundWindow($hwnd)
        [void][OCUWin32]::SetFocus($hwnd)
    } finally {
        if ($attached) {
            [void][OCUWin32]::AttachThreadInput($myThread, $fgThread, $false)
        }
    }

    Start-Sleep -Milliseconds 150
    return (Test-IsTargetForeground $hwnd)
}

function Resolve-App([string]$query) {
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $processes = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        $match = $processes | Where-Object { $_.Id -eq $pidValue } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    $match = $processes | Where-Object {
        $_.ProcessName -ieq $processQuery -or
        "$($_.ProcessName).exe" -ieq $normalized -or
        $_.MainWindowTitle -ieq $normalized -or
        $_.MainWindowTitle -ilike "*$normalized*"
    } | Select-Object -First 1
    if ($null -ne $match) {
        return $match
    }

    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
        try {
            $started = Start-Process -FilePath $normalized -PassThru
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $candidate = Get-Process -Id $started.Id -ErrorAction SilentlyContinue
                if ($null -ne $candidate -and $candidate.MainWindowHandle -ne 0) {
                    return $candidate
                }
            }
        } catch {
        }
    }

    throw "appNotFound(`"$query`")"
}

function Get-MainElement($process) {
    if ($process.MainWindowHandle -ne 0) {
        return [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    }
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
    $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($children.Count -gt 0) {
        return $children.Item(0)
    }
    throw "No top-level UI Automation window is available for $($process.ProcessName). Run the Windows runtime in the signed-in desktop session."
}

function Get-WindowBounds($process, $element) {
    $hwnd = [IntPtr]$process.MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        $fromWin32 = Get-WindowRectFrame $hwnd
        if ($null -ne $fromWin32) {
            return $fromWin32
        }
    }
    try {
        $rect = $element.Current.BoundingRectangle
        if (-not $rect.IsEmpty -and $rect.Width -gt 0 -and $rect.Height -gt 0) {
            return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
        }
    } catch {
    }
    return $null
}

function Get-PatternNames($element) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $element.GetSupportedPatterns()) {
        $programmatic = $pattern.ProgrammaticName
        if ($programmatic -like "InvokePatternIdentifiers.Pattern") { $names.Add("Invoke") }
        elseif ($programmatic -like "TogglePatternIdentifiers.Pattern") { $names.Add("Toggle") }
        elseif ($programmatic -like "SelectionItemPatternIdentifiers.Pattern") { $names.Add("Select") }
        elseif ($programmatic -like "ExpandCollapsePatternIdentifiers.Pattern") {
            try {
                $state = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
                if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $names.Add("Expand") }
                elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $names.Add("Collapse") }
            } catch {
                $names.Add("Expand")
                $names.Add("Collapse")
            }
        }
        elseif ($programmatic -like "ScrollItemPatternIdentifiers.Pattern") { $names.Add("ScrollIntoView") }
        elseif ($programmatic -like "ScrollPatternIdentifiers.Pattern") { $names.Add("Scroll") }
        elseif ($programmatic -like "ValuePatternIdentifiers.Pattern") { $names.Add("SetValue") }
    }
    if ($names.Count -gt 0) {
        return @($names | Select-Object -Unique)
    }
    return @()
}

function Get-ElementString($element, [string]$propertyName) {
    try {
        $value = $element.Current.$propertyName
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ElementInt64($element, [string]$propertyName) {
    try {
        return [int64]$element.Current.$propertyName
    } catch {
        return 0
    }
}

function Get-ElementControlTypeName($element) {
    try {
        $controlType = $element.Current.ControlType
        if ($null -eq $controlType) {
            return ""
        }
        return [string]$controlType.ProgrammaticName
    } catch {
        return ""
    }
}

function Get-ElementValue($element) {
    try {
        $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $value = $valuePattern.Current.Value
        if ($null -eq $value) {
            return ""
        }
        $text = [string]$value
        if ($text.Length -gt 500) {
            return $text.Substring(0, 500)
        }
        return $text
    } catch {
        return ""
    }
}

function Get-ElementRecord($element, [int]$index, $windowBounds) {
    $frame = Get-ElementFrame $element $windowBounds
    $runtimeId = @()
    try { $runtimeId = @($element.GetRuntimeId()) } catch {}
    [pscustomobject]@{
        index = $index
        runtimeId = $runtimeId
        automationId = Get-ElementString $element "AutomationId"
        name = Get-ElementString $element "Name"
        controlType = Get-ElementControlTypeName $element
        localizedControlType = Get-ElementString $element "LocalizedControlType"
        className = Get-ElementString $element "ClassName"
        value = Get-ElementValue $element
        nativeWindowHandle = Get-ElementInt64 $element "NativeWindowHandle"
        frame = $frame
        actions = @(Get-PatternNames $element)
    }
}

function Get-ElementTitle($record) {
    if (-not [string]::IsNullOrWhiteSpace($record.name)) {
        return $record.name
    }
    if (-not [string]::IsNullOrWhiteSpace($record.automationId)) {
        return "ID: $($record.automationId)"
    }
    return ""
}

function Render-Tree($element, $windowBounds) {
    $records = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $nextIndex = 0

    function Visit($node, [int]$depth) {
        if ($script:nextIndex -ge 500 -or $depth -gt 16) {
            return
        }
        $runtime = ""
        try { $runtime = (@($node.GetRuntimeId()) -join ".") } catch { $runtime = [guid]::NewGuid().ToString() }
        if (-not $script:visited.Add($runtime)) {
            return
        }

        $index = $script:nextIndex
        $script:nextIndex++
        $record = Get-ElementRecord $node $index $script:windowBounds
        $script:records.Add($record)

        $role = $record.localizedControlType
        if ([string]::IsNullOrWhiteSpace($role)) {
            $role = $record.controlType
        }
        $title = Get-ElementTitle $record
        $actionsSegment = ""
        if ($record.actions.Count -gt 0) {
            $actionsSegment = " Secondary Actions: " + ($record.actions -join ", ")
        }
        $valueSegment = ""
        if (-not [string]::IsNullOrWhiteSpace($record.value) -and $record.value -ne $title) {
            $safeValue = (($record.value -replace "`r", "\\r") -replace "`n", "\\n")
            $valueSegment = " Value: $safeValue"
        }
        $frameSegment = ""
        if ($null -ne $record.frame) {
            $frameSegment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}" -f [int][math]::Round($record.frame.x), [int][math]::Round($record.frame.y), [int][math]::Round($record.frame.width), [int][math]::Round($record.frame.height)
        }
        $script:lines.Add(("`t" * ($depth + 1)) + "$index $role $title$valueSegment$actionsSegment$frameSegment")

        try {
            $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) {
                Visit $children.Item($i) ($depth + 1)
            }
        } catch {
        }
    }

    $script:records = $records
    $script:lines = $lines
    $script:visited = $visited
    $script:nextIndex = $nextIndex
    $script:windowBounds = $windowBounds
    Visit $element 0

    [pscustomobject]@{
        records = $records.ToArray()
        lines = $lines.ToArray()
    }
}

function Capture-WindowPngBase64($bounds) {
    if ($null -eq $bounds -or $bounds.width -le 0 -or $bounds.height -le 0) {
        return $null
    }
    try {
        $bitmap = New-Object System.Drawing.Bitmap ([int][math]::Round($bounds.width)), ([int][math]::Round($bounds.height))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        $bytes = $stream.ToArray()
        $stream.Dispose()
        return [Convert]::ToBase64String($bytes)
    } catch {
        return $null
    }
}

function Get-FocusedSummary($processId) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $role = $focused.Current.LocalizedControlType
            $name = $focused.Current.Name
            if ([string]::IsNullOrWhiteSpace($name)) {
                return $role
            }
            return "$role $name"
        }
    } catch {
    }
    return $null
}

function Get-SelectedText($processId) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            return $null
        }
        $textPattern = $focused.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $selection = $textPattern.GetSelection()
        if ($selection.Count -gt 0) {
            return $selection.Item(0).GetText(2048)
        }
    } catch {
    }
    return $null
}

function Build-Snapshot([string]$query) {
    $process = Resolve-App $query
    $element = Get-MainElement $process
    $bounds = Get-WindowBounds $process $element
    $rendered = Render-Tree $element $bounds
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        windowTitle = $process.MainWindowTitle
        windowBounds = $bounds
        screenshotPngBase64 = Capture-WindowPngBase64 $bounds
        treeLines = @($rendered.lines)
        focusedSummary = Get-FocusedSummary $process.Id
        selectedText = Get-SelectedText $process.Id
        elements = @($rendered.records)
    }
}

function List-Apps {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object ProcessName, Id)) {
        $title = $process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "untitled"
        }
        $lines.Add(("{0} -- {1} [running, pid={2}, window={3}]" -f $process.ProcessName, $process.ProcessName, $process.Id, $title))
    }
    return ($lines -join "`n")
}

function Same-RuntimeId($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
}

function Get-AllElements($root) {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($root)
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count; $i++) {
            $items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

function Find-Element($process, $record) {
    if ($null -eq $record) {
        return $null
    }
    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        try {
            if (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId)) {
                return $element
            }
        } catch {
        }
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            $sameAutomationId = -not [string]::IsNullOrWhiteSpace($record.automationId) -and $element.Current.AutomationId -eq $record.automationId
            $sameName = -not [string]::IsNullOrWhiteSpace($record.name) -and $element.Current.Name -eq $record.name
            $sameType = $element.Current.ControlType.ProgrammaticName -eq $record.controlType
            if (($sameAutomationId -or $sameName) -and $sameType) {
                return $element
            }
        } catch {
        }
    }
    return $null
}

$operation = Get-Content -Raw -Path $OperationPath | ConvertFrom-Json

try {
    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "get_app_state") {
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app) }
    } else {
        $process = Resolve-App $operation.app
        $hwnd = [IntPtr]$process.MainWindowHandle
        $windowBounds = $operation.windowBounds
        $element = Find-Element $process $operation.element

        switch ($operation.tool) {
            "click" {
                if (-not (Ensure-Foreground $hwnd)) { throw "failed to bring app window to foreground" }
                $fresh = Get-WindowRectFrame $hwnd
                if ($null -ne $fresh) { $windowBounds = $fresh }
                if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                    $point = Get-ScreenPoint $operation.element.frame $windowBounds
                } else {
                    $point = [pscustomobject]@{
                        x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                        y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                    }
                }
                Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
            }
            "perform_secondary_action" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                if (-not (Ensure-Foreground $hwnd)) { throw "failed to bring app window to foreground" }
                $fresh = Get-WindowRectFrame $hwnd
                if ($null -ne $fresh) { $windowBounds = $fresh }
                $point = Get-ScreenPoint $operation.element.frame $windowBounds
                Send-MouseClick $hwnd $point.x $point.y "left" 1
            }
            "scroll" {
                if (-not (Ensure-Foreground $hwnd)) { throw "failed to bring app window to foreground" }
                $fresh = Get-WindowRectFrame $hwnd
                if ($null -ne $fresh) { $windowBounds = $fresh }
                $point = Get-ScreenPoint $operation.element.frame $windowBounds
                Send-Scroll $hwnd $point.x $point.y $operation.direction ([double]$operation.pages)
            }
            "drag" {
                if (-not (Ensure-Foreground $hwnd)) { throw "failed to bring app window to foreground" }
                $fresh = Get-WindowRectFrame $hwnd
                if ($null -ne $fresh) { $windowBounds = $fresh }
                Send-Drag $hwnd ([int][math]::Round($windowBounds.x + [double]$operation.from_x)) ([int][math]::Round($windowBounds.y + [double]$operation.from_y)) ([int][math]::Round($windowBounds.x + [double]$operation.to_x)) ([int][math]::Round($windowBounds.y + [double]$operation.to_y)) $operation.mouse_button
            }
            "type_text" {
                if (-not (Ensure-Foreground $hwnd)) { throw "keyboard input refused: app window did not get focus (text would go to another window)" }
                Send-Text $hwnd $operation.text
            }
            "press_key" {
                if (-not (Ensure-Foreground $hwnd)) { throw "keyboard input refused: app window did not get focus (key would go to another window)" }
                Send-Key $hwnd $operation.key
            }
            "set_value" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                if (-not (Ensure-Foreground $hwnd)) { throw "failed to bring app window to foreground" }
                $fresh = Get-WindowRectFrame $hwnd
                if ($null -ne $fresh) { $windowBounds = $fresh }
                $point = Get-ScreenPoint $operation.element.frame $windowBounds
                Send-MouseClick $hwnd $point.x $point.y "left" 1
                Start-Sleep -Milliseconds 100
                Send-Key $hwnd "ctrl+a"
                Start-Sleep -Milliseconds 50
                Send-Text $hwnd $operation.value
            }
            default {
                throw "unsupportedTool(`"$($operation.tool)`")"
            }
        }

        Start-Sleep -Milliseconds 120
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app) }
    }
} catch {
    $message = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        $message = "$message at $($_.ScriptStackTrace)"
    }
    $response = [pscustomobject]@{ ok = $false; error = $message }
}

$response | ConvertTo-Json -Depth 50 -Compress