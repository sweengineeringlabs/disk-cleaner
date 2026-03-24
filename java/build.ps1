<#
.SYNOPSIS
    Build disk-cleaner Java implementation using justc.
.PARAMETER JustcPath
    Path to justc compiler. Defaults to justc on PATH.
#>
param(
    [string]$JustcPath = "justc"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Building disk-cleaner (Java/justc)..." -ForegroundColor Cyan

& $JustcPath build (Join-Path $ScriptDir "src\DiskCleaner.java") -o (Join-Path $ScriptDir "disk-cleaner")

if ($LASTEXITCODE -eq 0) {
    Write-Host "Build complete: disk-cleaner" -ForegroundColor Green
} else {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}
