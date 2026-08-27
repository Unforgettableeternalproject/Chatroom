# 一鍵測試：使用專案自帶 .venv（絕不使用 U.E.P Core 環境）
# 用法：pwsh scripts/test.ps1 [-Coverage]
param([switch]$Coverage)

$repo = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    Write-Error "找不到 $python — 請先執行：py -3.12 -m venv .venv; .venv\Scripts\python.exe -m pip install -r requirements.txt"
    exit 1
}

$args = @("-m", "pytest", "tests/", "-q")
if ($Coverage) {
    $args += @("--cov=server/chatroom_server", "--cov-report=term-missing", "--cov-fail-under=85")
}
& $python @args
exit $LASTEXITCODE
