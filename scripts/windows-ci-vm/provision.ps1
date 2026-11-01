# Install what the CI Windows jobs need, then register this VM as the self-hosted runner `elarni-windows`.
# Run elevated over SSH (see README.md): provision.ps1 -Token <registration token> -Password <the elarni user's password>
# Each step skips what is already installed, so a rerun resumes after a failure.
param([Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$Password)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$downloads = 'C:\ci-downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null

function Get-Verified($url, $sha256) {
    $file = Join-Path $downloads ([IO.Path]::GetFileName($url))
    if (-not (Test-Path $file)) { Invoke-WebRequest $url -OutFile $file }
    if ($sha256 -and (Get-FileHash $file -Algorithm SHA256).Hash -ne $sha256) { Remove-Item $file; throw "$url does not match its published SHA-256" }
    $file
}
function Add-MachinePath($directory) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $directory) { [Environment]::SetEnvironmentVariable('Path', "$path;$directory", 'Machine') }
}

# Flutter's Windows build and the repo's deep build trees need long paths. CI writes heavily, so Defender skips
# the runner and the toolchains and caches (mise's Flutter alone is 1.9 GB): scanning made `flutter pub get` take 2 minutes.
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1
Add-MpPreference -ExclusionPath C:\actions-runner, $downloads, "$env:LOCALAPPDATA\mise", "$env:LOCALAPPDATA\Pub",
    "$env:LOCALAPPDATA\go-build", "$env:USERPROFILE\go", "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup",
    "$env:USERPROFILE\.dotnet", "$env:TEMP"

if (-not (Test-Path 'C:\Program Files\Git\bin\bash.exe')) {
    $git = Get-Verified 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/Git-2.56.0.4-64-bit.exe' '4961A4A8CC778D8B6E00A5819E5FE4D078B754555AFF7AEDC2D77A5D74C2DE80'
    Start-Process $git -Wait -ArgumentList '/VERYSILENT', '/NORESTART', '/SP-', '/o:PathOption=Cmd'
}
# `shell: bash` steps resolve bash from PATH, as on the hosted image; mise-action needs unzip from usr\bin,
# which comes last so Windows' own find and sort keep precedence.
Add-MachinePath 'C:\Program Files\Git\bin'
Add-MachinePath 'C:\Program Files\Git\usr\bin'
& 'C:\Program Files\Git\cmd\git.exe' config --system core.longpaths true

if (-not (Test-Path 'C:\Program Files\Python313\python.exe')) {
    $python = Get-Verified 'https://www.python.org/ftp/python/3.13.17/python-3.13.17-amd64.exe' '5DA012101BA2E17113A9A1CD901E9CE1441086F2B7ECB5DE06EC94163899A190'
    Start-Process $python -Wait -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_launcher=1'
}

# Visual Studio Build Tools with the C++ workload (MSVC, Windows SDK, CMake) for Flutter, Rust and the routing checks.
$vs = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
if (-not (Test-Path "$vs\VC\Tools\MSVC")) {
    $installer = Get-Verified 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $null
    $process = Start-Process $installer -Wait -PassThru -ArgumentList '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended'
    if ($process.ExitCode -notin 0, 3010) { throw "Build Tools exited $($process.ExitCode)" }
}
Add-MachinePath "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"

# WiX installs as a dotnet tool in the workflow.
if (-not (Test-Path 'C:\Program Files\dotnet\dotnet.exe')) {
    $script = Get-Verified 'https://dot.net/v1/dotnet-install.ps1' $null
    & $script -Channel 8.0 -InstallDir 'C:\Program Files\dotnet'
}
Add-MachinePath 'C:\Program Files\dotnet'

if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) {
    $rustup = Get-Verified 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' $null
    & $rustup -y --default-toolchain none --profile minimal
}

if (-not (Test-Path C:\actions-runner\.runner)) {
    $runner = Get-Verified 'https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-win-x64-2.338.2.zip' 'A1F17AA987FC8158BC7521D284912267A0D01B7C2C4684B33C86783B5E8221CC'
    Expand-Archive $runner C:\actions-runner -Force
    # The service reads PATH from the registry; this session's copy predates the installers.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    # As the elarni administrator, so steps get its profile (rustup, caches) and can create symlinks.
    & C:\actions-runner\config.cmd --unattended --url https://github.com/Shilmoon/elarni --token $Token `
        --name elarni-windows-vm --labels elarni-windows --runasservice --windowslogonaccount '.\elarni' --windowslogonpassword $Password
    if ($LASTEXITCODE) { throw "Runner registration exited $LASTEXITCODE" }
}
'Provisioned; the runner service is ' + (Get-Service 'actions.runner.*').Status
