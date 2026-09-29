
param(
    [string]$EnvFile = ".env",
    [string]$KeyStoreFile = "android-release.jks",
    [string]$Alias = "release",
    [string]$DistinguishedName = "CN=Android Release, OU=Development, O=Personal, C=US",
    [int]$ValidityDays = 10000
)

$ErrorActionPreference = "Stop"

# Resolve paths relative to the current directory.
$EnvFile = [System.IO.Path]::GetFullPath($EnvFile)
$KeyStoreFile = [System.IO.Path]::GetFullPath($KeyStoreFile)

# Check prerequisites.
$keytool = Get-Command keytool -ErrorAction SilentlyContinue

if (-not $keytool) {
    throw "keytool was not found. Install a JDK and add its bin directory to PATH."
}

if (Test-Path -LiteralPath $KeyStoreFile) {
    throw "Keystore already exists: $KeyStoreFile. Refusing to overwrite an existing signing key."
}

# Prevent accidental replacement of existing credentials.
$secretNames = @(
    "ANDROID_KEY_STORE_BASE64",
    "ANDROID_KEY_STORE_PASSWORD",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEY_ALIAS"
)

if (Test-Path -LiteralPath $EnvFile) {
    $existing = Get-Content -LiteralPath $EnvFile -Raw

    foreach ($name in $secretNames) {
        if ($existing -match "(?m)^\s*$name\s*=") {
            throw "$name already exists in $EnvFile. Refusing to replace existing credentials."
        }
    }
}

# Generate a cryptographically secure random password.
function New-SecurePassword {
    param([int]$Length = 32)

    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    # Hexadecimal avoids shell and .env escaping issues.
    return [System.BitConverter]::ToString($bytes).Replace("-", "")
}

# PKCS12 uses the same password for the keystore and private key.
$password = New-SecurePassword

Write-Host "Generating Android release signing key..."

# Generate the signing key.
# Passwords are passed to keytool as process arguments.
# Avoid running this script on an untrusted machine.
& $keytool.Source `
    -genkeypair `
    -v `
    -keystore $KeyStoreFile `
    -storetype PKCS12 `
    -alias $Alias `
    -keyalg RSA `
    -keysize 4096 `
    -sigalg SHA256withRSA `
    -validity $ValidityDays `
    -dname $DistinguishedName `
    -storepass $password `
    -keypass $password

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $KeyStoreFile)) {
    throw "Failed to generate Android signing keystore."
}

# Encode the complete keystore as Base64.
$keystoreBytes = [System.IO.File]::ReadAllBytes($KeyStoreFile)
$keystoreBase64 = [Convert]::ToBase64String($keystoreBytes)

# Prepare environment variables.
$envContent = @(
    ""
    "# Android release signing"
    "ANDROID_KEY_STORE_BASE64=$keystoreBase64"
    "ANDROID_KEY_STORE_PASSWORD=$password"
    "ANDROID_KEY_PASSWORD=$password"
    "ANDROID_KEY_ALIAS=$Alias"
) -join "`n"

# Write using UTF-8 without BOM.
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (Test-Path -LiteralPath $EnvFile) {
    $existing = [System.IO.File]::ReadAllText($EnvFile)

    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) {
        $envContent = "`n" + $envContent
    }

    [System.IO.File]::AppendAllText(
        $EnvFile,
        $envContent + "`n",
        $utf8
    )
}
else {
    [System.IO.File]::WriteAllText(
        $EnvFile,
        $envContent.TrimStart() + "`n",
        $utf8
    )
}

Write-Host ""
Write-Host "Android signing key generated successfully!" -ForegroundColor Green
Write-Host "Keystore: $KeyStoreFile"
Write-Host "Environment file: $EnvFile"
Write-Host "Key alias: $Alias"
Write-Host ""
Write-Host "Back up the keystore and credentials securely."
Write-Host "Do not commit either file to Git."
