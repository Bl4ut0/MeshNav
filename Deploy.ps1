# Deploy.ps1
# Script to bump version numbers and deploy MeshNav to your local WoW client.
# Run with: Set-ExecutionPolicy RemoteSigned -Scope Process
# Usage: 
#   .\Deploy.ps1 -Bump patch
#   .\Deploy.ps1 -Bump minor
#   .\Deploy.ps1 -Bump major

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("major", "minor", "patch", "none")]
    [string]$Bump = "none",
    
    [Parameter(Mandatory=$false)]
    [string]$WoWPath = $null
)

$AddonName = "MeshNav"
$ConfigFile = Join-Path $PSScriptRoot "DeployConfig.json"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         MeshNav Local Deploy Tool                " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Resolve WoW Path
if (-not $WoWPath) {
    if (Test-Path $ConfigFile) {
        $config = Get-Content $ConfigFile | ConvertFrom-Json
        $WoWPath = $config.WoWPath
    }
}

if (-not $WoWPath -or -not (Test-Path $WoWPath)) {
    Write-Host "WoW AddOns path not configured or not found." -ForegroundColor Yellow
    
    # Try common default paths
    $defaultPaths = @(
        "C:\Program Files (x86)\World of Warcraft\_classic_\Interface\AddOns",
        "C:\Program Files\World of Warcraft\_classic_\Interface\AddOns",
        "D:\Games\World of Warcraft\_classic_\Interface\AddOns",
        "D:\World of Warcraft\_classic_\Interface\AddOns"
    )
    
    foreach ($dp in $defaultPaths) {
        if (Test-Path $dp) {
            $WoWPath = $dp
            break
        }
    }
    
    if (-not $WoWPath) {
        $WoWPath = Read-Host "Please enter your WoW AddOns directory path (e.g. C:\WoW\_classic_\Interface\AddOns)"
    }
    
    if (Test-Path $WoWPath) {
        $config = @{ WoWPath = $WoWPath }
        $config | ConvertTo-Json | Out-File $ConfigFile
        Write-Host "Saved WoW path config to: $ConfigFile" -ForegroundColor Green
    } else {
        Write-Host "[Error] Invalid WoW path. Deployment aborted." -ForegroundColor Red
        return
    }
}

Write-Host "Target Client AddOns folder: $WoWPath" -ForegroundColor Green

# 2. Version Bump Logic
$TOCFile = Join-Path $PSScriptRoot "MeshNav.toc"
$LuaFile = Join-Path $PSScriptRoot "MeshNav.lua"
$BindingsFile = Join-Path $PSScriptRoot "Bindings.xml"

if ($Bump -ne "none") {
    Write-Host "Bumping version ($Bump)..." -ForegroundColor Yellow
    
    $tocContent = Get-Content $TOCFile -Raw
    if ($tocContent -match '## Version:\s*(\d+)\.(\d+)\.(\d+)') {
        [int]$major = $Matches[1]
        [int]$minor = $Matches[2]
        [int]$patch = $Matches[3]
        
        $oldVer = "$major.$minor.$patch"
        
        if ($Bump -eq "major") {
            $major++
            $minor = 0
            $patch = 0
        } elseif ($Bump -eq "minor") {
            $minor++
            $patch = 0
        } elseif ($Bump -eq "patch") {
            $patch++
        }
        
        $newVer = "$major.$minor.$patch"
        Write-Host "Version bumped from $oldVer to $newVer" -ForegroundColor Green
        
        # Update TOC
        $tocContent = $tocContent -replace '## Version:\s*\d+\.\d+\.\d+', "## Version: $newVer"
        $tocContent | Out-File $TOCFile -Encoding utf8
        
        # Update Lua DB Version code
        # Format: local DB_VERSION = 10000 -- (Major * 10000 + Minor * 100 + Patch)
        $newDbCode = ($major * 10000) + ($minor * 100) + $patch
        $luaContent = Get-Content $LuaFile -Raw
        if ($luaContent -match 'local DB_VERSION = \d+') {
            $luaContent = $luaContent -replace 'local DB_VERSION = \d+', "local DB_VERSION = $newDbCode"
            $luaContent | Out-File $LuaFile -Encoding utf8
            Write-Host "Updated Lua DB_VERSION constant to $newDbCode" -ForegroundColor Green
        }
    } else {
        Write-Host "[Warning] Could not parse version in TOC file. Skipping version bump." -ForegroundColor Yellow
    }
}

# 3. Copy files to WoW Addons Directory
$DestFolder = Join-Path $WoWPath "MeshNav"

if (-not (Test-Path $DestFolder)) {
    Write-Host "Creating local WoW Addon directory: $DestFolder" -ForegroundColor Gray
    New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
}

Write-Host "Deploying files to local WoW client..." -ForegroundColor Yellow

# Copy only the necessary client addon files
$FilesToCopy = @($TOCFile, $LuaFile, $BindingsFile)
foreach ($file in $FilesToCopy) {
    if (Test-Path $file) {
        $destFile = Join-Path $DestFolder (Split-Path $file -Leaf)
        Copy-Item -Path $file -Destination $destFile -Force
    }
}

Write-Host "Deployment Completed Successfully!" -ForegroundColor Green
Write-Host "In WoW, type '/reload' to load the new version." -ForegroundColor Gray

