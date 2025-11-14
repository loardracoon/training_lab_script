<#
.SYNOPSIS
  Script PowerShell para aplicar QoS via API do VyOS (porta WAN) — equivalente ao wanem_update.sh
.DESCRIPTION
  Faz POST na API HTTPS do VyOS para aplicar perfil de QoS a uma interface e opcionalmente salvar configuração.
.PARAMETER Link
  Interface/link que receberá o perfil.
.PARAMETER Profile
  Nome do perfil de QoS.
.PARAMETER Save
  Switch para indicar que a configuração deve ser salva.
.PARAMETER Host
  Host (URL completo) da API do VyOS.
.PARAMETER ApiKey
  API-Key para autenticação.
.PARAMETER Insecure
  Se definido, ignora validação de certificado TLS (como “-k” no curl).
#>

param(
    [Parameter(Mandatory=$true)][string]$Link,
    [Parameter(Mandatory=$true)][string]$Profile,
    [switch]$Save,
    [string]$Host   = "https://10.100.100.1",
    [string]$ApiKey = $env:VYOS_API_KEY ? $env:VYOS_API_KEY : "MY-HTTPS-API-PLAINTEXT-KEY",
    [switch]$NoInsecure
)

# Ajuste do SSL/TLS se for ignorar verificação
if (-not $NoInsecure) {
    # Ignorar warnings de certificado — **uso somente se você entende o risco**
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback = delegate (
            object s, X509Certificate certificate,
            X509Chain chain, SslPolicyErrors sslPolicyErrors) {
                return true;
        };
    }
}
"@
    [TrustAll]::Enable()
}

# Validações simples (reduz risco de injeção)
if ($Link -notmatch '^[A-Za-z0-9./_-]+$') {
    Write-Error "ERRO: --link inválido"
    exit 2
}
if ($Profile -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "ERRO: --profile inválido"
    exit 2
}

# Preparar payload
# No script original era algo como: delete + set em um único commit (embutido em JSON)
# Aqui vamos montar manualmente.
$payload = @(
    @{
        op   = "delete"
        path = @("qos","egress",$Link)
    },
    @{
        op   = "set"
        path = @("qos","egress",$Link,"profile",$Profile)
    }
) | ConvertTo-Json

# Enviar requisição para endpoint /configure (ou similar) da API do VyOS
$uri = "$Host/configure"
$body = @{
    key  = $ApiKey
    data = $payload
} # serialização será automática

try {
    $response = Invoke-WebRequest -Uri $uri -Method Post -Body $body -UseBasicParsing
    $json = $response.Content | ConvertFrom-Json
    if (-not $json.success) {
        Write-Error "Falha na aplicação do perfil: $($response.Content)"
        exit 1
    }
} catch {
    Write-Error "Erro na requisição: $_"
    exit 1
}

# Se solicitado salvar
if ($Save) {
    $uri2 = "$Host/config-file"
    $body2 = @{
        key  = $ApiKey
        data = @{ op = "save" }
    }
    try {
        $response2 = Invoke-WebRequest -Uri $uri2 -Method Post -Body $body2 -UseBasicParsing
        $json2 = $response2.Content | ConvertFrom-Json
        if (-not $json2.success) {
            Write-Error "Commit OK, mas save falhou. Resposta: $($response2.Content)"
            exit 1
        }
    } catch {
        Write-Error "Erro ao salvar configuração: $_"
        exit 1
    }
}

Write-Output "OK: QoS em $Link => egress '$Profile' aplicado$(if ($Save) { ' e salvo' })"
