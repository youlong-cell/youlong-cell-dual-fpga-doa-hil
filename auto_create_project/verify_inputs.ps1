param([Parameter(Mandatory=$true)][string]$LogDirectory)
$ErrorActionPreference = 'Stop'
try {
    # 仅进程内使用系统自带PowerShell；不修改全局执行策略或FPGA工程。
    $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $Catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'input_hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) { throw 'LOG_DIRECTORY_NOT_PREPARED' }
    $Prefix = $Root.TrimEnd('\') + '\'
    foreach ($Row in $Catalog.files) {
        $Path = [IO.Path]::GetFullPath((Join-Path $Root $Row.path))
        if (-not $Path.StartsWith($Prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'SOURCE_OUTSIDE_REPOSITORY' }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('SOURCE_MISSING: ' + $Row.path) }
        # 直接使用.NET，避免依赖调用者的PowerShell模块搜索路径。
        $Algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $Stream = [IO.File]::OpenRead($Path)
            try { $Actual = [BitConverter]::ToString($Algorithm.ComputeHash($Stream)).Replace('-','').ToLowerInvariant() }
            finally { $Stream.Dispose() }
        } finally { $Algorithm.Dispose() }
        if ($Actual -ne $Row.sha256) { throw ('SOURCE_HASH_MISMATCH: ' + $Row.path) }
    }
    $Count = @($Catalog.files).Count
    $Lines = @(('CATALOG=' + $Catalog.catalog_sha256), ('COUNT=' + $Count))
    [IO.File]::WriteAllLines((Join-Path $LogDirectory 'INPUTS_VERIFIED.txt'), [string[]]$Lines, (New-Object Text.UTF8Encoding($false)))
    Write-Output ('INPUT_HASHES_VERIFIED count=' + $Count)
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
