$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Pass = if ($env:RDP_PASS) { $env:RDP_PASS } else { "WinCloud!2026Pass" }
$NgrokTok = $env:NGROK_TOK
$GhToken = $env:GH_TOKEN
$Repo = $env:GH_REPO

Write-Host "[WinCloud] Configuring Windows 10-gen RDP (Multi-session + Smooth Graphics)..."
net user runneradmin "$Pass"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fSingleSessionPerUser" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 0
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name "bEnumerateHWBeforeSW" -Value 1 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name "fEnableVirtualizedGraphics" -Value 1 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name "AVC444ModePreferred" -Value 1 -Type DWord -Force

# 1. Start Bore.pub Free TCP Tunnel (No card required)
Write-Host "[WinCloud] Starting Bore.pub TCP tunnel (port 3389)..."
try {
  Invoke-WebRequest -Uri "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-pc-windows-msvc.zip" -OutFile bore.zip -UseBasicParsing
  Expand-Archive bore.zip -DestinationPath . -Force
  Start-Process -FilePath ".\bore.exe" -ArgumentList "local 3389 --to bore.pub" -RedirectStandardOutput "bore.log" -RedirectStandardError "bore_err.log" -WindowStyle Hidden
} catch {
  Write-Host "[WinCloud] Bore start warning: $($_.Exception.Message)"
}

# 2. Start Pinggy Free SSH TCP Tunnel (No card required)
Write-Host "[WinCloud] Starting Pinggy SSH TCP tunnel (port 3389)..."
try {
  if (!(Test-Path "$env:USERPROFILE\.ssh\id_rsa")) {
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    ssh-keygen -t rsa -b 2048 -f "$env:USERPROFILE\.ssh\id_rsa" -N '""' | Out-Null
  }
  "" | Out-File -FilePath "empty_in.txt" -Encoding ascii
  Start-Process -FilePath "ssh.exe" -ArgumentList "-p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ServerAliveInterval=30 -T -R0:127.0.0.1:3389 tcp@free.pinggy.io" -RedirectStandardInput "empty_in.txt" -RedirectStandardOutput "pinggy.log" -RedirectStandardError "pinggy_err.log" -WindowStyle Hidden
} catch {
  Write-Host "[WinCloud] Pinggy start warning: $($_.Exception.Message)"
}

# 3. Optional Ngrok (Hidden output so ERR_NGROK_8013 never breaks or floods logs)
if ($NgrokTok -and $NgrokTok.Trim().Length -gt 5) {
  try {
    Invoke-WebRequest -Uri "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" -OutFile ngrok.zip -UseBasicParsing
    Expand-Archive ngrok.zip -DestinationPath . -Force
    .\ngrok.exe config add-authtoken "$NgrokTok" 2>&1 | Out-Null
    Start-Process -FilePath ".\ngrok.exe" -ArgumentList "tcp 3389" -RedirectStandardOutput "ngrok.log" -RedirectStandardError "ngrok_err.log" -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $ngErr = ""
    if (Test-Path "ngrok_err.log") { $ngErr += (Get-Content "ngrok_err.log" -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path "ngrok.log") { $ngErr += (Get-Content "ngrok.log" -Raw -ErrorAction SilentlyContinue) }
    if ($ngErr -match "ERR_NGROK_8013") {
      Write-Host "[WinCloud] Ngrok TCP skipped (free account requires card). Using Bore.pub + Pinggy instead."
    }
  } catch {}
}

function Capture-ScreenOnDemand {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($bounds.Width -le 0) { return "" }
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $small = New-Object System.Drawing.Bitmap 800, 450
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.DrawImage($bmp, 0, 0, 800, 450)
    $ms = New-Object System.IO.MemoryStream
    $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g2.Dispose(); $small.Dispose(); $g.Dispose(); $bmp.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()
    return $b64
  } catch {
    return ""
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
$script:LastScreenshot = ""

function Add-Log([string]$line) {
  $script:LogBuffer.Add($line)
  if ($script:LogBuffer.Count -gt 40) { $script:LogBuffer.RemoveAt(0) }
}

function Publish-Status($force) {
  $t = Get-LiveTunnels
  $primaryRdp = if ($t.ngrok) { $t.ngrok } elseif ($t.bore) { $t.bore } else { $t.pinggy }
  $backupRdp  = if ($t.pinggy) { $t.pinggy } else { $t.bore }

  $now = Get-Date
  $elapsed = ($now - $script:LastStatusPush).TotalSeconds
  if (-not $force -and $primaryRdp -eq $script:LastRdpPublished -and $elapsed -lt 25) {
    return
  }

  $script:LastStatusPush = $now
  $script:LastRdpPublished = $primaryRdp

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
    screenshotBase64 = $script:LastScreenshot
    logs             = @($script:LogBuffer)
  }

  $jsonText = $statusObj | ConvertTo-Json -Depth 4 -Compress
  $b64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonText))

  for ($try = 0; $try -lt 2; $try++) {
    $sha = $null
    try {
      $existing = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/contents/state/status.json" -Headers $GhHeaders -TimeoutSec 8 -ErrorAction SilentlyContinue
      if ($existing -and $existing.sha) { $sha = $existing.sha }
    } catch {}

    $putObj = @{ message = "Heartbeat"; content = $b64Content }
    if ($sha) { $putObj.sha = $sha }
    $putBody = $putObj | ConvertTo-Json -Compress
    try {
      Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/contents/state/status.json" -Method PUT -Headers $GhHeaders -Body $putBody -ContentType "application/json" -TimeoutSec 10 | Out-Null
      break
    } catch {
      if ($try -eq 1) {
        Write-Host "[WinCloud] Publish-Status retry failed: $($_.Exception.Message)"
      }
      Start-Sleep -Milliseconds 500
    }
  }
}

for ($w = 0; $w -lt 8; $w++) {
  Start-Sleep -Seconds 2
  $tCheck = Get-LiveTunnels
  if ($tCheck.bore -or $tCheck.pinggy -or $tCheck.ngrok) { break }
}
$tInit = Get-LiveTunnels
Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Windows 10-gen VM $env:COMPUTERNAME online (Lightweight Mode)!"
if ($tInit.bore) {
  Write-Host "[WinCloud] READY Bore TCP: $($tInit.bore)"
  Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Bore TCP: $($tInit.bore)"
}
if ($tInit.pinggy) {
  Write-Host "[WinCloud] READY Pinggy TCP: $($tInit.pinggy)"
  Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Pinggy TCP: $($tInit.pinggy)"
}
Write-Host "[WinCloud] Publishing status to WinCloud dashboard..."
Publish-Status $true
Write-Host "[WinCloud] Agent loop active. Waiting for RDP connections & PowerShell commands..."

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
        if ($cmdObj.type -eq "screenshot") {
          $script:LastScreenshot = Capture-ScreenOnDemand
          Add-Log "[$(Get-Date -Format 'HH:mm:ss')] Captured desktop screenshot."
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
  Start-Sleep -Seconds 4
}
