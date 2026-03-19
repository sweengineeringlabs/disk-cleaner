# TomlConfig.ps1 - Pure-PowerShell TOML parser (single-line values only)

class TomlConfig {
    [hashtable] $Data
    [string[]]  $Profiles

    TomlConfig([string]$filePath) {
        if (-not (Test-Path $filePath)) {
            throw "Config file not found: $filePath"
        }

        $this.Data = @{}
        $profileList = [System.Collections.ArrayList]::new()
        $currentSection = ""

        foreach ($rawLine in Get-Content $filePath) {
            $line = ($rawLine -replace '#.*$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match '^\[(.+)\]$') {
                $currentSection = $Matches[1]
                if ($currentSection -match '^profiles\.(.+)$') {
                    [void]$profileList.Add($Matches[1])
                }
                continue
            }

            if ($line -match '^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2].Trim()
                $this.Data["$currentSection.$key"] = $value
            }
        }

        $this.Profiles = @($profileList)
    }

    [string] GetValue([string]$key) {
        $raw = $this.Data[$key]
        if ($null -eq $raw) { return "" }
        if ($raw -match '^"(.*)"$') { return $Matches[1] }
        if ($raw -match "^'(.*)'$") { return $Matches[1] }
        return $raw
    }

    [string[]] GetArray([string]$key) {
        $raw = $this.Data[$key]
        if ($null -eq $raw) { return @() }

        $raw = $raw -replace '^\[', '' -replace '\]$', ''
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

        $items = $raw -split ','
        $result = @()
        foreach ($item in $items) {
            $item = $item.Trim().Trim('"').Trim("'")
            if ($item.Length -gt 0) {
                $result += $item
            }
        }
        return $result
    }
}
