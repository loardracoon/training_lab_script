<#
.SYNOPSIS
  Monitor USB insertions and trigger Sophos scan with caching & logging.

.DESCRIPTION
  - Keeps a FIFO cache of up to 10 USB device serials scanned within last 24h.
  - Skips scan if same USB re-inserted within 24h (unless --no-cache).
  - Logs service start, USB detection, scan success/failure/bypass, service stop.
  - Supports arguments: --debug (console output), --no-cache, --noui.
#>

param(
    [switch]$Debug,
    [switch]$NoCache,
    [switch]$NoUI
)

### Paths & Settings ###
$scriptDir   = "C:\Scripts"
$logFile     = Join-Path $scriptDir "usb-monitor-log.txt"
$cacheFile   = Join-Path $scriptDir "usb-monitor-cache.json"
$maxCache    = 10
$cacheWindow = (Get-Date).AddHours(-24)
$sophiExe    = "C:\Program Files\Sophos\Endpoint Defense\SophosInterceptXCLI.exe"
$scanArgs    = "scan --quick" + ($NoUI ? " --noui" : "")

# Ensure script directory exists
if (-not (Test-Path $scriptDir)) {
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
}

# Logging function
function Write-Log {
    param($level, $message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$level] $message"
    Add-Content -Path $logFile -Value $line
    if ($Debug) { Write-Host $line }
}

# Load or initialize cache (array of @{ Serial; Time })
function Load-Cache {
    if (Test-Path $cacheFile) {
        try { 
            $json = Get-Content $cacheFile -Raw
            return (ConvertFrom-Json $json)
        } catch {
            Write-Log "ERROR" "Failed to read cache: $_"
            return @()
        }
    }
    return @()
}

# Save cache array back to disk
function Save-Cache($arr) {
    try {
        $arr | ConvertTo-Json -Depth 2 | Set-Content -Path $cacheFile
    } catch {
        Write-Log "ERROR" "Failed to write cache: $_"
    }
}

# Add an entry (Serial) to cache, enforce FIFO & window
function Add-ToCache($serial) {
    $cache = Load-Cache
    # prune old (>24h)
    $cache = $cache | Where-Object { [DateTime]$_."Time" -ge $cacheWindow }
    # remove if exists
    $cache = $cache | Where-Object { $_.Serial -ne $serial }
    # append
    $cache += [PSCustomObject]@{ Serial = $serial; Time = (Get-Date) }
    # enforce max
    if ($cache.Count -gt $maxCache) {
        $cache = $cache[($cache.Count - $maxCache)..($cache.Count - 1)]
    }
    Save-Cache $cache
}

# Check if serial in cache within 24h
function Is-InCache($serial) {
    if ($NoCache) { return $false }
    $cache = Load-Cache
    $found = $cache | Where-Object { $_.Serial -eq $serial -and ([DateTime]$_."Time" -ge $cacheWindow) }
    return ($found -ne $null)
}

# Perform the Sophos scan
function Invoke-Scan($driveLetter, $serial) {
    Write-Log "INFO" "Starting scan on $driveLetter (Serial: $serial)"
    try {
        $proc = Start-Process -FilePath $sophiExe `
                              -ArgumentList "$scanArgs `"$driveLetter\`"" `
                              -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Log "INFO" "Scan SUCCESS on $driveLetter (ExitCode=0)"
            Add-ToCache $serial
        } else {
            Write-Log "WARN" "Scan FAILED on $driveLetter (ExitCode=$($proc.ExitCode))"
        }
    } catch {
        Write-Log "ERROR" "Exception during scan on $driveLetter: $_"
    }
}

# Extract unique serial from a USB DiskDrive object
function Get-UsbSerial($driveLetter) {
    try {
        $vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.DriveLetter -eq $driveLetter }
        $assoc = @(Get-WmiObject -Query "ASSOCIATORS OF {Win32_Volume.DeviceID='$($vol.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition")
        $parts = @(Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($assoc[0].DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition")
        $disk  = @(Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($parts[0].DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition")
        # PNPDeviceID often contains the USB serial at end
        $pnp = $disk[0].PNPDeviceID
        return ($pnp -split '\\')[-1]
    } catch {
        Write-Log "ERROR" "Failed to get serial for $driveLetter: $_"
        return ""
    }
}

# Handle each new USB volume event
function OnUsbInserted {
    try {
        $vol = $Event.SourceEventArgs.NewEvent.TargetInstance
        $drive = $vol.DriveLetter
        if (-not $drive) { return }
        Write-Log "DEBUG" "Volume event DriveLetter=$drive"

        $serial = Get-UsbSerial $drive
        if (-not $serial) {
            Write-Log "WARN" "No serial for $drive; skipping cache check."
            Invoke-Scan $drive $serial
            return
        }

        if (Is-InCache $serial) {
            Write-Log "INFO" "Bypass scan for $drive; serial in cache (<24h)"
        } else {
            Invoke-Scan $drive $serial
        }
    } catch {
        Write-Log "ERROR" "Error in event handler: $_"
    }
}

### Main ###
Write-Log "INFO" "Service initializing..."
if (-not (Test-Path $sophiExe)) {
    Write-Log "ERROR" "Sophos executable not found at $sophiExe. Exiting."
    exit 1
}

# Register WMI event for removable volumes (DriveType=2)
Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Volume' AND TargetInstance.DriveType = 2" `
    -SourceIdentifier "UsbMonitorEvent" `
    -Action { OnUsbInserted } | Out-Null

Write-Log "INFO" "USB monitor active. Awaiting events."

# Keep script alive
while ($true) {
    Start-Sleep -Seconds 10
}

# When stopping the script (manual Ctrl+C or service stop), unregister & log
finally {
    Write-Log "INFO" "Service shutting down..."
    Unregister-Event -SourceIdentifier "UsbMonitorEvent"
    Write-Log "INFO" "Service stopped."
}
