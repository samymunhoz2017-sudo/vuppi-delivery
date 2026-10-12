$ErrorActionPreference = 'Stop'
$upProjectPath = Split-Path -Parent $PSScriptRoot
$upNodePath = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
if (-not (Test-Path -LiteralPath $upNodePath)) { $upNodePath = (Get-Command node -ErrorAction Stop).Source }
$upVaultPath = Join-Path $upProjectPath '.local\cofre.json'
function Read-UpPlainSecret($secureValue) {
 $upPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
 try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($upPointer) }
 finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($upPointer) }
}
if (-not (Test-Path -LiteralPath $upVaultPath)) {
 Write-Host 'Primeira inicializacao. As chaves ficam criptografadas para seu usuario Windows.'
 $upUrl = Read-Host 'URL do seu projeto Supabase (https://...supabase.co)'
 $upUri = [Uri]$upUrl
 if ($upUri.Scheme -ne 'https' -or -not $upUri.Host.EndsWith('.supabase.co')) { throw 'Informe uma URL HTTPS valida do Supabase.' }
 $upPublicKey = Read-Host 'Cole a chave publishable do Supabase (entrada oculta)' -AsSecureString
 $upSessionBytes = New-Object byte[] 32
 $upRandom = [Security.Cryptography.RandomNumberGenerator]::Create()
 $upRandom.GetBytes($upSessionBytes); $upRandom.Dispose()
 $upSessionProtected = ConvertTo-SecureString ([Convert]::ToBase64String($upSessionBytes)) -AsPlainText -Force
 $upVault = @{ SUPABASE_URL = $upUrl; SUPABASE_PUBLISHABLE_KEY = (ConvertFrom-SecureString $upPublicKey); UP_SESSION_KEY = (ConvertFrom-SecureString $upSessionProtected) }
 New-Item -ItemType Directory -Path (Split-Path -Parent $upVaultPath) -Force | Out-Null
 $upVault | ConvertTo-Json | Set-Content -LiteralPath $upVaultPath -Encoding UTF8
}
$upSavedVault = Get-Content -LiteralPath $upVaultPath -Raw | ConvertFrom-Json
$env:SUPABASE_URL = $upSavedVault.SUPABASE_URL
$env:SUPABASE_PUBLISHABLE_KEY = Read-UpPlainSecret (ConvertTo-SecureString $upSavedVault.SUPABASE_PUBLISHABLE_KEY)
$env:UP_SESSION_KEY = Read-UpPlainSecret (ConvertTo-SecureString $upSavedVault.UP_SESSION_KEY)
$env:UP_CITY_ID = 'pitangueiras-sp'
try {
 Set-Location -LiteralPath $upProjectPath
 & $upNodePath scripts/build.mjs
 if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar a plataforma.' }
 Write-Host 'Cadastro exige confirmacao de e-mail desativada no Supabase. Permissoes exigem as migracoes revisadas.'
 & $upNodePath scripts/local-server.mjs
} finally {
 Remove-Item Env:\SUPABASE_PUBLISHABLE_KEY -ErrorAction SilentlyContinue
 Remove-Item Env:\UP_SESSION_KEY -ErrorAction SilentlyContinue
}
