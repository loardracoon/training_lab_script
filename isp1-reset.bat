@echo off
setlocal enabledelayedexpansion

rem === Parametros estaticos (hardcoded conforme solicitado) ===
set HOST=https://10.100.100.1
set API_KEY=Sophos@1985
set INSECURE=-k
set LINK=eth1
set PROFILE=ISP1-DEFAULT
set DO_SAVE=1  rem 1 para salvar (equivalente a --save=true)

rem Validacoes minimas (mantidas para seguranca)
echo %LINK% | findstr /r "^[A-Za-z0-9./_-]*$" >nul || (echo ERRO: LINK invalido & exit /b 2)
echo %PROFILE% | findstr /r "^[A-Za-z0-9._-]*$" >nul || (echo ERRO: PROFILE invalido & exit /b 2)

rem Monta payload
set "PAYLOAD=[{\"op\":\"delete\",\"path\":[\"qos\",\"interface\",\"%LINK%\",\"egress\"]},{\"op\":\"set\",\"path\":[\"qos\",\"interface\",\"%LINK%\",\"egress\"],\"value\":\"%PROFILE%\"}]"

rem === 1) /configure: aplica mudancas ===
curl -sS -L %INSECURE% --request POST "%HOST%/configure" --form "data=%PAYLOAD%" --form "key=%API_KEY%" > response.txt
findstr /c:"\"success\": true" response.txt >nul
if errorlevel 1 (
    echo Falha no /configure. Resposta:
    type response.txt
    del response.txt
    exit /b 1
)
del response.txt

rem === 2) /config-file: salva (como DO_SAVE=1) ===
curl -sS -L %INSECURE% --request POST "%HOST%/config-file" --form "data={\"op\":\"save\"}" --form "key=%API_KEY%" > response2.txt
findstr /c:"\"success\": true" response2.txt >nul
if errorlevel 1 (
    echo Commit OK, mas save falhou. Resposta:
    type response2.txt
    del response2.txt
    exit /b 1
)
del response2.txt

echo OK: QoS em %LINK% =^> egress '%PROFILE%' aplicado e salvo.
exit /b 0
