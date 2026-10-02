[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'AppSandbox-fork-release'))

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = (& $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
if (-not $vs) { throw 'Visual Studio 2022 with C++ tools and Windows SDK is required' }
$msbuild = Join-Path $vs 'MSBuild\Current\Bin\amd64\MSBuild.exe'

foreach ($project in @('AppSandboxCore.vcxproj', 'AppSandbox.vcxproj')) {
    & $msbuild (Join-Path $repo $project) /p:Configuration=Release /p:Platform=x64 "/p:SolutionDir=$repo\" /p:PostBuildEventUseInBuild=false /m /v:minimal /nologo
    if ($LASTEXITCODE) { throw "Build failed: $project" }
}

# Keep upstream's signed drivers and runtime resources byte-for-byte.
$upstream = 'https://github.com/jamesstringer90/appsandbox/releases/download/v0.1.9/AppSandbox-0.1.9-win-x64.zip'
$digest = 'CA300D13789D75E1EC33363AE484E3E310EBEBEE6FE030150F2D631AD934D12E'
[xml]$props = Get-Content -LiteralPath (Join-Path $repo 'Directory.Build.props') -Raw
$version = $props.Project.PropertyGroup | Where-Object AsbVersionMajor
$name = 'AppSandbox-{0}.{1}.{2}.{3}-win-x64.zip' -f $version.AsbVersionMajor, $version.AsbVersionMinor, $version.AsbVersionPatch, $version.AsbVersionRevision
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory $name
if (Test-Path -LiteralPath $output) { throw "Output already exists: $output" }
Invoke-WebRequest -Uri $upstream -OutFile $output
if ((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -ne $digest) {
    Remove-Item -LiteralPath $output
    throw 'Upstream ZIP checksum mismatch'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($output, [IO.Compression.ZipArchiveMode]::Update)
$files = [ordered]@{
    'AppSandbox.exe' = 'bin\Release\AppSandbox.exe'
    'appsandbox_core.dll' = 'bin\Release\appsandbox_core.dll'
    'headless-api/asb.py' = 'tools\headless-api\asb.py'
    'headless-api/README.md' = 'tools\headless-api\README.md'
    'LICENSE' = 'LICENSE'
}
try {
    foreach ($file in $files.GetEnumerator()) {
        $old = $zip.GetEntry($file.Key)
        if ($old) { $old.Delete() }
        $entry = $zip.CreateEntry($file.Key, [IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead((Join-Path $repo $file.Value))
        $stream = $entry.Open()
        try { $input.CopyTo($stream) }
        finally { $stream.Dispose(); $input.Dispose() }
    }
} finally {
    $zip.Dispose()
}
Write-Output $output
Get-FileHash -LiteralPath $output -Algorithm SHA256
