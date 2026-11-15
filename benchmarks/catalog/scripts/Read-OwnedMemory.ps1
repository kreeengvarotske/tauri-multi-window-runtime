# Diagnostic Private Bytes reader. It does not change the frozen benchmark
# protocol. Callers must reject Unavailable rows rather than accept their zero.
function Read-OwnedMemory {
    param($Job,[int]$ProcessId,[scriptblock]$OpenProcess={param($id) [Diagnostics.Process]::GetProcessById($id)})
    $process=$null
    try {
        try {$process=& $OpenProcess $ProcessId}
        catch [ArgumentException] {
            return [pscustomobject]@{Status='ExitedBeforeOpen';PrivateBytes=0L;CreatedTicks=$null;Error=$_.Exception.Message}
        }
        # Pin the process object before querying by PID, so a recycled PID
        # cannot redirect the subsequent memory read to another process.
        $handle=$process.Handle
        if($null -eq $handle -or $handle -eq [IntPtr]::Zero){throw 'Process handle was unavailable'}
        $exited=$process.HasExited
        if($null -eq $exited){throw 'Process exit state was unavailable'}
        if($exited){return [pscustomobject]@{Status='ExitedAfterOpen';PrivateBytes=0L;CreatedTicks=$null;Error=$null}}
        if(-not $Job.Contains($handle)){return [pscustomobject]@{Status='Unavailable';PrivateBytes=0L;CreatedTicks=$null;Error='Process is no longer a member of the owned job'}}
        $created=$process.StartTime.ToUniversalTime().Ticks
        $bytes=$process.PrivateMemorySize64
        # PowerShell can return null for a failing property getter rather than
        # enter catch. Never cast an unread live-process value to a valid zero.
        $exited=$process.HasExited
        if($null -eq $exited){throw 'Process exit state was unavailable'}
        if($exited){return [pscustomobject]@{Status='ExitedDuringRead';PrivateBytes=0L;CreatedTicks=$created;Error=$null}}
        if($null -eq $bytes){throw 'Private Bytes query returned no value'}
        if($bytes -lt 0){throw 'Private Bytes query returned a negative value'}
        return [pscustomobject]@{Status='Read';PrivateBytes=[long]$bytes;CreatedTicks=$created;Error=$null}
    } catch {
        $reason=$_.Exception.Message
        if($process){
            try {
                if($process.HasExited){return [pscustomobject]@{Status='ExitedDuringRead';PrivateBytes=0L;CreatedTicks=$null;Error=$reason}}
            } catch {}
        }
        return [pscustomobject]@{Status='Unavailable';PrivateBytes=0L;CreatedTicks=$null;Error=$reason}
    } finally {if($process){$process.Dispose()}}
}
