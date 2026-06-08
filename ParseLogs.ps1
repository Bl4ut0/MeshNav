# ParseLogs.ps1
# Script to parse WoW MeshNav saved variables log history.
# Execute with: Set-ExecutionPolicy RemoteSigned -Scope Process

param (
    [string]$SavedVarsPath = $null
)

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "           MeshNav Log Parser Script              " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Attempt to auto-locate WoW SavedVariables if path is not provided
if (-not $SavedVarsPath) {
    Write-Host "No path specified. Attempting to auto-locate World of Warcraft directory..." -ForegroundColor Yellow
    
    $commonPaths = @(
        "C:\Program Files (x86)\World of Warcraft\_classic_\WTF\Account",
        "C:\Program Files\World of Warcraft\_classic_\WTF\Account",
        "D:\Games\World of Warcraft\_classic_\WTF\Account",
        "D:\World of Warcraft\_classic_\WTF\Account"
    )
    
    $foundFiles = @()
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            Write-Host "Searching inside WTF directory: $path" -ForegroundColor Gray
            $files = Get-ChildItem -Path $path -Filter "MeshNav.lua" -Recurse -ErrorAction SilentlyContinue
            if ($files) {
                $foundFiles += $files
            }
        }
    }
    
    if ($foundFiles.Count -eq 0) {
        Write-Host "[Error] Could not automatically locate 'MeshNav.lua' in common WoW paths." -ForegroundColor Red
        Write-Host "Please run the script and provide the explicit path, e.g.:" -ForegroundColor Gray
        Write-Host ".\ParseLogs.ps1 -SavedVarsPath 'C:\WoW\WTF\Account\MYACCOUNT\SavedVariables\MeshNav.lua'" -ForegroundColor Gray
        return
    } elseif ($foundFiles.Count -eq 1) {
        $SavedVarsPath = $foundFiles[0].FullName
        Write-Host "Found file: $SavedVarsPath" -ForegroundColor Green
    } else {
        Write-Host "Found multiple potential SavedVariables accounts:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $foundFiles.Count; $i++) {
            Write-Host " [$i] $($foundFiles[$i].FullName)" -ForegroundColor Gray
        }
        $selection = Read-Host "Select index [0-$($foundFiles.Count - 1)]"
        if ($selection -match '^\d+$' -and [int]$selection -lt $foundFiles.Count) {
            $SavedVarsPath = $foundFiles[[int]$selection].FullName
        } else {
            Write-Host "Invalid selection. Exiting." -ForegroundColor Red
            return
        }
    }
}

# 2. Check if file exists
if (-not (Test-Path $SavedVarsPath)) {
    Write-Host "[Error] File not found: $SavedVarsPath" -ForegroundColor Red
    return
}

# 3. Read content
Write-Host "Reading log database..." -ForegroundColor Gray
$content = Get-Content -Raw -Path $SavedVarsPath

# Extract the history block using regex
$historyRegex = '\["history"\]\s*=\s*\{(.*?)\}\s*(?:,\s*\[|\r?\n\})'
if ($content -match $historyRegex) {
    $historyBlock = $Matches[1]
    
    # Extract entries enclosed in {...}
    $entryMatches = [regex]::Matches($historyBlock, '(?s)\{(.*?)\}')
    
    Write-Host "Found $($entryMatches.Count) sync history records." -ForegroundColor Green
    
    $parsedRecords = @()
    foreach ($match in $entryMatches) {
        $inner = $match.Groups[1].Value
        
        # Parse fields (order-independent)
        $timeVal = $null
        $senderVal = $null
        $payloadVal = $null
        
        if ($inner -match '\["time"\]\s*=\s*(\d+)') {
            $timeVal = $Matches[1]
        }
        if ($inner -match '\["sender"\]\s*=\s*"([^"]+)"') {
            $senderVal = $Matches[1]
        }
        if ($inner -match '\["payload"\]\s*=\s*"([^"]+)"') {
            $payloadVal = $Matches[1]
        }
        
        if ($timeVal -and $senderVal -and $payloadVal) {
            # Convert epoch time to datetime object
            $epoch = [datetime]"1970-01-01 00:00:00"
            $dateTime = $epoch.AddSeconds($timeVal).ToLocalTime()
            
            # Format payload for human readability
            # Payload looks like "3:24015" where 3 is sender index, 24015 are buckets
            $senderIdx = $null
            $buckets = $null
            if ($payloadVal -match '^(\d+):(.*)$') {
                $senderIdx = $Matches[1]
                $buckets = $Matches[2]
            }
            
            $parsedRecords += [PSCustomObject]@{
                Timestamp      = $dateTime.ToString("yyyy-MM-dd HH:mm:ss")
                Sender         = $senderVal
                SenderIndex    = $senderIdx
                DistanceVector = $buckets
            }
        }
    }
    
    if ($parsedRecords.Count -gt 0) {
        Write-Host "Sync Logs History:" -ForegroundColor Green
        $parsedRecords | Out-String | Write-Host
    } else {
        Write-Host "No valid records could be parsed from the history block." -ForegroundColor Yellow
    }
} else {
    Write-Host "[Notice] No history log data block found in this file. Make sure you enabled logging in game using '/mr log' and reloaded your UI or logged out." -ForegroundColor Yellow
}

