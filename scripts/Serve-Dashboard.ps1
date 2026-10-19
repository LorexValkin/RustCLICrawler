[CmdletBinding()]
param([int]$Port = 8765)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Choose an unprivileged port between 1024 and 65535' }
Import-Module (Join-Path $PSScriptRoot 'Dashboard.psm1') -Force -DisableNameChecking
$root = Split-Path -Parent $PSScriptRoot
$config = Read-JsonFile (Join-Path $root 'scout.config.json')
$dataRoot = [IO.Path]::GetFullPath((Join-Path $root $config.outputDirectory))
$web = Join-Path $root 'dashboard'
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$allowedOrigins = @("http://localhost:$Port", "http://127.0.0.1:$Port")
$static = @{ '/' = @('index.html', 'text/html; charset=utf-8'); '/app.js' = @('app.js', 'text/javascript; charset=utf-8'); '/style.css' = @('style.css', 'text/css; charset=utf-8'); '/review.css' = @('review.css', 'text/css; charset=utf-8'); '/api/v1/openapi.json' = @('openapi.json', 'application/json; charset=utf-8') }
try {
    $listener.Start()
    Write-Output "Repo Scout dashboard: http://localhost:$Port"
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $response.Headers['X-Content-Type-Options'] = 'nosniff'
            $response.Headers['Referrer-Policy'] = 'no-referrer'
            $response.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
            $response.Headers['Cache-Control'] = 'no-store'
            if (-not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address) -or $request.Url.Host -notin @('localhost', '127.0.0.1')) {
                $result = New-ApiResult @{error = @{code = 'forbidden'; message = 'Loopback access only'}} 403
            } elseif ($request.Headers['Origin'] -and $request.Headers['Origin'] -notin $allowedOrigins) {
                $result = New-ApiResult @{error = @{code = 'forbidden'; message = 'Cross-origin requests are disabled'}} 403
            } elseif ($request.HttpMethod -notin @('GET', 'HEAD')) {
                $response.Headers['Allow'] = 'GET, HEAD'
                $result = New-ApiResult @{error = @{code = 'method_not_allowed'; message = 'This API is read-only'}} 405
            } elseif ($static.ContainsKey($request.Url.AbsolutePath)) {
                $file = $static[$request.Url.AbsolutePath]
                $result = New-ApiResult ([IO.File]::ReadAllText((Join-Path $web $file[0]), [Text.Encoding]::UTF8)) 200 $file[1]
            } elseif ($request.Url.AbsolutePath.StartsWith('/api/v1/')) {
                $result = Invoke-DashboardApi $dataRoot $request.Url.AbsolutePath $request.QueryString
            } else { $result = New-ApiResult @{error = @{code = 'not_found'; message = 'Route not found'}} 404 }
            $response.StatusCode = $result.status
            $response.ContentType = $result.content_type
            if ($result.filename) { $response.Headers['Content-Disposition'] = 'attachment; filename="' + $result.filename + '"' }
            $text = if ($result.body -is [string]) { $result.body } else { ConvertTo-Json -InputObject $result.body -Depth 24 -Compress }
        } catch {
            $response.StatusCode = if ($_.Exception -is [ArgumentException]) { 400 } elseif ($_.Exception -is [IO.FileNotFoundException]) { 404 } else { 500 }
            $response.ContentType = 'application/json; charset=utf-8'
            $message = if ($response.StatusCode -eq 500) { 'Unable to read research data. Check the server log.' } else { $_.Exception.Message }
            $text = @{error = @{code = "http_$($response.StatusCode)"; message = $message}} | ConvertTo-Json -Compress
            Write-Warning $_.Exception.Message
        }
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $response.ContentLength64 = $bytes.Length
            if ($request.HttpMethod -ne 'HEAD') { $response.OutputStream.Write($bytes, 0, $bytes.Length) }
        } catch { Write-Warning 'Client disconnected before the response completed.' }
        finally { $response.Close() }
    }
} finally { $listener.Close() }
