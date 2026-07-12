# Mock mpv IPC server — see mpv.bat. Serves \\.\pipe\240mp-mpv, logs every
# command the app sends, streams time-pos updates for ~8 s, then reports a
# natural end-of-file and exits 0 (mpv's success code).
$log = "$env:TEMP\mock-mpv.log"
"[$(Get-Date -Format HH:mm:ss.fff)] launched: $($args -join ' ')" | Add-Content $log

$pipe = New-Object System.IO.Pipes.NamedPipeServerStream('240mp-mpv', 'InOut', 1, 'Byte', 'None')
$pipe.WaitForConnection()
"[$(Get-Date -Format HH:mm:ss.fff)] client connected" | Add-Content $log

$reader = New-Object System.IO.StreamReader($pipe)
$writer = New-Object System.IO.StreamWriter($pipe)
$writer.AutoFlush = $true

# The app sends exactly four observe_property commands on connect.
for ($i = 0; $i -lt 4; $i++) {
    $cmd = $reader.ReadLine()
    "[recv] $cmd" | Add-Content $log
}

$writer.WriteLine('{"event":"property-change","id":4,"name":"pause","data":false}')
$writer.WriteLine('{"event":"property-change","id":2,"name":"duration","data":30.0}')
$writer.WriteLine('{"event":"property-change","id":3,"name":"playlist-pos","data":0}')
for ($t = 0; $t -le 16; $t++) {
    $writer.WriteLine('{"event":"property-change","id":1,"name":"time-pos","data":' + ($t * 0.5) + '}')
    Start-Sleep -Milliseconds 500
}
$writer.WriteLine('{"event":"end-file","reason":"eof"}')
"[$(Get-Date -Format HH:mm:ss.fff)] sent eof, exiting 0" | Add-Content $log
Start-Sleep -Milliseconds 300
$pipe.Dispose()
exit 0
