param([switch]$Native)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Read-OwnedMemory.ps1"
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function ProcessFixture {
    $p=[pscustomobject]@{Exited=$false;Disposed=$false;DenyHandle=$false;FailRead=$false;ExitOnRead=$false;PrivateReads=0;StartTime=[datetime]'2026-11-14T00:00:00Z'}
    $p | Add-Member ScriptProperty Handle {if($this.DenyHandle){throw [ComponentModel.Win32Exception]::new(5)};[IntPtr]1}
    $p | Add-Member ScriptProperty HasExited {$this.Exited}
    $p | Add-Member ScriptProperty PrivateMemorySize64 {$this.PrivateReads++;if($this.ExitOnRead){$this.Exited=$true;throw [InvalidOperationException]::new('Exited during query')};if($this.FailRead){throw [ComponentModel.Win32Exception]::new(5)};123456L}
    $p | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    return $p
}
$job=[pscustomobject]@{InJob=$true};$job | Add-Member ScriptMethod Contains {param($handle) $this.InJob}
$fixture=ProcessFixture
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Read' -and $r.PrivateBytes -eq 123456 -and $fixture.Disposed) 'Live owned process read/disposal failed'
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {throw [ArgumentException]::new('PID no longer exists')}
Assert ($r.Status -eq 'ExitedBeforeOpen' -and $r.PrivateBytes -eq 0) 'Exited before opening was not classified'
$fixture=ProcessFixture;$fixture.Exited=$true
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'ExitedAfterOpen' -and $fixture.PrivateReads -eq 0 -and $fixture.Disposed) 'Exited process was read'
$fixture=ProcessFixture;$fixture.ExitOnRead=$true
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'ExitedDuringRead' -and $fixture.Disposed) 'Exit during memory query was not classified'
$fixture=ProcessFixture;$fixture.FailRead=$true
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.Disposed) 'Live access failure was incorrectly accepted'
$fixture=ProcessFixture;$fixture.DenyHandle=$true
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.PrivateReads -eq 0 -and $fixture.Disposed) 'Handle access failure was incorrectly accepted'
$fixture=ProcessFixture;$job.InJob=$false
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.PrivateReads -eq 0 -and $fixture.Disposed) 'Foreign/recycled PID memory was read'
$fixture=ProcessFixture;$job.InJob=$true
$fixture | Add-Member ScriptProperty HasExited {throw [ComponentModel.Win32Exception]::new(5)} -Force
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.PrivateReads -eq 0 -and $fixture.Disposed) 'Unknown exit state was incorrectly accepted'
$fixture=ProcessFixture
$fixture | Add-Member ScriptProperty PrivateMemorySize64 {-1L} -Force
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.Disposed) 'Negative Private Bytes was incorrectly accepted'
$fixture=ProcessFixture
$fixture | Add-Member NoteProperty ExitChecks 0
$fixture | Add-Member ScriptProperty HasExited {$this.ExitChecks++;if($this.ExitChecks -gt 1){throw [ComponentModel.Win32Exception]::new(5)};$false} -Force
$r=Read-OwnedMemory -Job $job -ProcessId 1 -OpenProcess {$fixture}
Assert ($r.Status -eq 'Unavailable' -and $fixture.PrivateReads -eq 1 -and $fixture.Disposed) 'Unknown final exit state was incorrectly accepted'
'OWNED_MEMORY_CASES_PASSED=10'
if($Native) {
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native reader checks require Windows'}
    . "$PSScriptRoot/CatalogJobCpu.ps1"
    $job=New-CatalogJob
    $app=$null
    $held=$null
    try {
        $shell=(Get-Process -Id $PID).Path
        $app=Start-CatalogJobProcess -Job $job -CommandLine ('"{0}" -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 1500"' -f $shell) -WorkingDirectory $PSScriptRoot
        $held=[Diagnostics.Process]::GetProcessById($app.ProcessId)
        $null=$held.Handle
        $r=Read-OwnedMemory -Job $job -ProcessId $app.ProcessId
        Assert ($r.Status -eq 'Read' -and $r.PrivateBytes -ge 0 -and $r.CreatedTicks -gt 0) 'Native owned process query failed'
        $r=Read-OwnedMemory -Job $job -ProcessId $PID
        Assert ($r.Status -eq 'Unavailable') 'Native foreign process was accepted'
        Assert ([TmwrCatalogJob]::WaitExit($app.Process,5000)) 'Native fixture did not finish'
        $r=Read-OwnedMemory -Job $job -ProcessId $app.ProcessId -OpenProcess {$held}
        $held=$null # Read-OwnedMemory disposed the held Process object.
        Assert ($r.Status -eq 'ExitedAfterOpen') 'Native exited pinned process was not classified'
        Assert ($job.Accounting()[3] -eq 0) 'Native fixture job retained processes'
        'OWNED_MEMORY_NATIVE_CASES_PASSED=3'
    } finally {
        if($held){$held.Dispose()}
        if($app){[TmwrCatalogJob]::Close($app.Process)}
        $job.Dispose() # Kill-on-close covers a failed fixture, never foreign PIDs.
    }
}
