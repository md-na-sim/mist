$ErrorActionPreference = "Stop"

$Url = "https://student.mist.ac.bd/semester-evaluation/faculty-evaluation"
$Port = 9222
$CdpListUrl = "http://127.0.0.1:$Port/json/list"

function Sleep-MS([int]$ms) {
    Start-Sleep -Milliseconds $ms
}

function Get-CdpPages {
    try {
        return @(Invoke-RestMethod -Uri $CdpListUrl -Method Get -TimeoutSec 3)
    }
    catch {
        return @()
    }
}

function Get-EdgePath {
    $paths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramW6432\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }
    $cmd = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

function Wait-Cdp {
    param([int]$TimeoutSeconds = 20)
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $end) {
        $pages = Get-CdpPages
        if ($pages.Count -gt 0) {
            return $pages
        }
        Sleep-MS 500
    }
    return @()
}

function Invoke-CDP {
    param(
        [string]$Method,
        [hashtable]$Params = @{}
    )
    $script:CdpId++
    $request = @{
        id = $script:CdpId
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 20
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
    $sendTask = $script:WebSocket.SendAsync(
        [System.ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    )
    $sendTask.GetAwaiter().GetResult() | Out-Null
    while ($true) {
        $buffer = New-Object byte[] 65536
        $result = $script:WebSocket.ReceiveAsync(
            [System.ArraySegment[byte]]::new($buffer),
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()
        if ($result.Count -gt 0) {
            $text = [System.Text.Encoding]::UTF8.GetString(
                $buffer,
                0,
                $result.Count
            )
            try {
                $response = $text | ConvertFrom-Json
                if ($response.id -eq $script:CdpId) {
                    return $response
                }
            }
            catch {
            }
        }
    }
}

function Invoke-JavaScript {
    param([string]$Code)
    $response = Invoke-CDP "Runtime.evaluate" @{
        expression = $Code
        returnByValue = $true
        awaitPromise = $true
    }
    if ($response.result.result.value -ne $null) {
        return $response.result.result.value
    }
    return $null
}

function Click-At {
    param(
        [int]$X,
        [int]$Y
    )
    Invoke-CDP "Input.dispatchMouseEvent" @{
        type = "mousePressed"
        x = $X
        y = $Y
        button = "left"
        clickCount = 1
    } | Out-Null
    Invoke-CDP "Input.dispatchMouseEvent" @{
        type = "mouseReleased"
        x = $X
        y = $Y
        button = "left"
        clickCount = 1
    } | Out-Null
}

function Get-EvaluateCount {
    return Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    return [...document.querySelectorAll("button")]
        .filter(visible)
        .filter(b => {
            const t = (b.innerText || "").trim().toLowerCase();
            return t === "evaluate";
        }).length;
})()
'@
}

function Get-GoodCount {
    return Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    return [...document.querySelectorAll("*")]
        .filter(visible)
        .filter(e => (e.innerText || "").trim() === "Good")
        .filter(e => {
            const r = e.getBoundingClientRect();
            return r.width > 10 && r.height > 10;
        }).length;
})()
'@
}

function Get-MuiTextarea {
    return Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    return [...document.querySelectorAll("textarea")]
        .filter(visible)
        .map(t => ({
            value: t.value || "",
            placeholder: t.placeholder || "",
            aria: t.getAttribute("aria-label") || ""
        }));
})()
'@
}

function Set-MuiTextareaNAN {
    param([int]$Index)
    $code = @"
(() => {
    const areas = [...document.querySelectorAll("textarea")]
        .filter(t => {
            const r = t.getBoundingClientRect();
            const s = getComputedStyle(t);
            return r.width > 0 &&
                   r.height > 0 &&
                   s.display !== "none" &&
                   s.visibility !== "hidden";
        });
    const el = areas[$Index];
    if (!el) return false;
    el.focus();
    const setter = Object.getOwnPropertyDescriptor(
        HTMLTextAreaElement.prototype,
        "value"
    ).set;
    setter.call(el, "NAN");
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return el.value === "NAN";
})()
"@
    return Invoke-JavaScript $code
}

function Get-DialogSubmit {
    return Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    const dialogs = [...document.querySelectorAll(
        '[role="dialog"], .MuiDialog-root'
    )].filter(visible);
    for (const dialog of dialogs) {
        const buttons = [...dialog.querySelectorAll("button")]
            .filter(visible);
        const submit = buttons.find(b => {
            return (b.innerText || "").trim().toLowerCase() === "submit";
        });
        if (submit) {
            const r = submit.getBoundingClientRect();
            return {
                enabled: !submit.disabled &&
                    submit.getAttribute("aria-disabled") !== "true",
                x: r.left + r.width / 2,
                y: r.top + r.height / 2
            };
        }
    }
    return null;
})()
'@
}

Write-Host "================================================"
Write-Host "MIST UNIPLEX FACULTY EVALUATION"
Write-Host "================================================"
Write-Host ""
Write-Host "Checking Microsoft Edge..."

$pages = Get-CdpPages

if ($pages.Count -eq 0) {
    Write-Host "Remote debugging is not active."
    Write-Host "Starting Microsoft Edge with remote debugging..."
    $EdgePath = Get-EdgePath
    if (-not $EdgePath) {
        Write-Host "ERROR: Microsoft Edge executable was not found."
        exit 1
    }
    Write-Host "Edge executable:"
    Write-Host $EdgePath
    $ProfilePath = Join-Path $env:TEMP "MIST-UNIPLEX-EDGE"
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
    }
    Start-Process -FilePath $EdgePath -ArgumentList @(
        "--remote-debugging-port=$Port",
        "--user-data-dir=$ProfilePath",
        "--new-window"
    )
    Write-Host "Waiting for Edge debugging interface..."
    $pages = Wait-Cdp -TimeoutSeconds 30
    if ($pages.Count -eq 0) {
        Write-Host "ERROR: Microsoft Edge debugging interface did not start."
        exit 1
    }
    Write-Host "Microsoft Edge debugging interface detected."
}
else {
    Write-Host "Microsoft Edge debugging interface detected."
}

Write-Host ""
Write-Host "Opening UNIPLEX in a NEW Edge tab..."

$newTabUrl = "http://127.0.0.1:$Port/json/new?" +
    [System.Uri]::EscapeDataString($Url)

$newTab = $null

try {
    $newTab = Invoke-RestMethod `
        -Uri $newTabUrl `
        -Method Put `
        -TimeoutSec 5
}
catch {
    Write-Host "Could not create new tab through /json/new."
}

$targetId = $null

if ($newTab) {
    $targetId = $newTab.id
}

Write-Host "Waiting for new UNIPLEX tab..."

$end = (Get-Date).AddSeconds(30)
$target = $null

while ((Get-Date) -lt $end) {
    $pages = Get-CdpPages
    if ($targetId) {
        $target = $pages |
            Where-Object { $_.id -eq $targetId } |
            Select-Object -First 1
    }
    if (-not $target) {
        $target = $pages |
            Where-Object {
                $_.url -like "https://student.mist.ac.bd/*"
            } |
            Select-Object -First 1
    }
    if ($target) {
        break
    }
    Sleep-MS 500
}

if (-not $target) {
    Write-Host "ERROR: UNIPLEX tab was not detected."
    exit 1
}

Write-Host "New Edge tab detected."
Write-Host "Page: $($target.url)"

$wsUrl = $target.webSocketDebuggerUrl

if (-not $wsUrl) {
    Write-Host "ERROR: WebSocket debugger URL not found."
    exit 1
}

$script:CdpId = 0
$script:WebSocket = New-Object System.Net.WebSockets.ClientWebSocket

$connectTask = $script:WebSocket.ConnectAsync(
    [Uri]$wsUrl,
    [Threading.CancellationToken]::None
)

$connectTask.GetAwaiter().GetResult() | Out-Null

Invoke-CDP "Runtime.enable" | Out-Null
Invoke-CDP "Page.enable" | Out-Null

Write-Host "Connected to Edge DevTools Protocol."

$currentUrl = Invoke-JavaScript "location.href"

if ($currentUrl -like "view-source:*") {
    Write-Host "View-source page detected."
    Write-Host "Navigating to actual UNIPLEX page..."
    Invoke-CDP "Page.navigate" @{
        url = $Url
    } | Out-Null
    Sleep-MS 2000
}

Write-Host ""
Write-Host "Waiting for UNIPLEX page..."

$pageEnd = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $pageEnd) {
    $urlNow = Invoke-JavaScript "location.href"
    if ($urlNow -like "https://student.mist.ac.bd/*") {
        break
    }
    Sleep-MS 500
}

Write-Host ""
Write-Host "Checking UNIPLEX login status..."
Write-Host "Please complete login in the Edge window if required."

$loginEnd = (Get-Date).AddSeconds(600)
$loggedIn = $false

while ((Get-Date) -lt $loginEnd) {
    try {
        $count = [int](Get-EvaluateCount)
        if ($count -gt 0) {
            $loggedIn = $true
            break
        }
    }
    catch {
    }
    Sleep-MS 2000
}

if (-not $loggedIn) {
    Write-Host "ERROR: Faculty evaluation page was not detected."
    exit 1
}

Write-Host "UNIPLEX faculty evaluation page detected."

$processed = 0

while ($true) {
    $evaluateCount = [int](Get-EvaluateCount)
    Write-Host ""
    Write-Host "Faculty evaluations available: $evaluateCount"

    if ($evaluateCount -le 0) {
        break
    }

    Write-Host "Opening faculty evaluation #$($processed + 1)..."

    $clicked = Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    const button = [...document.querySelectorAll("button")]
        .filter(visible)
        .find(b => {
            return (b.innerText || "").trim().toLowerCase() === "evaluate";
        });
    if (!button) return false;
    button.click();
    return true;
})()
'@

    if (-not $clicked) {
        Write-Host "ERROR: Could not click Evaluate."
        break
    }

    Write-Host "Waiting for evaluation questions..."

    $goodEnd = (Get-Date).AddSeconds(30)
    $goodReady = $false

    while ((Get-Date) -lt $goodEnd) {
        try {
            $goodCount = [int](Get-GoodCount)
            if ($goodCount -ge 10) {
                $goodReady = $true
                break
            }
        }
        catch {
        }
        Sleep-MS 500
    }

    if (-not $goodReady) {
        Write-Host "ERROR: Ten Good options were not detected."
        break
    }

    Write-Host "10 Good options detected."

    $selected = Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    const elements = [...document.querySelectorAll("*")]
        .filter(visible)
        .filter(e => (e.innerText || "").trim() === "Good")
        .filter(e => {
            const r = e.getBoundingClientRect();
            return r.width > 10 && r.height > 10;
        });
    const unique = [];
    const seen = new Set();
    for (const e of elements) {
        if (!seen.has(e)) {
            seen.add(e);
            unique.push(e);
        }
    }
    let clicked = 0;
    for (const e of unique) {
        if (clicked >= 10) break;
        try {
            e.click();
            clicked++;
        }
        catch {
        }
    }
    return clicked;
})()
'@

    Write-Host "Selected $selected Good options."

    if ([int]$selected -lt 10) {
        Write-Host "ERROR: Could not select all 10 Good options."
        break
    }

    Write-Host "Submitting evaluation answers..."

    $submitClicked = Invoke-JavaScript @'
(() => {
    const visible = e => {
        if (!e) return false;
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return r.width > 0 &&
               r.height > 0 &&
               s.display !== "none" &&
               s.visibility !== "hidden";
    };
    const buttons = [...document.querySelectorAll("button")]
        .filter(visible);
    const submit = buttons.find(b => {
        return (b.innerText || "").trim().toLowerCase() === "submit";
    });
    if (!submit) return false;
    submit.click();
    return true;
})()
'@

    if (-not $submitClicked) {
        Write-Host "ERROR: First Submit button was not found."
        break
    }

    Write-Host "Waiting for comments dialog..."

    $dialogEnd = (Get-Date).AddSeconds(30)
    $dialogReady = $false

    while ((Get-Date) -lt $dialogEnd) {
        try {
            $areas = @(Get-MuiTextarea)
            if ($areas.Count -ge 2) {
                $dialogReady = $true
                break
            }
        }
        catch {
        }
        Sleep-MS 500
    }

    if (-not $dialogReady) {
        Write-Host "ERROR: Comments dialog was not detected."
        break
    }

    Write-Host "Comments dialog detected."
    Write-Host "Entering Overall Comments: NAN"

    $result1 = Set-MuiTextareaNAN -Index 0

    if (-not $result1) {
        Write-Host "ERROR: Could not set Overall Comments."
        break
    }

    Write-Host "Entering Recommendations: NAN"

    $result2 = Set-MuiTextareaNAN -Index 1

    if (-not $result2) {
        Write-Host "ERROR: Could not set Recommendations."
        break
    }

    $verify = @(Get-MuiTextarea)

    if ($verify.Count -lt 2) {
        Write-Host "ERROR: Could not verify textareas."
        break
    }

    if ($verify[0].value -ne "NAN" -or
        $verify[1].value -ne "NAN") {
        Write-Host "ERROR: Textarea verification failed."
        break
    }

    Write-Host "Both comments verified as NAN."
    Write-Host "Waiting for final Submit button..."

    $finalEnd = (Get-Date).AddSeconds(15)
    $finalSubmit = $null

    while ((Get-Date) -lt $finalEnd) {
        try {
            $finalSubmit = Get-DialogSubmit
            if ($finalSubmit -and $finalSubmit.enabled) {
                break
            }
        }
        catch {
        }
        Sleep-MS 300
    }

    if (-not $finalSubmit -or -not $finalSubmit.enabled) {
        Write-Host "ERROR: Final Submit button did not become enabled."
        break
    }

    Write-Host "Clicking final Submit..."

    Click-At `
        -X ([int]$finalSubmit.x) `
        -Y ([int]$finalSubmit.y)

    Write-Host "Waiting for faculty list..."

    $listEnd = (Get-Date).AddSeconds(30)
    $returned = $false

    while ((Get-Date) -lt $listEnd) {
        try {
            $countAfter = [int](Get-EvaluateCount)
            if ($countAfter -gt 0) {
                $returned = $true
                break
            }
        }
        catch {
        }
        Sleep-MS 500
    }

    if (-not $returned) {
        Write-Host "Faculty list did not return."
        Write-Host "The current evaluation may have been submitted."
        $processed++
        break
    }

    $processed++
    Write-Host "Faculty evaluation #$processed completed."
}

Write-Host ""
Write-Host "Closing CDP connection..."

try {
    if ($script:WebSocket) {
        $script:WebSocket.Dispose()
    }
}
catch {
}

Write-Host ""
Write-Host "================================================"
Write-Host "FACULTY EVALUATION COMPLETED"
Write-Host "================================================"
Write-Host "Processed evaluations: $processed"
Write-Host "================================================"
```
