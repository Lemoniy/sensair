<#
.SYNOPSIS
  Installs the Sensair firmware on an ESP32-C3 and sets up its WiFi.

.DESCRIPTION
  Does the same as the browser installer: downloads the firmware, flashes it with
  esptool and sends the WiFi credentials to the device via Improv Serial.
  Start it by double-clicking Install-Sensair.cmd. Works with the PowerShell 5.1
  that comes with Windows; esptool is downloaded once on the first run.

.PARAMETER Port
  Serial port of the device, e.g. COM5. Detected automatically if omitted.
.PARAMETER Firmware
  Local .factory.bin to flash instead of downloading the latest release.
.PARAMETER ManifestUrl
  Firmware manifest to download from (the same one the browser installer uses).
.PARAMETER KeepData
  Do not erase the flash first. Keeps the WiFi settings and the Home Assistant key.
.PARAMETER WifiOnly
  Skip flashing and only set up the WiFi of a device that already runs Sensair.
.PARAMETER PauseAtEnd
  Wait for Enter before exiting, so the window stays open (used by Install-Sensair.cmd).

.EXAMPLE
  .\install-sensair.ps1 -Port COM5 -Firmware .\sensair-esp32c3.factory.bin
#>
[CmdletBinding()]
param(
  [string]$Port,
  [string]$Firmware,
  # GitHub Pages of this repository; release.yml points it at the repository it is built in
  [string]$ManifestUrl = 'https://lemoniy.github.io/sensair/firmware/manifest.json',
  [switch]$KeepData,
  [switch]$WifiOnly,
  [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
# The progress bar slows down Invoke-WebRequest considerably in PowerShell 5.1
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# esptool is pinned to a version and checksum, so a tampered download is rejected
$EsptoolVersion = '5.4.0'
$EsptoolSha256 = 'b7f6b9dd301a210b31f4829118c909c84aae23107f9ca1fdc14ccf4d7384be2e'
$EsptoolUrl = "https://github.com/espressif/esptool/releases/download/v$EsptoolVersion/esptool-v$EsptoolVersion-windows-amd64.zip"
$ToolDir = Join-Path $env:LOCALAPPDATA 'Sensair'

# Improv Serial protocol (https://www.improv-wifi.com/serial/)
$TypeCurrentState = 1
$TypeErrorState = 2
$TypeRpcResponse = 4
$CmdWifiSettings = 1
$CmdGetCurrentState = 2
$CmdGetDeviceInfo = 3
$CmdGetWifiNetworks = 4
$StateProvisioned = 4
$ErrorUnableToConnect = 3

$script:Rx = New-Object 'System.Collections.Generic.List[byte]'

function Write-Step([string]$Text) {
  Write-Host ''
  Write-Host "==> $Text" -ForegroundColor Cyan
}

# --- downloads --------------------------------------------------------------

function Get-Esptool {
  $dir = Join-Path $ToolDir "esptool-$EsptoolVersion"
  $exe = Join-Path $dir 'esptool-windows-amd64\esptool.exe'
  if (Test-Path $exe) { return $exe }

  Write-Step "Downloading esptool $EsptoolVersion (only needed once)"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $zip = Join-Path $dir 'esptool.zip'
  Invoke-WebRequest -Uri $EsptoolUrl -OutFile $zip -UseBasicParsing
  if ((Get-FileHash -Path $zip -Algorithm SHA256).Hash -ne $EsptoolSha256) {
    Remove-Item $zip
    throw 'The esptool download is damaged (checksum mismatch). Please try again.'
  }
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  Remove-Item $zip
  if (-not (Test-Path $exe)) { throw 'esptool.exe was not found after unpacking.' }
  return $exe
}

function Get-FirmwareFile {
  if ($Firmware) {
    if (-not (Test-Path $Firmware)) { throw "Firmware file not found: $Firmware" }
    return (Resolve-Path $Firmware).Path
  }

  Write-Step 'Downloading the latest Sensair firmware'
  $manifest = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing
  if ($manifest -is [string]) { $manifest = $manifest | ConvertFrom-Json }
  $build = $manifest.builds | Where-Object { $_.chipFamily -eq 'ESP32-C3' } | Select-Object -First 1
  if (-not $build) { throw 'The firmware manifest has no build for the ESP32-C3.' }
  $part = $build.parts | Select-Object -First 1
  $url = (New-Object System.Uri -ArgumentList ([Uri]$ManifestUrl), $part.path).AbsoluteUri

  $file = Join-Path $env:TEMP 'sensair.factory.bin'
  Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
  if ($part.sha256 -and (Get-FileHash -Path $file -Algorithm SHA256).Hash -ne $part.sha256) {
    throw 'The firmware download is damaged (checksum mismatch). Please try again.'
  }
  Write-Host "Firmware: $($manifest.name) $($manifest.version)"
  return $file
}

# --- serial port and esptool ------------------------------------------------

function Get-SerialPortList {
  # Only USB serial ports: skips built-in COM ports of the mainboard and Bluetooth ports
  Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.Name -match '\(COM\d+\)' -and $_.PNPDeviceID -match '^(USB|FTDIBUS)\\' } |
    ForEach-Object {
      $null = $_.Name -match '\((COM\d+)\)'
      [pscustomobject]@{
        Port      = $Matches[1]
        Name      = $_.Name
        # 303A is Espressif's USB vendor ID (built-in USB of the ESP32-C3)
        Espressif = ($_.PNPDeviceID -match 'VID_303A')
      }
    } |
    Sort-Object { [int]($_.Port -replace '\D', '') }
}

function Select-SerialPort {
  if ($Port) { return $Port }
  while ($true) {
    $ports = @(Get-SerialPortList)
    $esp = @($ports | Where-Object Espressif)
    if ($esp.Count -eq 1) {
      Write-Host "Found: $($esp[0].Name)"
      return $esp[0].Port
    }
    if ($ports.Count -eq 1) {
      Write-Host "Found: $($ports[0].Name)"
      return $ports[0].Port
    }
    if ($ports.Count -gt 1) {
      Write-Host 'Several devices found:'
      for ($i = 0; $i -lt $ports.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $ports[$i].Name)
      }
      $choice = Read-Host 'Which one is the Sensair? Enter the number'
      $n = 0
      if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $ports.Count) {
        return $ports[$n - 1].Port
      }
      continue
    }
    Write-Host 'No device found. Connect the ESP32-C3 with a USB cable that can transfer data.' -ForegroundColor Yellow
    Read-Host 'Press Enter to search again' | Out-Null
  }
}

function Invoke-Esptool([string[]]$Arguments, [switch]$Capture) {
  if ($Capture) {
    # Native programs write to stderr; with 'Stop' PowerShell 5.1 would treat that as an error
    $ErrorActionPreference = 'Continue'
    $out = & $script:Esptool @Arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
  }
  # Run directly in this console, so esptool's progress bar is shown live
  $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
  $proc = Start-Process -FilePath $script:Esptool -ArgumentList ($quoted -join ' ') -NoNewWindow -PassThru
  $null = $proc.Handle  # keeps the exit code available after the process ends
  $proc.WaitForExit()
  return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = '' }
}

function Assert-Esp32C3([string]$PortName) {
  Write-Step "Checking the device on $PortName"
  $r = Invoke-Esptool -Capture -Arguments @('--port', $PortName, 'read-mac')
  if ($r.ExitCode -ne 0) {
    Write-Host $r.Output -ForegroundColor DarkGray
    throw ("Could not connect to the device on $PortName. Try another USB cable, or hold the " +
      'BOOT button while plugging it in, then start again.')
  }
  $chip = 'an unknown chip'
  foreach ($pattern in @('Chip type:\s*(ESP\d+(?:-[A-Z0-9]+)?)', 'Connected to (ESP\d+(?:-[A-Z0-9]+)?)', 'Chip is (ESP\d+(?:-[A-Z0-9]+)?)')) {
    if ($r.Output -match $pattern) { $chip = $Matches[1]; break }
  }
  if ($chip -ne 'ESP32-C3') {
    throw "This device is $chip. The Sensair firmware needs an ESP32-C3."
  }
  Write-Host 'ESP32-C3 found.'
}

function Install-Firmware([string]$PortName, [string]$File) {
  Write-Step 'Installing the firmware (about one minute, do not unplug the device)'
  $flashArgs = @('--chip', 'esp32c3', '--port', $PortName, '--baud', '460800', 'write-flash')
  # Erasing removes old WiFi settings and keys, like "erase" in the browser installer
  if (-not $KeepData) { $flashArgs += '--erase-all' }
  $flashArgs += @('0x0', $File)
  if ((Invoke-Esptool -Arguments $flashArgs).ExitCode -ne 0) {
    throw 'Installing the firmware failed (see the messages above).'
  }
}

# --- Improv Serial ----------------------------------------------------------

function Open-SerialPort([string]$PortName) {
  # After flashing, the ESP32-C3 restarts and its USB port briefly disappears
  $deadline = (Get-Date).AddSeconds(20)
  while ($true) {
    try {
      $sp = New-Object System.IO.Ports.SerialPort -ArgumentList $PortName, 115200
      # DTR/RTS stay off: on the ESP32-C3 they would reset the chip
      $sp.DtrEnable = $false
      $sp.RtsEnable = $false
      $sp.Open()
      $script:Rx.Clear()
      return $sp
    } catch {
      if ((Get-Date) -gt $deadline) {
        throw "Could not open $PortName. Is another program (e.g. a serial monitor) using it?"
      }
      Start-Sleep -Milliseconds 500
    }
  }
}

function Send-ImprovCommand($Serial, [int]$Command, [byte[]]$Payload = @()) {
  $packet = New-Object 'System.Collections.Generic.List[byte]'
  # "IMPROV", version 1, type RPC, length, then command, payload length, payload
  $packet.AddRange([byte[]](0x49, 0x4D, 0x50, 0x52, 0x4F, 0x56, 1, 3, ($Payload.Length + 2), $Command, $Payload.Length))
  $packet.AddRange($Payload)
  $sum = 0
  foreach ($b in $packet) { $sum += $b }
  $packet.Add([byte]($sum -band 0xFF))
  $bytes = $packet.ToArray()
  $Serial.Write($bytes, 0, $bytes.Length)
}

function Get-NextImprovFrame {
  # Picks the next valid Improv frame out of the received bytes; log text is skipped
  $rx = $script:Rx
  while ($true) {
    $start = -1
    for ($i = 0; $i -le $rx.Count - 6; $i++) {
      if ($rx[$i] -eq 0x49 -and $rx[$i + 1] -eq 0x4D -and $rx[$i + 2] -eq 0x50 -and
          $rx[$i + 3] -eq 0x52 -and $rx[$i + 4] -eq 0x4F -and $rx[$i + 5] -eq 0x56) {
        $start = $i
        break
      }
    }
    if ($start -lt 0) {
      if ($rx.Count -gt 5) { $rx.RemoveRange(0, $rx.Count - 5) }
      return $null
    }
    if ($start -gt 0) { $rx.RemoveRange(0, $start) }
    if ($rx.Count -lt 9) { return $null }
    $length = [int]$rx[8]
    $total = 10 + $length
    if ($rx.Count -lt $total) { return $null }
    $sum = 0
    for ($i = 0; $i -lt $total - 1; $i++) { $sum += $rx[$i] }
    if ($rx[6] -ne 1 -or ($sum -band 0xFF) -ne $rx[$total - 1]) {
      $rx.RemoveAt(0)
      continue
    }
    $data = New-Object byte[] $length
    if ($length -gt 0) { $rx.CopyTo(9, $data, 0, $length) }
    $frame = [pscustomobject]@{ Type = [int]$rx[7]; Data = $data }
    $rx.RemoveRange(0, $total)
    return $frame
  }
}

function Wait-ImprovFrame($Serial, [int]$TimeoutMs, [scriptblock]$Match) {
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $n = $Serial.BytesToRead
    if ($n -gt 0) {
      $buffer = New-Object byte[] $n
      $read = $Serial.Read($buffer, 0, $n)
      for ($i = 0; $i -lt $read; $i++) { $script:Rx.Add($buffer[$i]) }
    }
    while ($null -ne ($frame = Get-NextImprovFrame)) {
      if (& $Match $frame) { return $frame }
    }
    Start-Sleep -Milliseconds 50
  }
  return $null
}

function Get-RpcStrings([byte[]]$Data) {
  # RPC response: command, data length, then strings each prefixed by their length
  $strings = @()
  $end = [Math]::Min(2 + $Data[1], $Data.Length)
  $pos = 2
  while ($pos -lt $end) {
    $len = $Data[$pos]
    $strings += [Text.Encoding]::UTF8.GetString($Data, $pos + 1, $len)
    $pos += 1 + $len
  }
  return , $strings
}

function Get-DeviceInfo($Serial, [string]$PortName) {
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    try {
      Send-ImprovCommand $Serial $CmdGetDeviceInfo
      $frame = Wait-ImprovFrame $Serial 1000 { param($f) $f.Type -eq $TypeRpcResponse -and $f.Data[0] -eq $CmdGetDeviceInfo }
      if ($frame) {
        # firmware name, version, chip, device name
        return , (Get-RpcStrings $frame.Data)
      }
    } catch {
      # The port went away during the restart: open it again. .NET errors arrive wrapped
      # in a MethodInvocationException, so any error is handled the same way here.
      Write-Verbose "Serial error: $($_.Exception.Message)"
      try { $Serial.Close() } catch { }
      $Serial = Open-SerialPort $PortName
      $script:Serial = $Serial
    }
  }
  return $null
}

function Get-WifiNetworks($Serial) {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    Send-ImprovCommand $Serial $CmdGetWifiNetworks
    $networks = @{}
    while ($true) {
      $frame = Wait-ImprovFrame $Serial 10000 { param($f) $f.Type -eq $TypeRpcResponse -and $f.Data[0] -eq $CmdGetWifiNetworks }
      if (-not $frame) { break }
      $s = Get-RpcStrings $frame.Data
      # An empty response ends the list
      if ($s.Count -lt 3) { break }
      $rssi = [int]$s[1]
      if ($s[0] -and (-not $networks.ContainsKey($s[0]) -or $networks[$s[0]].Rssi -lt $rssi)) {
        $networks[$s[0]] = [pscustomobject]@{ Ssid = $s[0]; Rssi = $rssi; Secured = ($s[2] -eq 'YES') }
      }
    }
    if ($networks.Count -gt 0) { return @($networks.Values | Sort-Object Rssi -Descending) }
    # The device scans right after starting; give the scan a moment to finish
    Start-Sleep -Seconds 3
  }
  return @()
}

function Get-SignalText([int]$Rssi) {
  if ($Rssi -ge -55) { return 'excellent' }
  if ($Rssi -ge -67) { return 'good' }
  if ($Rssi -ge -75) { return 'fair' }
  return 'weak'
}

function Read-WifiChoice($Networks) {
  while ($true) {
    Write-Host ''
    if ($Networks.Count -gt 0) {
      Write-Host 'WiFi networks the Sensair can see:'
      for ($i = 0; $i -lt $Networks.Count; $i++) {
        $lock = if ($Networks[$i].Secured) { '' } else { ', open' }
        Write-Host ('  [{0}] {1}  ({2}{3})' -f ($i + 1), $Networks[$i].Ssid, (Get-SignalText $Networks[$i].Rssi), $lock)
      }
    } else {
      Write-Host 'The Sensair did not find any WiFi networks.' -ForegroundColor Yellow
    }
    Write-Host '  [0] Enter the name manually (hidden network)'
    $choice = Read-Host 'Choose your WiFi'
    $n = -1
    if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 0 -or $n -gt $Networks.Count) { continue }
    if ($n -eq 0) {
      $ssid = Read-Host 'WiFi name'
      if ($ssid) { return [pscustomobject]@{ Ssid = $ssid; Secured = $true } }
      continue
    }
    return $Networks[$n - 1]
  }
}

function Read-Password([string]$Ssid) {
  $secure = Read-Host "Password for '$Ssid'" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Connect-Wifi($Serial) {
  Write-Step 'Looking for WiFi networks'
  $networks = Get-WifiNetworks $Serial
  while ($true) {
    $network = Read-WifiChoice $networks
    $password = if ($network.Secured) { Read-Password $network.Ssid } else { '' }

    $ssidBytes = [Text.Encoding]::UTF8.GetBytes($network.Ssid)
    $passwordBytes = [Text.Encoding]::UTF8.GetBytes($password)
    $password = $null
    if ($ssidBytes.Length -gt 32 -or $passwordBytes.Length -gt 64) {
      Write-Host 'The WiFi name or password is too long.' -ForegroundColor Yellow
      continue
    }
    [byte[]]$payload = @($ssidBytes.Length) + $ssidBytes + @($passwordBytes.Length) + $passwordBytes

    Write-Step "Connecting the Sensair to '$($network.Ssid)'"
    Send-ImprovCommand $Serial $CmdWifiSettings $payload
    $result = Wait-ImprovFrame $Serial 60000 {
      param($f)
      ($f.Type -eq $TypeCurrentState -and $f.Data[0] -eq $StateProvisioned) -or
      ($f.Type -eq $TypeErrorState -and $f.Data[0] -ne 0)
    }
    if ($result -and $result.Type -eq $TypeCurrentState) { return $network.Ssid }

    if ($result -and $result.Data[0] -eq $ErrorUnableToConnect) {
      Write-Host 'The Sensair could not connect. Please check the password.' -ForegroundColor Yellow
    } else {
      Write-Host 'The Sensair did not report a connection.' -ForegroundColor Yellow
    }
    $again = Read-Host 'Try again? [Y/n]'
    if ($again -match '^(n|no)$') { throw 'WiFi setup cancelled.' }
  }
}

# --- main -------------------------------------------------------------------

$exitCode = 0
$script:Serial = $null
try {
  try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
  Write-Host 'Sensair installer' -ForegroundColor Green
  Write-Host 'Installs the Sensair firmware on an ESP32-C3 and connects it to your WiFi.'

  if (-not $WifiOnly) {
    $script:Esptool = Get-Esptool
    $firmwareFile = Get-FirmwareFile
  }

  Write-Step 'Looking for the device'
  $portName = Select-SerialPort

  if (-not $WifiOnly) {
    Assert-Esp32C3 $portName
    Install-Firmware $portName $firmwareFile
  }

  Write-Step 'Waiting for the Sensair to start'
  $script:Serial = Open-SerialPort $portName
  $info = Get-DeviceInfo $script:Serial $portName
  if (-not $info) {
    throw ('The device does not answer. Unplug it, plug it back in and start again with -WifiOnly. ' +
      'WiFi setup is only possible within 15 minutes after the Sensair is powered up.')
  }
  $deviceName = if ($info.Count -ge 4) { $info[3] } else { 'The Sensair' }
  Write-Host "$deviceName is running $($info[0]) $($info[1])."

  Send-ImprovCommand $script:Serial $CmdGetCurrentState
  $state = Wait-ImprovFrame $script:Serial 2000 { param($f) $f.Type -eq $TypeCurrentState }
  $ssid = $null
  if ($state -and $state.Data[0] -eq $StateProvisioned) {
    $answer = Read-Host 'This Sensair is already connected to a WiFi. Set up a different one? [y/N]'
    if ($answer -match '^(y|yes)$') { $ssid = Connect-Wifi $script:Serial }
  } else {
    $ssid = Connect-Wifi $script:Serial
  }

  Write-Host ''
  if ($ssid) {
    Write-Host "Done! $deviceName is connected to '$ssid'." -ForegroundColor Green
  } else {
    Write-Host "Done! $deviceName keeps its WiFi settings." -ForegroundColor Green
  }
  Write-Host 'Next: open Home Assistant > Settings > Devices & services. The Sensair shows up'
  Write-Host 'there as a discovered device; click "Add". Do this within 15 minutes, otherwise'
  Write-Host 'unplug the Sensair for a few seconds and plug it back in.'
  Write-Host 'You can now unplug the Sensair from the computer and use any USB power supply.'
} catch {
  Write-Host ''
  Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
  $exitCode = 1
} finally {
  if ($script:Serial) { try { $script:Serial.Close() } catch { } }
}

if ($PauseAtEnd) { Read-Host 'Press Enter to close this window' | Out-Null }
exit $exitCode
