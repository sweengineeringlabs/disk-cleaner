# Spinner.ps1 - Animated text spinner for long-running operations

class Spinner {
    hidden [powershell] $PS
    hidden [runspace]   $Runspace
    [bool] $Suppressed

    Spinner([bool]$suppressed) {
        $this.Suppressed = $suppressed
    }

    [void] Start([string]$message) {
        if ($this.Suppressed) { return }

        $this.Runspace = [runspacefactory]::CreateRunspace()
        $this.Runspace.Open()

        $this.PS = [powershell]::Create()
        $this.PS.Runspace = $this.Runspace
        [void]$this.PS.AddScript({
            param($msg)
            $chars = @('|', '/', '-', '\')
            $i = 0
            try {
                while ($true) {
                    $c = $chars[$i % 4]
                    [Console]::Write("`r  $c $msg  ")
                    $i++
                    Start-Sleep -Milliseconds 120
                }
            } catch {}
        })
        [void]$this.PS.AddArgument($message)
        [void]$this.PS.BeginInvoke()
    }

    [void] Stop() {
        if ($this.PS) {
            try { $this.PS.Stop() } catch {}
            try { $this.PS.Dispose() } catch {}
            $this.PS = $null
        }
        if ($this.Runspace) {
            try { $this.Runspace.Close() } catch {}
            try { $this.Runspace.Dispose() } catch {}
            $this.Runspace = $null
        }
        if (-not $this.Suppressed) {
            [Console]::Write("`r" + (" " * 80) + "`r")
        }
    }
}
