$ErrorActionPreference = "Stop"

$Url = "https://student.mist.ac.bd/semester-evaluation/faculty-evaluation"
$Port = 9222
$CdpListUrl = "http://127.0.0.1:$Port/json/list"

function Sleep-MS {
    param([int]$Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

Write-Host ""
Write-Host "================================================"
Write-Host "MIST UNIPLEX FACULTY EVALUATION"
Write-Host "================================================"
Write-Host ""
Write-Host "Checking currently operating Microsoft Edge..."
Write-Host ""

try {
    $existingPages = Invoke-RestMethod -Uri $CdpListUrl -Method Get -TimeoutSec 3
}
catch {
    Write-Host ""
    Write-Host "ERROR: Cannot connect to Microsoft Edge."
    Write-Host ""
    Write-Host "Edge must be running with remote debugging"
    Write-Host "enabled on port 9222."
    Write-Host ""
    exit 1
}

Write-Host "Microsoft Edge debugging interface detected."
Write-Host ""
Write-Host "Opening UNIPLEX in a NEW Edge tab..."
Write-Host ""

$newTab = $null

try {
    $newTabUrl = "http://127.0.0.1:$Port/json/new?" + [System.Uri]::EscapeDataString($Url)
    $newTab = Invoke-RestMethod -Uri $newTabUrl -Method Put -TimeoutSec 5
}
catch {
    Write-Host ""
    Write-Host "ERROR: Could not create a new Edge tab."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    exit 1
}

Write-Host "Waiting for new UNIPLEX tab..."

$page = $null

for ($i = 0; $i -lt 40; $i++) {
    try {
        $pages = Invoke-RestMethod -Uri $CdpListUrl -Method Get -TimeoutSec 2

        if ($newTab.id) {
            foreach ($p in $pages) {
                if ($p.id -eq $newTab.id -and $p.type -eq "page" -and $p.webSocketDebuggerUrl) {
                    $page = $p
                    break
                }
            }
        }

        if (-not $page) {
            foreach ($p in $pages) {
                if ($p.type -ne "page") {
                    continue
                }

                if (-not $p.webSocketDebuggerUrl) {
                    continue
                }

                $pUrl = [string]$p.url

                if ($pUrl -like "view-source:*") {
                    continue
                }

                if ($pUrl -like "devtools:*") {
                    continue
                }

                if ($pUrl -like "https://student.mist.ac.bd/*") {
                    $page = $p
                    break
                }
            }
        }

        if ($page) {
            break
        }
    }
    catch {
    }

    Sleep-MS 500
}

if (-not $page) {
    Write-Host ""
    Write-Host "ERROR: New UNIPLEX tab was not detected."
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "New Edge tab detected."
Write-Host "Page: $($page.url)"
Write-Host ""

$WebSocket = New-Object System.Net.WebSockets.ClientWebSocket
$WsUri = [System.Uri]$page.webSocketDebuggerUrl

try {
    $WebSocket.ConnectAsync(
        $WsUri,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()
}
catch {
    Write-Host ""
    Write-Host "ERROR: Could not connect to Edge tab."
    Write-Host $_.Exception.Message
    Write-Host ""
    exit 1
}

$script:CdpId = 0

function Invoke-CDP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $script:CdpId++
    $id = $script:CdpId

    $message = @{
        id = $id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)

    $WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()

    $fullMessage = New-Object System.Text.StringBuilder

    while ($true) {
        $buffer = New-Object byte[] 65536
        $receiveSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)

        $result = $WebSocket.ReceiveAsync(
            $receiveSegment,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        if ($result.Count -gt 0) {
            $chunk = [System.Text.Encoding]::UTF8.GetString(
                $buffer,
                0,
                $result.Count
            )

            [void]$fullMessage.Append($chunk)
        }

        if ($result.EndOfMessage) {
            $json = $fullMessage.ToString()
            $fullMessage.Clear()

            try {
                $response = $json | ConvertFrom-Json

                if ($response.id -eq $id) {
                    if ($response.error) {
                        throw ("CDP error: " + $response.error.message)
                    }

                    return $response
                }
            }
            catch {
                if ($_.Exception.Message -like "CDP error:*") {
                    throw
                }
            }
        }
    }
}

function Invoke-JavaScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script
    )

    $response = Invoke-CDP `
        -Method "Runtime.evaluate" `
        -Params @{
            expression = $Script
            returnByValue = $true
            awaitPromise = $true
        }

    if ($response.result.exceptionDetails) {
        throw ($response.result.exceptionDetails.text)
    }

    if ($null -eq $response.result.result.value) {
        return $null
    }

    return $response.result.result.value
}

Invoke-CDP "Runtime.enable" | Out-Null
Invoke-CDP "Page.enable" | Out-Null

$currentUrl = Invoke-JavaScript "location.href"

if ($currentUrl -like "view-source:*") {
    Write-Host ""
    Write-Host "WARNING: view-source page detected."
    Write-Host "Navigating to actual UNIPLEX page..."

    Invoke-CDP `
        -Method "Page.navigate" `
        -Params @{
            url = $Url
        } | Out-Null

    Sleep-MS 3000
}

Write-Host ""
Write-Host "================================================"
Write-Host "UNIPLEX LOGIN"
Write-Host "================================================"
Write-Host ""
Write-Host "If login is required, log in inside the NEW Edge tab."
Write-Host ""
Write-Host "The script will automatically detect the"
Write-Host "Faculty Evaluation page."
Write-Host ""
Write-Host "Waiting for Faculty Evaluation..."
Write-Host ""

$listDetected = $false

for ($i = 0; $i -lt 600; $i++) {
    try {
        $state = Invoke-JavaScript @'
(() => {
    const buttons = [...document.querySelectorAll("button")];
    const evaluate = buttons.filter(button => {
        const r = button.getBoundingClientRect();
        const s = getComputedStyle(button);

        return (
            r.width > 0 &&
            r.height > 0 &&
            s.display !== "none" &&
            s.visibility !== "hidden" &&
            (button.innerText || "").trim() === "Evaluate"
        );
    });

    return {
        count: evaluate.length,
        url: location.href
    };
})()
'@

        if ($state.count -gt 0) {
            $listDetected = $true
            break
        }
    }
    catch {
    }

    Sleep-MS 1000
}

if (-not $listDetected) {
    Write-Host ""
    Write-Host "ERROR: Faculty Evaluation list was not detected."
    Write-Host ""

    try {
        $WebSocket.Dispose()
    }
    catch {
    }

    exit 1
}

$initialCount = [int](Invoke-JavaScript @'
(() => {
    return [...document.querySelectorAll("button")]
        .filter(button => {
            const r = button.getBoundingClientRect();
            const s = getComputedStyle(button);

            return (
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden" &&
                (button.innerText || "").trim() === "Evaluate"
            );
        }).length;
})()
'@)

Write-Host "Faculty Evaluation list detected."
Write-Host "Evaluate buttons found: $initialCount"
Write-Host ""

function Click-At {
    param(
        [double]$X,
        [double]$Y
    )

    Invoke-CDP `
        -Method "Input.dispatchMouseEvent" `
        -Params @{
            type = "mouseMoved"
            x = $X
            y = $Y
        } | Out-Null

    Invoke-CDP `
        -Method "Input.dispatchMouseEvent" `
        -Params @{
            type = "mousePressed"
            x = $X
            y = $Y
            button = "left"
            clickCount = 1
            buttons = 1
        } | Out-Null

    Invoke-CDP `
        -Method "Input.dispatchMouseEvent" `
        -Params @{
            type = "mouseReleased"
            x = $X
            y = $Y
            button = "left"
            clickCount = 1
            buttons = 0
        } | Out-Null
}

function Send-CtrlA {
    Invoke-CDP `
        -Method "Input.dispatchKeyEvent" `
        -Params @{
            type = "keyDown"
            modifiers = 2
            key = "a"
            code = "KeyA"
            windowsVirtualKeyCode = 65
        } | Out-Null

    Invoke-CDP `
        -Method "Input.dispatchKeyEvent" `
        -Params @{
            type = "keyUp"
            modifiers = 2
            key = "a"
            code = "KeyA"
            windowsVirtualKeyCode = 65
        } | Out-Null
}

function Get-EvaluateCount {
    return [int](Invoke-JavaScript @'
(() => {
    return [...document.querySelectorAll("button")]
        .filter(button => {
            const r = button.getBoundingClientRect();
            const s = getComputedStyle(button);

            return (
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden" &&
                (button.innerText || "").trim() === "Evaluate"
            );
        }).length;
})()
'@)
}

function Get-MuiTextarea {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field
    )

    $js = @"
(() => {
    const field = "$Field".toLowerCase();

    if (field === "recommendations") {
        const textarea = document.querySelector('textarea[name="recommendations"]');

        if (textarea) {
            const r = textarea.getBoundingClientRect();
            const s = getComputedStyle(textarea);

            if (
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden"
            ) {
                return {
                    found: true,
                    id: textarea.id,
                    name: textarea.name,
                    x: r.left + r.width / 2,
                    y: r.top + r.height / 2,
                    value: textarea.value
                };
            }
        }

        return {
            found: false,
            reason: "Visible recommendations textarea not found"
        };
    }

    const labels = [...document.querySelectorAll("label")];

    const label = labels.find(label => {
        const text = (label.innerText || "").trim().toLowerCase();

        return (
            text.includes("overall comments") ||
            text.includes("overall comment")
        );
    });

    if (!label) {
        return {
            found: false,
            reason: "Overall Comments label not found"
        };
    }

    const id = label.getAttribute("for");

    if (!id) {
        return {
            found: false,
            reason: "Overall Comments label has no FOR attribute"
        };
    }

    const textarea = document.getElementById(id);

    if (!textarea) {
        return {
            found: false,
            reason: "Textarea associated with Overall Comments label not found"
        };
    }

    const r = textarea.getBoundingClientRect();
    const s = getComputedStyle(textarea);

    if (
        r.width <= 0 ||
        r.height <= 0 ||
        s.display === "none" ||
        s.visibility === "hidden"
    ) {
        return {
            found: false,
            reason: "Overall Comments textarea is not visible"
        };
    }

    return {
        found: true,
        id: textarea.id,
        name: textarea.name,
        x: r.left + r.width / 2,
        y: r.top + r.height / 2,
        value: textarea.value
    };
})()
"@

    return Invoke-JavaScript $js
}

function Focus-MuiTextarea {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field
    )

    $js = @"
(() => {
    const field = "$Field".toLowerCase();
    let textarea = null;

    if (field === "recommendations") {
        textarea = document.querySelector('textarea[name="recommendations"]');
    }
    else {
        const labels = [...document.querySelectorAll("label")];

        const label = labels.find(label => {
            const text = (label.innerText || "").trim().toLowerCase();

            return (
                text.includes("overall comments") ||
                text.includes("overall comment")
            );
        });

        if (label) {
            const id = label.getAttribute("for");

            if (id) {
                textarea = document.getElementById(id);
            }
        }
    }

    if (!textarea) {
        return false;
    }

    textarea.scrollIntoView({
        behavior: "instant",
        block: "center"
    });

    textarea.focus();

    return document.activeElement === textarea;
})()
"@

    return Invoke-JavaScript $js
}

function Set-MuiTextareaByReact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field
    )

    $js = @"
(() => {
    const field = "$Field".toLowerCase();
    let textarea = null;

    if (field === "recommendations") {
        textarea = document.querySelector('textarea[name="recommendations"]');
    }
    else {
        const labels = [...document.querySelectorAll("label")];

        const label = labels.find(label => {
            const text = (label.innerText || "").trim().toLowerCase();

            return (
                text.includes("overall comments") ||
                text.includes("overall comment")
            );
        });

        if (label) {
            const id = label.getAttribute("for");

            if (id) {
                textarea = document.getElementById(id);
            }
        }
    }

    if (!textarea) {
        return false;
    }

    textarea.focus();

    const setter = Object.getOwnPropertyDescriptor(
        HTMLTextAreaElement.prototype,
        "value"
    ).set;

    setter.call(textarea, "NAN");

    textarea.dispatchEvent(
        new InputEvent(
            "input",
            {
                bubbles: true,
                inputType: "insertText",
                data: "NAN"
            }
        )
    );

    textarea.dispatchEvent(
        new Event(
            "change",
            {
                bubbles: true
            }
        )
    );

    return textarea.value;
})()
"@

    return Invoke-JavaScript $js
}

function Set-MuiTextareaNAN {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    Write-Host ""
    Write-Host "---------------------------------------------"
    Write-Host "Filling $DisplayName"
    Write-Host "---------------------------------------------"

    $info = Get-MuiTextarea $Field

    if (-not $info.found) {
        Write-Host ""
        Write-Host "ERROR: $DisplayName not found."
        Write-Host "Reason: $($info.reason)"
        return $false
    }

    Write-Host "Textarea ID   : $($info.id)"
    Write-Host "Textarea name : $($info.name)"
    Write-Host "Current value : [$($info.value)]"

    $focused = Focus-MuiTextarea $Field

    if (-not $focused) {
        Write-Host ""
        Write-Host "ERROR: Could not focus $DisplayName."
        return $false
    }

    Sleep-MS 300
    Send-CtrlA
    Sleep-MS 150

    Invoke-CDP `
        -Method "Input.insertText" `
        -Params @{
            text = "NAN"
        } | Out-Null

    Sleep-MS 600

    Invoke-JavaScript @'
(() => {
    if (document.activeElement) {
        document.activeElement.blur();
    }
})()
'@ | Out-Null

    Sleep-MS 800

    $verify = Get-MuiTextarea $Field

    Write-Host ""
    Write-Host "$DisplayName value: [$($verify.value)]"

    if ($verify.value -eq "NAN") {
        Write-Host "$DisplayName successfully set to NAN."
        return $true
    }

    Write-Host ""
    Write-Host "Normal browser input did not persist."
    Write-Host "Trying React/MUI fallback..."

    $fallback = Set-MuiTextareaByReact $Field

    Sleep-MS 600

    Invoke-JavaScript @'
(() => {
    if (document.activeElement) {
        document.activeElement.blur();
    }
})()
'@ | Out-Null

    Sleep-MS 800

    $verify2 = Get-MuiTextarea $Field

    Write-Host ""
    Write-Host "$DisplayName after fallback: [$($verify2.value)]"

    if ($verify2.value -eq "NAN") {
        Write-Host "$DisplayName successfully set to NAN."
        return $true
    }

    Write-Host ""
    Write-Host "ERROR: Could not set $DisplayName to NAN."
    return $false
}

function Get-DialogSubmit {
    $js = @'
(() => {
    const dialog = document.querySelector('[role="dialog"]');

    if (!dialog) {
        return {
            found: false,
            reason: "MUI dialog not found"
        };
    }

    const buttons = [...dialog.querySelectorAll("button")]
        .filter(button => {
            const r = button.getBoundingClientRect();
            const s = getComputedStyle(button);

            return (
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden" &&
                (button.innerText || "").trim().toLowerCase() === "submit"
            );
        });

    if (!buttons.length) {
        return {
            found: false,
            reason: "Submit button not found inside dialog"
        };
    }

    return buttons.map(button => {
        const r = button.getBoundingClientRect();

        return {
            disabled: button.disabled,
            ariaDisabled: button.getAttribute("aria-disabled"),
            x: r.left + r.width / 2,
            y: r.top + r.height / 2,
            text: (button.innerText || "").trim()
        };
    });
})()
'@

    return Invoke-JavaScript $js
}

$FacultyNumber = 0

while ($true) {
    $clickedEvaluate = Invoke-JavaScript @'
(() => {
    const buttons = [...document.querySelectorAll("button")];

    const evaluate = buttons.find(button => {
        const r = button.getBoundingClientRect();
        const s = getComputedStyle(button);

        return (
            r.width > 0 &&
            r.height > 0 &&
            s.display !== "none" &&
            s.visibility !== "hidden" &&
            (button.innerText || "").trim() === "Evaluate"
        );
    });

    if (!evaluate) {
        return false;
    }

    evaluate.scrollIntoView({
        behavior: "instant",
        block: "center"
    });

    evaluate.click();

    return true;
})()
'@

    if (-not $clickedEvaluate) {
        Write-Host ""
        Write-Host "No more Evaluate buttons found."
        break
    }

    $FacultyNumber++

    Write-Host ""
    Write-Host "================================================"
    Write-Host "PROCESSING FACULTY #$FacultyNumber"
    Write-Host "================================================"

    $formDetected = $false

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $goodCount = [int](Invoke-JavaScript @'
(() => {
    return [...document.querySelectorAll("*")]
        .filter(element => {
            const text = (element.innerText || "").trim();
            const r = element.getBoundingClientRect();
            const s = getComputedStyle(element);

            return (
                text === "Good" &&
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden"
            );
        }).length;
})()
'@)

            if ($goodCount -ge 10) {
                $formDetected = $true
                break
            }
        }
        catch {
        }

        Sleep-MS 500
    }

    if (-not $formDetected) {
        Write-Host ""
        Write-Host "ERROR: Evaluation form did not load."
        break
    }

    $goodSelected = [int](Invoke-JavaScript @'
(() => {
    const elements = [...document.querySelectorAll("*")]
        .filter(element => {
            const text = (element.innerText || "").trim();
            const r = element.getBoundingClientRect();
            const s = getComputedStyle(element);

            return (
                text === "Good" &&
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden"
            );
        });

    const unique = elements.filter(element =>
        !elements.some(other =>
            other !== element &&
            other.contains(element)
        )
    );

    const firstTen = unique.slice(0, 10);

    firstTen.forEach(element => {
        element.scrollIntoView({
            behavior: "instant",
            block: "center"
        });

        element.click();
    });

    return firstTen.length;
})()
'@)

    Write-Host "Good options found: $goodSelected"
    Write-Host "Good options selected: $goodSelected"
    Write-Host "Q1-Q10 -> Good"

    if ($goodSelected -ne 10) {
        Write-Host ""
        Write-Host "ERROR: Could not select Good for all 10 questions."
        break
    }

    Sleep-MS 700

    $firstSubmit = Invoke-JavaScript @'
(() => {
    const buttons = [...document.querySelectorAll("button")];

    const visible = buttons.filter(button => {
        const r = button.getBoundingClientRect();
        const s = getComputedStyle(button);

        return (
            r.width > 0 &&
            r.height > 0 &&
            s.display !== "none" &&
            s.visibility !== "hidden" &&
            (button.innerText || "").trim() === "Submit"
        );
    });

    if (!visible.length) {
        return false;
    }

    visible[0].scrollIntoView({
        behavior: "instant",
        block: "center"
    });

    visible[0].click();

    return true;
})()
'@

    if (-not $firstSubmit) {
        Write-Host ""
        Write-Host "ERROR: First Submit button was not found."
        break
    }

    Write-Host "Evaluation form submitted to comment dialog."

    $dialogReady = $false

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $dialogInfo = Invoke-JavaScript @'
(() => {
    const dialog = document.querySelector('[role="dialog"]');

    if (!dialog) {
        return false;
    }

    const visibleTextareas = [...dialog.querySelectorAll("textarea")]
        .filter(textarea => {
            const r = textarea.getBoundingClientRect();
            const s = getComputedStyle(textarea);

            return (
                r.width > 0 &&
                r.height > 0 &&
                s.display !== "none" &&
                s.visibility !== "hidden"
            );
        });

    return visibleTextareas.length >= 2;
})()
'@

            if ($dialogInfo) {
                $dialogReady = $true
                break
            }
        }
        catch {
        }

        Sleep-MS 500
    }

    if (-not $dialogReady) {
        Write-Host ""
        Write-Host "ERROR: MUI comment dialog did not appear."
        break
    }

    Write-Host "MUI comment dialog detected."

    $commentsOK = Set-MuiTextareaNAN `
        -Field "comments" `
        -DisplayName "Overall Comments"

    if (-not $commentsOK) {
        Write-Host ""
        Write-Host "STOPPED."
        Write-Host "Overall Comments could not be set to NAN."
        Write-Host "Final Submit will NOT be clicked."
        break
    }

    $recommendationsOK = Set-MuiTextareaNAN `
        -Field "recommendations" `
        -DisplayName "Recommendations"

    if (-not $recommendationsOK) {
        Write-Host ""
        Write-Host "STOPPED."
        Write-Host "Recommendations could not be set to NAN."
        Write-Host "Final Submit will NOT be clicked."
        break
    }

    Write-Host ""
    Write-Host "============================================="
    Write-Host "FINAL FIELD VERIFICATION"
    Write-Host "============================================="

    $finalComments = Get-MuiTextarea "comments"
    $finalRecommendations = Get-MuiTextarea "recommendations"

    Write-Host ""
    Write-Host "Overall Comments : [$($finalComments.value)]"
    Write-Host "Recommendations  : [$($finalRecommendations.value)]"
    Write-Host ""

    if (
        -not $finalComments.found -or
        -not $finalRecommendations.found
    ) {
        Write-Host "ERROR: Could not verify both fields."
        Write-Host "Final Submit will NOT be clicked."
        break
    }

    if (
        $finalComments.value -ne "NAN" -or
        $finalRecommendations.value -ne "NAN"
    ) {
        Write-Host "ERROR: One or both fields are not NAN."
        Write-Host "Final Submit will NOT be clicked."
        break
    }

    Write-Host "Both fields contain exactly NAN."
    Write-Host ""
    Write-Host "Waiting for MUI Submit to become enabled..."

    $enabledSubmit = $null

    for ($wait = 0; $wait -lt 40; $wait++) {
        $submitState = Get-DialogSubmit

        if (
            $submitState -and
            $submitState.found -ne $false
        ) {
            $candidates = @(
                $submitState |
                Where-Object {
                    $_.disabled -ne $true -and
                    $_.ariaDisabled -ne "true"
                }
            )

            if ($candidates.Count -gt 0) {
                $enabledSubmit = $candidates[-1]
                break
            }
        }

        Sleep-MS 500
    }

    if (-not $enabledSubmit) {
        Write-Host ""
        Write-Host "ERROR: MUI dialog Submit is still disabled."
        Write-Host ""
        Write-Host "Final submission was NOT performed."
        break
    }

    Write-Host "MUI dialog Submit is ENABLED."
    Write-Host ""
    Write-Host "Clicking final Submit..."

    Click-At `
        -X ([double]$enabledSubmit.x) `
        -Y ([double]$enabledSubmit.y)

    Write-Host "Final Submit clicked successfully."
    Write-Host ""
    Write-Host "Waiting for Faculty Evaluation list..."

    $returned = $false

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $count = Get-EvaluateCount

            if ($count -gt 0) {
                $returned = $true
                break
            }
        }
        catch {
        }

        Sleep-MS 500
    }

    if (-not $returned) {
        Write-Host ""
        Write-Host "ERROR: Faculty list did not return."
        break
    }

    Write-Host "Faculty Evaluation list detected again."
    Write-Host "Moving to next individual faculty..."

    Sleep-MS 1000
}

try {
    if ($WebSocket) {
        $WebSocket.Dispose()
    }
}
catch {
}

Write-Host ""
Write-Host "================================================"
Write-Host "AUTOMATION FINISHED"
Write-Host "================================================"
Write-Host ""
Write-Host "Evaluations processed: $FacultyNumber"
Write-Host ""
Write-Host "================================================"
