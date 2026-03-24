# OutputWriter.ps1 - Text/JSON output abstraction

class OutputWriter {
    [bool] $JsonMode

    OutputWriter([bool]$jsonMode) {
        $this.JsonMode = $jsonMode
    }

    [void] Text([string]$message, [string]$color) {
        if ($this.JsonMode) { return }
        Write-Host $message -ForegroundColor $color
    }

    [void] TextNoNewline([string]$message, [string]$color) {
        if ($this.JsonMode) { return }
        Write-Host $message -ForegroundColor $color -NoNewline
    }

    [void] PlainText([string]$message) {
        if ($this.JsonMode) { return }
        Write-Host $message
    }

    [void] BlankLine() {
        if ($this.JsonMode) { return }
        Write-Host ""
    }

    [void] Json([hashtable]$event) {
        if (-not $this.JsonMode) { return }
        $event["timestamp"] = (Get-Date -Format "o")
        $json = $event | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($json)
    }
}
