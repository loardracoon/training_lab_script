#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# === Default Parameters (edit according to your environment) ===

$HostUrl = "https://10.100.100.1"

$ApiKey = if ($env:VYOS_API_KEY) { $env:VYOS_API_KEY } else { "MY-HTTPS-API-PLAINTEXT-KEY" }  # Set env:VYOS_API_KEY=... if preferred

$Insecure = $true  # $true = skip cert check (self-signed); $false = require valid TLS

$Link = ""

$Profile = ""

$DoSave = $false

function Usage {
    Write-Error @"
Usage: $PSCommandPath -Link <ethX> -Profile <POLICY> [-Save] [-HostUrl https://IP] [-ApiKey <APIKEY>] [-NoInsecure]
Ex.: $PSCommandPath -Link eth1 -Profile HIGHDELAY -Save
"@
    exit 2
}

# Basic parsing using parameters
param(
    [Parameter(Mandatory=$true)]
    [string]$Link,

    [Parameter(Mandatory=$true)]
    [string]$Profile,

    [switch]$Save,

    [string]$HostUrl = "https://10.100.100.1",

    [string]$ApiKey = $(if ($env:VYOS_API_KEY) { $env:VYOS_API_KEY } else { "MY-HTTPS-API-PLAINTEXT-KEY" }),

    [switch]$NoInsecure
)

$DoSave = $Save.IsPresent
$Insecure = -not $NoInsecure.IsPresent

# Minimal validations (reduce injection risk)
if ($Link -notmatch '^[A-Za-z0-9./_-]+$') {
    Write-Error "ERROR: -Link invalid"
    exit 2
}
if ($Profile -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "ERROR: -Profile invalid"
    exit 2
}

$CertCheck = if ($Insecure) { @{ SkipCertificateCheck = $true } } else { @{} }  # SkipCertificateCheck requires PS 7+; for older, may need workaround

# Build payload as LIST of operations (delete + set in one commit)
$Payload = @(
    @{op="delete"; path=@("qos","interface",$Link,"egress")},
    @{op="set"; path=@("qos","interface",$Link,"egress"); value=$Profile}
) | ConvertTo-Json -Compress

# === 1) /configure: apply changes (implicit commit) ===
$Uri = "$HostUrl/configure"
$Body = @{ data = $Payload; key = $ApiKey }
$Resp = Invoke-WebRequest -Uri $Uri -Method Post -Body $Body -ContentType 'multipart/form-data' @CertCheck

$Ok = if ($Resp.Content -match '"success":\s*true') { $true } else { $false }
if (-not $Ok) {
    Write-Error "Failure in /configure. Response: $($Resp.Content)"
    exit 1
}

# === 2) /config-file: save (optional) ===
if ($DoSave) {
    $UriSave = "$HostUrl/config-file"
    $BodySave = @{ data = '{"op":"save"}'; key = $ApiKey }
    $RespSave = Invoke-WebRequest -Uri $UriSave -Method Post -Body $BodySave -ContentType 'multipart/form-data' @CertCheck

    $OkSave = if ($RespSave.Content -match '"success":\s*true') { $true } else { $false }
    if (-not $OkSave) {
        Write-Error "Commit OK, but save failed. Response: $($RespSave.Content)"
        exit 1
    }
}

Write-Output "OK: QoS on $Link => egress '$Profile' applied$(if ($DoSave) { ' and saved' })."
