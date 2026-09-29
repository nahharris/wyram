param(
  [string]$Json = '{"op":"status"}',
  [string]$RequestFile,
  [string]$DataDir
)
$ErrorActionPreference = 'Stop'

if (-not $DataDir) {
  $DataDir = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
}
$endpoint = Get-Content -LiteralPath (Join-Path $DataDir 'control.json') -Raw | ConvertFrom-Json
$requestText = if ($RequestFile) { Get-Content -LiteralPath $RequestFile -Raw } else { $Json }
$request = ConvertFrom-Json -InputObject $requestText
if ($request -isnot [pscustomobject]) { throw 'Control request must be a JSON object' }
$request | Add-Member -NotePropertyName token -NotePropertyValue $endpoint.token -Force

$tcp = [System.Net.Sockets.TcpClient]::new()
try {
  $tcp.Connect('127.0.0.1', [int]$endpoint.port)
  $tcp.ReceiveTimeout = 5000
  $tcp.SendTimeout = 5000
  $stream = $tcp.GetStream()
  $encoding = [System.Text.UTF8Encoding]::new($false)
  $writer = [System.IO.StreamWriter]::new($stream, $encoding)
  $reader = [System.IO.StreamReader]::new($stream, $encoding)
  $writer.AutoFlush = $true
  $writer.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
  $line = $reader.ReadLine()
  if (-not $line) { throw 'Control server returned no response' }
  Write-Output $line
  if (-not (ConvertFrom-Json -InputObject $line).ok) { exit 1 }
} finally {
  $tcp.Dispose()
}
