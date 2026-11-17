$ErrorActionPreference = "Continue"
$Pass = if ($env:RDP_PASS) { $env:RDP_PASS } else { "WinCloud!2026Pass" }
$NgrokTok = $env:NGROK_TOK
$GhToken = $env:GH_TOKEN
$Repo = $env:GH_REPO

Write-Host "[WinCloud] Enabling Windows Remote Desktop (Port 3389)..."
net user runneradmin "$Pass"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 0

# Disable RDP certificate warning prompt and start loopback session so Windows renders a live desktop
New-Item -Path "HKCU:\Software\Microsoft\Terminal Server Client" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Terminal Server Client" -Name "AuthenticationLevelOverride" -Value 0 -Type DWord -Force
cmdkey /generic:TERMSRV/127.0.0.1 /user:runneradmin /pass:"$Pass"
Start-Process mstsc.exe -ArgumentList "/v:127.0.0.1 /w:1280 /h:720"
Start-Sleep -Seconds 3

# 1. Start Bore.pub Free TCP Tunnel (Zero Credit Card, Zero Account)
try {
  Invoke-WebRequest -Uri "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-pc-windows-msvc.zip" -OutFile bore.zip -UseBasicParsing
  Expand-Archive bore.zip -DestinationPath . -Force
  Start-Process -FilePath ".\bore.exe" -ArgumentList "local 3389 --to bore.pub" -RedirectStandardOutput "bore.log" -RedirectStandardError "bore_err.log" -NoNewWindow
} catch {
  Write-Host "Bore setup warning: $_"
}

# 2. Start Pinggy Free SSH TCP Tunnel (Zero Credit Card, Zero Account)
try {
  if (!(Test-Path "$env:USERPROFILE\.ssh\id_rsa")) {
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    ssh-keygen -t rsa -b 2048 -f "$env:USERPROFILE\.ssh\id_rsa" -N '""' | Out-Null
  }
  "" | Out-File -FilePath "empty_in.txt" -Encoding ascii
  Start-Process -FilePath "ssh.exe" -ArgumentList "-p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ServerAliveInterval=30 -T -R0:127.0.0.1:3389 tcp@free.pinggy.io" -RedirectStandardInput "empty_in.txt" -RedirectStandardOutput "pinggy.log" -RedirectStandardError "pinggy_err.log" -NoNewWindow
} catch {
  Write-Host "Pinggy setup warning: $_"
}

# 3. Optional Ngrok (Wrapped so ERR_NGROK_8013 never crashes the workflow)
if ($NgrokTok -and $NgrokTok.Trim().Length -gt 5) {
  try {
    Invoke-WebRequest -Uri "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" -OutFile ngrok.zip -UseBasicParsing
    Expand-Archive ngrok.zip -DestinationPath . -Force
    .\ngrok.exe config add-authtoken "$NgrokTok" 2>&1 | Out-Null
    Start-Process -FilePath ".\ngrok.exe" -ArgumentList "tcp 3389" -NoNewWindow
  } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$winInputCode = 'using System; using System.Runtime.InteropServices; public class WinInput { [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y); [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo); public const uint MOUSEEVENTF_LEFTDOWN = 0x0002; public const uint MOUSEEVENTF_LEFTUP = 0x0004; public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008; public const uint MOUSEEVENTF_RIGHTUP = 0x0010; }'
Add-Type -TypeDefinition $winInputCode -ErrorAction SilentlyContinue

function Capture-ScreenBase64 {
  try {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = if ($bounds.Width -gt 0) { $bounds.Width } else { 1280 }
    $h = if ($bounds.Height -gt 0) { $bounds.Height } else { 720 }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $graphics.Dispose()
    $bmp.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()
    return @{ b64 = $b64; w = $w; h = $h }
  } catch {
    return @{ b64 = ""; w = 1280; h = 720 }
  }
}

function Get-LiveTunnels {
  $pinggyUrl = ""
  $boreUrl = ""
  $ngrokUrl = ""
  if (Test-Path "bore.log") {
    $bContent = Get-Content "bore.log" -Raw -ErrorAction SilentlyContinue
    if ($bContent -match "listening at (bore\.pub:\d+)") { $boreUrl = $Matches[1] }
  }
  if (Test-Path "pinggy.log") {
    $pContent = Get-Content "pinggy.log" -Raw -ErrorAction SilentlyContinue
    if ($pContent -match "tcp://([a-zA-Z0-9.-]+:\d+)") { $pinggyUrl = $Matches[1] }
  }
  try {
    $ng = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 1 -ErrorAction SilentlyContinue
    if ($ng -and $ng.tunnels -and $ng.tunnels.Count -gt 0) {
      $ngrokUrl = $ng.tunnels[0].public_url -replace "^tcp://", ""
    }
  } catch {}
  return @{ bore = $boreUrl; pinggy = $pinggyUrl; ngrok = $ngrokUrl }
}

$GhHeaders = @{
  "Authorization"        = "Bearer $GhToken"
  "Accept"               = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"           = "WinCloud10-Agent"
}

$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:LastAckedSeq = 0
$script:LastStatusPush = [DateTime]::MinValue
$script:LastRdpPublished = ""

function Add-Log([string]$line) {
  $script:LogBuffer.Add($line)
  if ($script:LogBuffer.Count -gt 60) {
    $script:LogBuffer.RemoveAt(0)
  }
}

function Publish-Status($force) {
  $t = Get-LiveTunnels
  $primaryRdp = if ($t.ngrok) { $t.ngrok } elseif ($t.bore) { $t.bore } else { $t.pinggy }
  $backupRdp  = if ($t.pinggy) { $t.pinggy } else { $t.bore }

  $now = Get-Date
  $elapsed = ($now - $script:LastStatusPush).TotalSeconds
  if (-not $force -and $primaryRdp -eq $script:LastRdpPublished -and $elapsed -lt 15) {
    return
  }

  $script:LastStatusPush = $now
  $script:LastRdpPublished = $primaryRdp

  $scr = Capture-ScreenBase64
  $osInfo = Get-CimInstance Win32_OperatingSystem
  $freeMem = [math]::Round($osInfo.FreePhysicalMemory / 1024)
  $totMem  = [math]::Round($osInfo.TotalVisibleMemorySize / 1024)

  $statusObj = @{
    updatedAt        = (Get-Date).ToUniversalTime().ToString("o")
    hostname         = $env:COMPUTERNAME
    osCaption        = $osInfo.Caption
    publicRdpUrl     = $primaryRdp
    backupRdpUrl     = $backupRdp
    username         = "runneradmin"
    password         = $Pass
    freeRamMb        = $freeMem
    totalRamMb       = $totMem
    lastAckedSeq     = $script:LastAckedSeq
    screenshotBase64 = $scr.b64
    screenWidth      = $scr.w
    screenHeight     = $scr.h
    logs             = @($script:LogBuffer)
  }

  $jsonText = $statusObj | ConvertTo-Json -Depth 4 -Compress
  $b64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonText))

  $sha = $null
  try {
    $existing = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/contents/state/status.json" -Headers $GhHeaders -TimeoutSec 8 -ErrorAction SilentlyContinue
    if ($existing -and $existing.sha) { $sha = $existing.sha }
  } catch {}

  $putObj = @{
    message = "Heartbeat from Windows VM"
    content = $b64Content
  }
  if ($sha) { $putObj.sha = $sha }

  $putBody = $putObj | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/contents/state/status.json" -Method PUT -Headers $GhHeaders -Body $putBody -ContentType "application/json" -TimeoutSec 12 | Out-Null
    Write-Host "[WinCloud] Synced status.json | Primary RDP: $primaryRdp | Backup: $backupRdp"
  } catch {
    Write-Host "[WinCloud] Failed to update status.json: $_"
  }
}

Start-Sleep -Seconds 6
$tInit = Get-LiveTunnels
Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Windows VM $env:COMPUTERNAME online!"
if ($tInit.bore) { Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Bore TCP RDP: $($tInit.bore)" }
if ($tInit.pinggy) { Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Pinggy TCP RDP: $($tInit.pinggy)" }
Publish-Status $true

$cmdEtag = ""

while ($true) {
  try {
    $cmdHeaders = @{
      "Authorization"        = "Bearer $GhToken"
      "Accept"               = "application/vnd.github.raw+json"
      "X-GitHub-Api-Version" = "2022-11-28"
      "User-Agent"           = "WinCloud10-Agent"
    }
    if ($cmdEtag) { $cmdHeaders["If-None-Match"] = $cmdEtag }

    $cmdResp = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/contents/state/cmd.json" -Headers $cmdHeaders -UseBasicParsing -TimeoutSec 8 -ErrorAction SilentlyContinue
    if ($cmdResp -and $cmdResp.StatusCode -eq 200) {
      if ($cmdResp.Headers["ETag"]) { $cmdEtag = $cmdResp.Headers["ETag"] }
      $cmdObj = $cmdResp.Content | ConvertFrom-Json
      if ($cmdObj -and $cmdObj.seq -gt $script:LastAckedSeq) {
        $script:LastAckedSeq = [int]$cmdObj.seq
        if ($cmdObj.type -eq "click") {
          [WinInput]::SetCursorPos([int]$cmdObj.x, [int]$cmdObj.y)
          if ($cmdObj.button -eq "right") {
            [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0)
            [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0)
          } else {
            [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            if ($cmdObj.button -eq "double") {
              Start-Sleep -Milliseconds 80
              [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
              [WinInput]::mouse_event([WinInput]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            }
          }
          Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Clicked at ($($cmdObj.x), $($cmdObj.y))"
          Start-Sleep -Milliseconds 400
          Publish-Status $true
        } elseif ($cmdObj.type -eq "key") {
          [System.Windows.Forms.SendKeys]::SendWait($cmdObj.text)
          Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Sent keys: $($cmdObj.text)"
          Start-Sleep -Milliseconds 400
          Publish-Status $true
        } elseif ($cmdObj.command) {
          $cmdStr = $cmdObj.command
          Add-Log "[$(Get-Date -Format 'HH:mm:ss')] PS> $cmdStr"
          $outStr = ""
          try {
            $outStr = (Invoke-Expression $cmdStr 2>&1 | Out-String).Trim()
          } catch {
            $outStr = "ERROR: $($_.Exception.Message)"
          }
          if ($outStr) { Add-Log $outStr } else { Add-Log "(Completed)" }
          Publish-Status $true
        }
      }
    }
  } catch {}

  Publish-Status $false
  Start-Sleep -Seconds 3
}
