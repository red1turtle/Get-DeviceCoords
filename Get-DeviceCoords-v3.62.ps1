<#
.SYNOPSIS
    Determines the best available physical location for Windows, Linux, or macOS.

.DESCRIPTION
    Uses multiple signals in order of trust:
      1. Verified Windows satellite/GNSS fix when PositionSource=Satellite
      2. Known/enterprise Wi-Fi BSSID map (VPN-independent, optional)
      3. Google Geolocation API using nearby Wi-Fi BSSIDs with considerIp=false
         (VPN-independent, optional; skipped completely when no key is configured)
      4. WiGLE exact-BSSID geolocation fallback
         (VPN-independent, optional; rate-limited and persistently cached)
      5. Passive Bluetooth LE proximity/anchor evidence
         (Windows; no pairing, connection, GATT interrogation, or upload)
      6. Native OS location provider where available
           Windows : Windows Location / GeoCoordinateWatcher
           macOS   : Core Location through built-in osascript/JXA
           Linux   : GeoClue where-am-i helper when installed
      7. Public-IP geolocation (fallback only; may represent VPN/proxy egress)

    Wi-Fi discovery is platform-specific:
           Windows : netsh wlan show networks mode=bssid
           Linux   : NetworkManager nmcli
           macOS   : CoreWLAN through osascript/JXA, with legacy airport fallback

    Public-IP geolocation is never treated as authoritative physical location.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for native OS location. Default: 8.

.PARAMETER GoogleGeolocationApiKey
    Optional Google Maps Platform Geolocation API key. If omitted, the script checks
    GOOGLE_GEO_API_KEY. If neither exists, Google is skipped without making a request
    and Google-specific fields are omitted from the final result.

.PARAMETER WigleApiName
    Optional WiGLE API name used for Basic authentication. If omitted, the script checks
    WIGLE_API_NAME.

.PARAMETER WigleApiToken
    Optional WiGLE API token used for Basic authentication. If omitted, the script checks
    WIGLE_API_TOKEN. WiGLE-specific fields are omitted from the final result unless both
    WiGLE credentials are resolved.

.PARAMETER MaxWigleLookupsPerRun
    Maximum number of live WiGLE BSSID requests in one execution. Default: 8.
    Persistent positive/negative caching prevents repeated queries for known BSSIDs.

.PARAMETER WifiMapPath
    Optional CSV containing known BSSID-to-site mappings:
      BSSID,Latitude,Longitude,Site,AccuracyMeters

.PARAMETER BluetoothMapPath
    Optional JSON map of known Bluetooth LE anchors. Supplying this parameter forces
    Bluetooth scan status/detail/evidence to be visible in the result, even when the
    scan returns zero devices or fails.

.PARAMETER BluetoothScanSeconds
    Passive Bluetooth LE scan window in seconds. In the stock build this parameter is null,
    so Bluetooth scanning remains opt-in.

    For remediation systems that cannot pass command-line switches, a deployment copy may
    assign a default directly in the param block, for example:

        [Nullable[int]]$BluetoothScanSeconds = 10

    A non-null scripted default enables Bluetooth and becomes the scan duration. When
    -BluetoothMapPath is supplied without any configured scan duration, an internal
    4-second scan window is used.

.PARAMETER SkipBluetooth
    Skip Bluetooth LE scanning. Because this is an explicit Bluetooth control, the result
    still shows BluetoothScanStatus, BluetoothScanDetail, and BluetoothEvidence explaining
    that scanning was skipped.

.PARAMETER NoTemporaryLocationConsent
    Windows only. Do not temporarily set the current user's Location consent to Allow.
    Existing consent is restored before exit.

.PARAMETER SkipPublicIpLookup
    Skip public-IP geolocation and physical-vs-egress comparison.

.PARAMETER IncludeWifiEvidence
    Retained for backward compatibility. Wi-Fi evidence is always returned in v3.1.

.EXAMPLE
    ./Get-DeviceCoords-v3.62.ps1 -IncludeWifiEvidence | Format-List *

.EXAMPLE
    $env:GOOGLE_GEO_API_KEY = '<key>'
    ./Get-DeviceCoords-v3.62.ps1 -IncludeWifiEvidence | Format-List *

.EXAMPLE
    $env:WIGLE_API_NAME = '<api-name>'
    $env:WIGLE_API_TOKEN = '<api-token>'
    ./Get-DeviceCoords-v3.62.ps1 | Format-List *

.EXAMPLE
    ./Get-DeviceCoords-v3.62.ps1 -WifiMapPath ./Corporate-WifiLocations.csv

.NOTES
    Lean production build preserving v3.40 collection/output functionality and adding
    router identity enrichment, normalized hardware/platform identity, and symmetric positive/negative router-VPN inference.
    WiGLE remains query-only; this script never uploads observations or enables any
    donation/commercial-use flag.
    Windows PowerShell 5.1 compatibility is retained; PowerShell 7 is recommended.
    Execution is quiet by default. Use -Verbose for collection/diagnostic output.
    Explicit Bluetooth parameters force Bluetooth scan outcome/evidence into the normal result. v3.49 uses the validated in-memory Windows PowerShell/C# BLE bridge and renders BLE evidence as a compact table. Windows BLE uses the current PowerShell WinRT projection first and automatically falls back to Windows PowerShell 5.1 when required.
    WifiEvidence remains the final output property.

#>

[CmdletBinding()]
param(
    [ValidateRange(2, 60)]
    [int]$TimeoutSeconds = 8,

    [string]$GoogleGeolocationApiKey,

    [string]$WigleApiName,

    [string]$WigleApiToken,

    [ValidateRange(1, 20)]
    [int]$MaxWigleLookupsPerRun = 8,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WifiMapPath,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BluetoothMapPath,

    [ValidateRange(1, 30)]
    [Nullable[int]]$BluetoothScanSeconds,

    [switch]$SkipBluetooth,

    [switch]$NoTemporaryLocationConsent,

    [switch]$SkipPublicIpLookup,

    [switch]$IncludeWifiEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Bluetooth can be enabled in either of two production deployment modes:
#
# 1. Runtime control:
#      -BluetoothScanSeconds 10
#      -BluetoothMapPath ...
#      -SkipBluetooth
#
# 2. Script-default/remediation control:
#      [Nullable[int]]$BluetoothScanSeconds = 10
#
# Parameter defaults are not added to $PSBoundParameters, so the non-null
# BluetoothScanSeconds value must also be considered configured intent.
$bluetoothScanSecondsConfigured = ($null -ne $BluetoothScanSeconds)

$bluetoothResultsForced = (
    $PSBoundParameters.ContainsKey('BluetoothMapPath') -or
    $PSBoundParameters.ContainsKey('BluetoothScanSeconds') -or
    $PSBoundParameters.ContainsKey('SkipBluetooth') -or
    $bluetoothScanSecondsConfigured
)

# The stock/public build leaves BluetoothScanSeconds null, which keeps BLE opt-in.
# A remediation build can assign a script default such as 10; that non-null value
# becomes both the activation signal and scan duration.
#
# -BluetoothMapPath without a configured duration still uses the internal 4-second
# fallback.
$effectiveBluetoothScanSeconds = if ($bluetoothScanSecondsConfigured) {
    [int]$BluetoothScanSeconds
}
else {
    4
}

# Always initialize optional Google resolver diagnostics before any branch can read them.
# Under StrictMode, reading an unset script-scoped variable terminates the script.
$script:GoogleWifiLastHttpStatus = $null
$script:GoogleWifiLastErrorReason = $null
$script:GoogleWifiLastErrorMessage = $null

$script:WigleLastHttpStatus = $null
$script:WigleLastErrorMessage = $null
$script:WigleLastErrorBody = $null
$script:WigleRateLimited = $false
$script:WigleRateLimitBasis = $null
$script:WigleRateLimitRemaining = $null
$script:WigleRateLimitLimit = $null
$script:WigleRateLimitReset = $null
$script:WigleTerminalFailure = $false
$script:WigleTerminalFailureBasis = $null
$script:WigleLiveQueriesUsed = 0
$script:WigleCacheHits = 0
$script:WigleCandidateCount = 0
$script:WigleCacheCandidatesChecked = 0
$script:WigleLiveCandidatesEligible = 0
$script:WigleCurrentBssidPrioritized = $false
$script:WigleCurrentBssid = $null
$script:WigleCurrentBssidEligibility = 'Unavailable'
$script:WigleCandidateOrder = @()

# Per-run caches for stable values. These are deliberately process-local only.
$script:PlatformNameCache = $null
$script:CommandPathCache = @{}
$script:IpGeoCache = @{}
$script:DnsIpv4Cache = @{}
$script:WindowsLocationConsentTargetsCache = @()
$script:WindowsLocationConsentTargetsCached = $false
$script:WindowsNetAdapterCache = @()
$script:WindowsNetAdapterCached = $false
$script:WindowsVpnConnectionCache = @()
$script:WindowsVpnConnectionCached = $false

function Get-PlatformName {
    if ($null -ne $script:PlatformNameCache) {
        return $script:PlatformNameCache
    }

    $script:PlatformNameCache = if ($PSVersionTable.PSVersion.Major -le 5) {
        'Windows'
    }
    elseif ($IsWindows) {
        'Windows'
    }
    elseif ($IsLinux) {
        'Linux'
    }
    elseif ($IsMacOS) {
        'macOS'
    }
    else {
        'Unknown'
    }

    return $script:PlatformNameCache
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string[]]$Candidates)

    $key = (@($Candidates) | ForEach-Object { [string]$_ }) -join ([char]31)

    if ($script:CommandPathCache.ContainsKey($key)) {
        return $script:CommandPathCache[$key]
    }

    $resolved = $null

    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if ([IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $resolved = [string]$candidate
                break
            }
            continue
        }

        $command = Get-Command `
            -Name $candidate `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($null -ne $command) {
            $resolved = [string]$command.Source
            break
        }
    }

    $script:CommandPathCache[$key] = $resolved
    return $resolved
}

function Get-DeviceProfile {
    $platform = Get-PlatformName
    $deviceType = 'Unknown'
    $detail = $null
    $wifiInterfacePresent = $false
    $wifiInterfaceDetail = @()

    # Cross-platform first pass: .NET can identify standard 802.11 interfaces without
    # triggering a network scan.
    try {
        $wirelessInterfaces = @(
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object {
                    $_.NetworkInterfaceType -eq
                        [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211
                }
        )

        if ($wirelessInterfaces.Count -gt 0) {
            $wifiInterfacePresent = $true
            $wifiInterfaceDetail = @(
                $wirelessInterfaces |
                    ForEach-Object {
                        if ([string]::IsNullOrWhiteSpace([string]$_.Description)) {
                            [string]$_.Name
                        }
                        else {
                            '{0} ({1})' -f $_.Name, $_.Description
                        }
                    }
            )
        }
    }
    catch {
        Write-Verbose ('Generic Wi-Fi interface detection failed: {0}' -f $_.Exception.Message)
    }

    switch ($platform) {
        'Windows' {
            $computerSystem = $null
            $chassisTypes = @()

            try {
                if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
                    $computerSystem = Get-CimInstance `
                        -ClassName Win32_ComputerSystem `
                        -Property PCSystemType, PCSystemTypeEx, Manufacturer, Model `
                        -ErrorAction Stop

                    $enclosures = @(
                        Get-CimInstance `
                            -ClassName Win32_SystemEnclosure `
                            -Property ChassisTypes `
                            -ErrorAction Stop
                    )
                }
                elseif (Get-Command -Name Get-WmiObject -ErrorAction SilentlyContinue) {
                    $computerSystem = Get-WmiObject `
                        -Class Win32_ComputerSystem `
                        -Property PCSystemType, PCSystemTypeEx, Manufacturer, Model `
                        -ErrorAction Stop

                    $enclosures = @(
                        Get-WmiObject `
                            -Class Win32_SystemEnclosure `
                            -Property ChassisTypes `
                            -ErrorAction Stop
                    )
                }
                else {
                    $enclosures = @()
                }

                $chassisTypes = @(
                    $enclosures |
                        ForEach-Object { @($_.ChassisTypes) } |
                        Where-Object { $null -ne $_ } |
                        ForEach-Object { [int]$_ } |
                        Select-Object -Unique
                )
            }
            catch {
                Write-Verbose ('Windows chassis detection failed: {0}' -f $_.Exception.Message)
            }

            $manufacturer = if ($null -ne $computerSystem) { [string]$computerSystem.Manufacturer } else { '' }
            $model = if ($null -ne $computerSystem) { [string]$computerSystem.Model } else { '' }
            $pcSystemType = if ($null -ne $computerSystem -and $null -ne $computerSystem.PCSystemType) {
                [int]$computerSystem.PCSystemType
            }
            else {
                0
            }

            $portableChassis = @(8, 9, 10, 11, 14, 30, 31, 32)
            $serverChassis = @(17, 23, 28, 29)
            $desktopChassis = @(3, 4, 5, 6, 7, 13, 15, 16, 24, 35, 36)

            if (('{0} {1}' -f $manufacturer, $model) -match
                '(?i)virtualbox|vmware|virtual machine|kvm|qemu|hyper-v|parallels|xen') {
                $deviceType = 'Virtual'
            }
            elseif (@($chassisTypes | Where-Object { $_ -in $portableChassis }).Count -gt 0 -or
                    $pcSystemType -eq 2) {
                $deviceType = 'Portable'
            }
            elseif ($pcSystemType -in @(4, 5, 7) -or
                    @($chassisTypes | Where-Object { $_ -in $serverChassis }).Count -gt 0) {
                $deviceType = 'Server'
            }
            elseif ($pcSystemType -eq 3) {
                $deviceType = 'Workstation'
            }
            elseif ($pcSystemType -eq 1 -or
                    @($chassisTypes | Where-Object { $_ -in $desktopChassis }).Count -gt 0) {
                $deviceType = 'Desktop'
            }

            $detail = 'PCSystemType={0}; ChassisTypes={1}; Manufacturer={2}; Model={3}' -f
                $pcSystemType,
                $(if ($chassisTypes.Count -gt 0) { $chassisTypes -join ',' } else { '<none>' }),
                $(if ([string]::IsNullOrWhiteSpace($manufacturer)) { '<unknown>' } else { $manufacturer }),
                $(if ([string]::IsNullOrWhiteSpace($model)) { '<unknown>' } else { $model })

            # Fallback Wi-Fi interface check for Windows hosts whose .NET adapter type does
            # not report Wireless80211 correctly.
            if (-not $wifiInterfacePresent -and
                (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
                try {
                    $wifiAdapters = @(
                        Get-NetAdapter -IncludeHidden -ErrorAction Stop |
                            Where-Object {
                                ([string]$_.NdisPhysicalMedium -match '(?i)802\.11|wireless') -or
                                ('{0} {1}' -f $_.Name, $_.InterfaceDescription) -match
                                    '(?i)\bwi-?fi\b|wireless|wlan|802\.11'
                            }
                    )

                    if ($wifiAdapters.Count -gt 0) {
                        $wifiInterfacePresent = $true
                        $wifiInterfaceDetail = @(
                            $wifiAdapters |
                                ForEach-Object {
                                    '{0} ({1})' -f $_.Name, $_.InterfaceDescription
                                }
                        )
                    }
                }
                catch {
                    Write-Verbose ('Get-NetAdapter Wi-Fi capability fallback failed: {0}' -f $_.Exception.Message)
                }
            }
        }

        'Linux' {
            $chassisType = $null
            $vendor = $null
            $model = $null

            try {
                if (Test-Path -LiteralPath '/sys/class/dmi/id/chassis_type') {
                    $chassisType = [int](
                        (Get-Content -LiteralPath '/sys/class/dmi/id/chassis_type' -Raw).Trim()
                    )
                }

                if (Test-Path -LiteralPath '/sys/class/dmi/id/sys_vendor') {
                    $vendor = (Get-Content -LiteralPath '/sys/class/dmi/id/sys_vendor' -Raw).Trim()
                }

                if (Test-Path -LiteralPath '/sys/class/dmi/id/product_name') {
                    $model = (Get-Content -LiteralPath '/sys/class/dmi/id/product_name' -Raw).Trim()
                }
            }
            catch {
                Write-Verbose ('Linux DMI chassis detection failed: {0}' -f $_.Exception.Message)
            }

            $hasBattery = @(
                Get-ChildItem -LiteralPath '/sys/class/power_supply' -ErrorAction SilentlyContinue |
                    Where-Object Name -Like 'BAT*'
            ).Count -gt 0

            if (('{0} {1}' -f $vendor, $model) -match
                '(?i)virtualbox|vmware|kvm|qemu|virtual machine|xen|parallels') {
                $deviceType = 'Virtual'
            }
            elseif ($hasBattery -or $chassisType -in @(8, 9, 10, 11, 14, 30, 31, 32)) {
                $deviceType = 'Portable'
            }
            elseif ($chassisType -in @(17, 23, 28, 29)) {
                $deviceType = 'Server'
            }
            elseif ($chassisType -in @(3, 4, 5, 6, 7, 13, 15, 16, 24, 35, 36)) {
                $deviceType = 'Desktop'
            }

            # /sys/class/net/<if>/wireless is a direct kernel-exposed indication.
            $linuxWireless = @(
                Get-ChildItem -LiteralPath '/sys/class/net' -Directory -ErrorAction SilentlyContinue |
                    Where-Object {
                        Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'wireless')
                    }
            )

            if ($linuxWireless.Count -gt 0) {
                $wifiInterfacePresent = $true
                $wifiInterfaceDetail = @($linuxWireless.Name)
            }

            $detail = 'ChassisType={0}; Battery={1}; Vendor={2}; Model={3}' -f
                $(if ($null -eq $chassisType) { '<unknown>' } else { $chassisType }),
                $hasBattery,
                $(if ([string]::IsNullOrWhiteSpace($vendor)) { '<unknown>' } else { $vendor }),
                $(if ([string]::IsNullOrWhiteSpace($model)) { '<unknown>' } else { $model })
        }

        'macOS' {
            $model = $null
            $hasBattery = $false

            try {
                $sysctl = Get-CommandPath -Candidates @('/usr/sbin/sysctl', 'sysctl')
                if ($sysctl) {
                    $result = Invoke-NativeCapture `
                        -FilePath $sysctl `
                        -ArgumentList @('-n', 'hw.model') `
                        -TimeoutSeconds 3
                    $model = ([string]$result.StdOut).Trim()
                }
            }
            catch {
                Write-Verbose ('macOS model detection failed: {0}' -f $_.Exception.Message)
            }

            try {
                $ioreg = Get-CommandPath -Candidates @('/usr/sbin/ioreg', 'ioreg')
                if ($ioreg) {
                    $batteryProbe = Invoke-NativeCapture `
                        -FilePath $ioreg `
                        -ArgumentList @('-r', '-c', 'AppleSmartBattery', '-d', '1') `
                        -TimeoutSeconds 3
                    $hasBattery = ([string]$batteryProbe.StdOut) -match 'AppleSmartBattery'
                }
            }
            catch {
                Write-Verbose ('macOS battery detection failed: {0}' -f $_.Exception.Message)
            }

            if ($hasBattery -or $model -match '(?i)^MacBook') {
                $deviceType = 'Portable'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($model)) {
                $deviceType = 'Desktop'
            }

            # networksetup can tell us whether a Wi-Fi hardware port exists without scanning.
            try {
                $networksetup = Get-CommandPath -Candidates @('/usr/sbin/networksetup', 'networksetup')
                if ($networksetup) {
                    $networkProbe = Invoke-NativeCapture `
                        -FilePath $networksetup `
                        -ArgumentList @('-listallhardwareports') `
                        -TimeoutSeconds 4

                    $networkText = [string]$networkProbe.StdOut
                    if ($networkText -match '(?im)^Hardware Port:\s*(Wi-Fi|AirPort)\s*$') {
                        $wifiInterfacePresent = $true
                        $wifiInterfaceDetail = @(
                            [regex]::Matches(
                                $networkText,
                                '(?ims)^Hardware Port:\s*(?:Wi-Fi|AirPort)\s*\r?\nDevice:\s*([^\r\n]+)'
                            ) |
                                ForEach-Object { $_.Groups[1].Value.Trim() }
                        )
                    }
                }
            }
            catch {
                Write-Verbose ('macOS Wi-Fi hardware-port detection failed: {0}' -f $_.Exception.Message)
            }

            $detail = 'Battery={0}; Model={1}' -f
                $hasBattery,
                $(if ([string]::IsNullOrWhiteSpace($model)) { '<unknown>' } else { $model })
        }
    }

    return [pscustomobject]@{
        DeviceType           = $deviceType
        WifiInterfacePresent = [bool]$wifiInterfacePresent
        WifiInterfaceDetail  = @($wifiInterfaceDetail)
        Detail               = $detail
    }
}

function New-SkippedWifiScanResult {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [string]$Reason
    )

    return [pscustomobject]@{
        Status        = $Status
        ExitCode      = 0
        ErrorText     = $Reason
        Collector     = 'Skipped'
        ScanAttempts  = 0
        RawBssidCount = 0
        AccessPoints  = @()
    }
}

function ConvertTo-NativeProcessArgumentString {
    param(
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    # ProcessStartInfo.ArgumentList is not available on Windows PowerShell 5.1 /
    # .NET Framework. This function builds the legacy ProcessStartInfo.Arguments
    # command line using the Windows CommandLineToArgvW quoting rules.
    $quotedArguments = [System.Collections.Generic.List[string]]::new()

    foreach ($rawArgument in $ArgumentList) {
        $argument = if ($null -eq $rawArgument) { '' } else { [string]$rawArgument }

        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $quotedArguments.Add($argument)
            continue
        }

        $builder = [System.Text.StringBuilder]::new()
        $null = $builder.Append('"')
        $backslashCount = 0

        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashCount++
                continue
            }

            if ($character -eq '"') {
                # Backslashes immediately before a quote must be doubled, and the
                # embedded quote itself must be escaped.
                if ($backslashCount -gt 0) {
                    $null = $builder.Append(('\' * ($backslashCount * 2)))
                }

                $null = $builder.Append('\"')
                $backslashCount = 0
                continue
            }

            if ($backslashCount -gt 0) {
                $null = $builder.Append(('\' * $backslashCount))
                $backslashCount = 0
            }

            $null = $builder.Append($character)
        }

        # Trailing backslashes inside a quoted argument must also be doubled.
        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\' * ($backslashCount * 2)))
        }

        $null = $builder.Append('"')
        $quotedArguments.Add($builder.ToString())
    }

    return ($quotedArguments -join ' ')
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 90)][int]$TimeoutSeconds = 8,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $supportsArgumentList = $psi.PSObject.Properties.Name -contains 'ArgumentList'

    if ($supportsArgumentList) {
        foreach ($argument in $ArgumentList) {
            $null = $psi.ArgumentList.Add([string]$argument)
        }

        $argumentMode = 'ArgumentList'
    }
    else {
        # Windows PowerShell 5.1 / .NET Framework compatibility path.
        $psi.Arguments = ConvertTo-NativeProcessArgumentString -ArgumentList $ArgumentList
        $argumentMode = 'Arguments'
    }

    $supportsEnvironment = $psi.PSObject.Properties.Name -contains 'Environment'
    $supportsEnvironmentVariables = $psi.PSObject.Properties.Name -contains 'EnvironmentVariables'

    foreach ($key in $Environment.Keys) {
        try {
            if ($supportsEnvironment) {
                $psi.Environment[[string]$key] = [string]$Environment[$key]
            }
            elseif ($supportsEnvironmentVariables) {
                $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
            }
        }
        catch {
            Write-Verbose ('Unable to set child-process environment variable [{0}]: {1}' -f
                $key,
                $_.Exception.Message)
        }
    }

    Write-Verbose ('Native process: {0}; argumentMode={1}; environmentMode={2}' -f
        $FilePath,
        $argumentMode,
        $(if ($supportsEnvironment) {
            'Environment'
        }
        elseif ($supportsEnvironmentVariables) {
            'EnvironmentVariables'
        }
        else {
            'Unavailable'
        }))

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        $null = $process.Start()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Kill(Boolean) is newer than .NET Framework. PowerShell's method binder will
            # throw on the unsupported overload in Windows PowerShell 5.1; then use Kill().
            try {
                $process.Kill($true)
            }
            catch {
                try { $process.Kill() } catch { }
            }

            return [pscustomobject]@{
                ExitCode = -2
                StdOut   = $stdoutTask.GetAwaiter().GetResult()
                StdErr   = 'Process timed out.'
                TimedOut = $true
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Normalize-Bssid {
    param(
        [AllowNull()]
        [string]$Bssid
    )

    if ([string]::IsNullOrWhiteSpace($Bssid)) {
        return $null
    }

    $normalized = $Bssid.Trim().Replace('-', ':').ToUpperInvariant()

    if ($normalized -notmatch '^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$') {
        return $null
    }

    return $normalized
}

function Get-GoogleWifiBssidAssessment {
    param([Parameter(Mandatory)][string]$Bssid)

    $normalized = Normalize-Bssid -Bssid $Bssid

    if ($null -eq $normalized) {
        return [pscustomobject]@{ Usable = $false; Reason = 'InvalidFormat' }
    }

    if ($normalized -eq 'FF:FF:FF:FF:FF:FF') {
        return [pscustomobject]@{ Usable = $false; Reason = 'Broadcast' }
    }

    if ($normalized.StartsWith('00:00:5E:')) {
        return [pscustomobject]@{ Usable = $false; Reason = 'ReservedIanaRange' }
    }

    $firstOctet = [Convert]::ToInt32($normalized.Substring(0, 2), 16)

    if (($firstOctet -band 0x01) -ne 0) {
        return [pscustomobject]@{ Usable = $false; Reason = 'MulticastOrGroup' }
    }

    if (($firstOctet -band 0x02) -ne 0) {
        return [pscustomobject]@{ Usable = $false; Reason = 'LocallyAdministered' }
    }

    return [pscustomobject]@{ Usable = $true; Reason = 'UniversallyAdministered' }
}

function New-WifiEvidenceRecord {
    param(
        [Parameter(Mandatory)][string]$Bssid,
        [AllowNull()][string]$Ssid,
        [AllowNull()][Nullable[int]]$SignalPercent,
        [AllowNull()][Nullable[int]]$SignalDbm,
        [AllowNull()][Nullable[int]]$Channel,
        [Parameter(Mandatory)][string]$Source
    )

    $normalized = Normalize-Bssid -Bssid $Bssid

    if ($null -eq $normalized) {
        return
    }

    $assessment = Get-GoogleWifiBssidAssessment -Bssid $normalized

    [pscustomobject]@{
        BSSID             = $normalized
        SSID              = if ([string]::IsNullOrWhiteSpace($Ssid)) { $null } else { $Ssid }
        SignalPercent     = $SignalPercent
        SignalDbm        = $SignalDbm
        Channel           = $Channel
        GoogleUsable      = [bool]$assessment.Usable
        GoogleEligibility = [string]$assessment.Reason
        Source            = $Source
    }
}

function Get-WifiSortScore {
    param([Parameter(Mandatory)][object]$AccessPoint)

    if ($null -ne $AccessPoint.SignalDbm) {
        # Typical Wi-Fi range is approximately -100..-20 dBm. Higher is stronger.
        return 1000 + [int]$AccessPoint.SignalDbm
    }

    if ($null -ne $AccessPoint.SignalPercent) {
        return [int]$AccessPoint.SignalPercent
    }

    return -10000
}

function Merge-WifiEvidence {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AccessPoints)

    $byBssid = @{}

    foreach ($ap in $AccessPoints) {
        if ($null -eq $ap -or [string]::IsNullOrWhiteSpace([string]$ap.BSSID)) { continue }

        $bssid = ([string]$ap.BSSID).Trim().Replace('-', ':').ToUpperInvariant()

        if (-not $byBssid.ContainsKey($bssid)) {
            $byBssid[$bssid] = $ap
            continue
        }

        $existing = $byBssid[$bssid]

        if ([string]::IsNullOrWhiteSpace([string]$existing.SSID) -and
            -not [string]::IsNullOrWhiteSpace([string]$ap.SSID)) {
            $existing.SSID = $ap.SSID
        }

        if ($null -ne $ap.SignalDbm -and
            ($null -eq $existing.SignalDbm -or [int]$ap.SignalDbm -gt [int]$existing.SignalDbm)) {
            $existing.SignalDbm = $ap.SignalDbm
        }

        if ($null -ne $ap.SignalPercent -and
            ($null -eq $existing.SignalPercent -or [int]$ap.SignalPercent -gt [int]$existing.SignalPercent)) {
            $existing.SignalPercent = $ap.SignalPercent
        }

        if ($null -eq $existing.Channel -and $null -ne $ap.Channel) {
            $existing.Channel = $ap.Channel
        }
    }

    return @(
        $byBssid.Values |
            Sort-Object -Property @{ Expression = { Get-WifiSortScore -AccessPoint $_ }; Descending = $true },
                                  @{ Expression = { [string]$_.BSSID }; Descending = $false }
    )
}

# ---------------------------------------------------------------------------
# Windows privacy/location helpers
# ---------------------------------------------------------------------------

function Convert-WindowsAccountNameToSid {
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return $null
    }

    try {
        $account = [Security.Principal.NTAccount]::new($AccountName)
        return [string](
            $account.Translate([Security.Principal.SecurityIdentifier]).Value
        )
    }
    catch {
        Write-Verbose ('Unable to translate Windows account [{0}] to SID: {1}' -f
            $AccountName,
            $_.Exception.Message)
        return $null
    }
}

function Get-WindowsLocationConsentTargetSids {
    if ((Get-PlatformName) -ne 'Windows') {
        return @()
    }

    $sids = [System.Collections.Generic.List[string]]::new()
    $serviceSids = @(
        'S-1-5-18', # LocalSystem
        'S-1-5-19', # LocalService
        'S-1-5-20'  # NetworkService
    )

    $identity = $null
    $currentSid = $null

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -ne $identity.User) {
            $currentSid = [string]$identity.User.Value
        }
    }
    catch {
        Write-Verbose ('Unable to determine current Windows identity SID: {0}' -f
            $_.Exception.Message)
    }

    # Normal interactive execution: target the actual current user's loaded HKU hive
    # directly. This avoids enumerating HKEY_USERS, which can fail for non-admin users.
    if (-not [string]::IsNullOrWhiteSpace($currentSid) -and
        $currentSid -notin $serviceSids) {

        $sids.Add($currentSid)
    }
    else {
        # SYSTEM/service execution: HKCU is the service account's hive (for LocalSystem,
        # HKEY_USERS\S-1-5-18), not the logged-on user's hive. Resolve the active console
        # user and address that SID under HKEY_USERS directly.
        try {
            $consoleUser = $null

            if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
                $computerSystem = Get-CimInstance `
                    -ClassName Win32_ComputerSystem `
                    -Property UserName `
                    -ErrorAction Stop
                $consoleUser = [string]$computerSystem.UserName
            }
            elseif (Get-Command -Name Get-WmiObject -ErrorAction SilentlyContinue) {
                $computerSystem = Get-WmiObject `
                    -Class Win32_ComputerSystem `
                    -Property UserName `
                    -ErrorAction Stop
                $consoleUser = [string]$computerSystem.UserName
            }

            if (-not [string]::IsNullOrWhiteSpace($consoleUser)) {
                $consoleSid = Convert-WindowsAccountNameToSid -AccountName $consoleUser

                if (-not [string]::IsNullOrWhiteSpace($consoleSid) -and
                    -not $sids.Contains($consoleSid)) {
                    $sids.Add($consoleSid)
                }
            }
        }
        catch {
            Write-Verbose ('Unable to resolve active console-user SID: {0}' -f
                $_.Exception.Message)
        }

        # Fallback for remediation/EDR contexts where Win32_ComputerSystem.UserName is
        # empty (for example around lock/session transitions): use owners of explorer.exe
        # processes. We still target explicit SIDs; HKEY_USERS is never enumerated.
        if ($sids.Count -eq 0) {
            try {
                if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
                    $explorers = @(
                        Get-CimInstance `
                            -ClassName Win32_Process `
                            -Filter "Name='explorer.exe'" `
                            -ErrorAction Stop
                    )

                    foreach ($explorer in $explorers) {
                        try {
                            $owner = Invoke-CimMethod `
                                -InputObject $explorer `
                                -MethodName GetOwner `
                                -ErrorAction Stop

                            if ($owner.ReturnValue -eq 0 -and
                                -not [string]::IsNullOrWhiteSpace([string]$owner.User)) {

                                $accountName = if (
                                    [string]::IsNullOrWhiteSpace([string]$owner.Domain)
                                ) {
                                    [string]$owner.User
                                }
                                else {
                                    '{0}\{1}' -f $owner.Domain, $owner.User
                                }

                                $ownerSid = Convert-WindowsAccountNameToSid `
                                    -AccountName $accountName

                                if (-not [string]::IsNullOrWhiteSpace($ownerSid) -and
                                    $ownerSid -notin $serviceSids -and
                                    -not $sids.Contains($ownerSid)) {
                                    $sids.Add($ownerSid)
                                }
                            }
                        }
                        catch {
                            Write-Verbose ('Unable to resolve explorer.exe owner SID: {0}' -f
                                $_.Exception.Message)
                        }
                    }
                }
            }
            catch {
                Write-Verbose ('Unable to enumerate explorer.exe processes for Location consent targeting: {0}' -f
                    $_.Exception.Message)
            }
        }
    }

    # Only retain SIDs whose user hives are actually loaded. Accessing a specific
    # HKEY_USERS\<SID> path does not require enumerating the HKEY_USERS root.
    return @(
        $sids |
            Where-Object {
                Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $_)
            } |
            Select-Object -Unique
    )
}

function Get-WindowsLocationConsentTargets {
    if ((Get-PlatformName) -ne 'Windows') {
        return @()
    }

    if ($script:WindowsLocationConsentTargetsCached) {
        return @($script:WindowsLocationConsentTargetsCache)
    }

    $suffix = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'

    $script:WindowsLocationConsentTargetsCache = @(
        Get-WindowsLocationConsentTargetSids |
            ForEach-Object {
                'Registry::HKEY_USERS\{0}\{1}' -f $_, $suffix
            }
    )
    $script:WindowsLocationConsentTargetsCached = $true

    return @($script:WindowsLocationConsentTargetsCache)
}

function Get-WindowsCurrentLocationConsentValue {
    if ((Get-PlatformName) -ne 'Windows') {
        return $null
    }

    foreach ($path in @(Get-WindowsLocationConsentTargets)) {
        try {
            $item = Get-ItemProperty `
                -LiteralPath $path `
                -Name Value `
                -ErrorAction Stop

            if ($item.PSObject.Properties.Name -contains 'Value') {
                return [string]$item.Value
            }
        }
        catch {
            Write-Verbose ('Unable to read Windows Location consent at [{0}]: {1}' -f
                $path,
                $_.Exception.Message)
        }
    }

    return $null
}

function Get-WindowsLocationServiceState {
    if ((Get-PlatformName) -ne 'Windows') { return $null }

    try {
        return [string](Get-Service -Name 'lfsvc' -ErrorAction Stop).Status
    }
    catch {
        return 'Unavailable'
    }
}

function Enable-WindowsTemporaryLocationConsent {
    $snapshots = [System.Collections.Generic.List[object]]::new()

    if ((Get-PlatformName) -ne 'Windows') {
        return @()
    }

    $targets = @(Get-WindowsLocationConsentTargets)

    if ($targets.Count -eq 0) {
        Write-Verbose 'No loaded interactive-user HKU hive could be resolved for Windows Location consent.'
        return @()
    }

    foreach ($path in $targets) {
        try {
            $keyExisted = Test-Path -LiteralPath $path

            if (-not $keyExisted) {
                $null = New-Item -Path $path -Force -ErrorAction Stop
            }

            $properties = Get-ItemProperty `
                -LiteralPath $path `
                -ErrorAction SilentlyContinue

            $valueExisted = $false
            $originalValue = $null

            if ($null -ne $properties -and
                $properties.PSObject.Properties.Name -contains 'Value') {
                $valueExisted = $true
                $originalValue = $properties.Value
            }

            $snapshots.Add([pscustomobject]@{
                Path          = $path
                KeyExisted    = $keyExisted
                ValueExisted  = $valueExisted
                OriginalValue = $originalValue
            })

            Set-ItemProperty `
                -LiteralPath $path `
                -Name 'Value' `
                -Value 'Allow' `
                -ErrorAction Stop
        }
        catch {
            Write-Verbose ('Could not temporarily allow Windows Location at [{0}]: {1}' -f
                $path,
                $_.Exception.Message)
        }
    }

    return @($snapshots)
}

function Restore-WindowsLocationConsent {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Snapshot
    )

    foreach ($item in @($Snapshot)) {
        try {
            if ($item.ValueExisted) {
                Set-ItemProperty `
                    -LiteralPath $item.Path `
                    -Name 'Value' `
                    -Value $item.OriginalValue `
                    -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $item.Path) {
                Remove-ItemProperty `
                    -LiteralPath $item.Path `
                    -Name 'Value' `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning ('Failed to restore Windows Location consent at [{0}]: {1}' -f
                $item.Path,
                $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# Wi-Fi collectors
# ---------------------------------------------------------------------------

function Initialize-WindowsNativeWlanScanApi {
    if ((Get-PlatformName) -ne 'Windows') {
        return
    }

    if ($null -ne ('DeviceCoords.NativeWlanV32' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace DeviceCoords
{
    public sealed class NativeWlanScanResult
    {
        public bool ApiAvailable { get; set; }
        public bool ScanRequested { get; set; }
        public int InterfaceCount { get; set; }
        public int SuccessfulScanRequests { get; set; }
        public string[] InterfaceDescriptions { get; set; }
        public uint[] ScanResults { get; set; }
        public uint OpenResult { get; set; }
        public uint EnumResult { get; set; }
        public string Error { get; set; }
        public int WaitMilliseconds { get; set; }
    }

    internal enum WLAN_INTERFACE_STATE
    {
        NotReady = 0,
        Connected = 1,
        AdHocNetworkFormed = 2,
        Disconnecting = 3,
        Disconnected = 4,
        Associating = 5,
        Discovering = 6,
        Authenticating = 7
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WLAN_INTERFACE_INFO
    {
        public Guid InterfaceGuid;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string InterfaceDescription;

        public WLAN_INTERFACE_STATE InterfaceState;
    }

    public static class NativeWlanV32
    {
        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanOpenHandle(
            uint dwClientVersion,
            IntPtr pReserved,
            out uint pdwNegotiatedVersion,
            out IntPtr phClientHandle
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanCloseHandle(
            IntPtr hClientHandle,
            IntPtr pReserved
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanEnumInterfaces(
            IntPtr hClientHandle,
            IntPtr pReserved,
            out IntPtr ppInterfaceList
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanScan(
            IntPtr hClientHandle,
            ref Guid pInterfaceGuid,
            IntPtr pDot11Ssid,
            IntPtr pIeData,
            IntPtr pReserved
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern void WlanFreeMemory(IntPtr pMemory);

        public static NativeWlanScanResult Refresh(int waitMilliseconds)
        {
            NativeWlanScanResult result = new NativeWlanScanResult();
            result.ApiAvailable = true;
            result.WaitMilliseconds = waitMilliseconds;

            IntPtr clientHandle = IntPtr.Zero;
            IntPtr interfaceList = IntPtr.Zero;

            try
            {
                uint negotiatedVersion;
                uint openResult = WlanOpenHandle(
                    2,
                    IntPtr.Zero,
                    out negotiatedVersion,
                    out clientHandle
                );

                result.OpenResult = openResult;

                if (openResult != 0)
                {
                    result.Error = "WlanOpenHandle failed with Win32 error " + openResult + ".";
                    return result;
                }

                uint enumResult = WlanEnumInterfaces(
                    clientHandle,
                    IntPtr.Zero,
                    out interfaceList
                );

                result.EnumResult = enumResult;

                if (enumResult != 0)
                {
                    result.Error = "WlanEnumInterfaces failed with Win32 error " + enumResult + ".";
                    return result;
                }

                int numberOfItems = Marshal.ReadInt32(interfaceList, 0);
                result.InterfaceCount = numberOfItems;

                List<string> descriptions = new List<string>();
                List<uint> scanResults = new List<uint>();
                int infoSize = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));
                IntPtr current = IntPtr.Add(interfaceList, 8);

                for (int i = 0; i < numberOfItems; i++)
                {
                    WLAN_INTERFACE_INFO info =
                        (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(
                            current,
                            typeof(WLAN_INTERFACE_INFO)
                        );

                    descriptions.Add(
                        String.IsNullOrWhiteSpace(info.InterfaceDescription)
                            ? info.InterfaceGuid.ToString()
                            : info.InterfaceDescription
                    );

                    Guid interfaceGuid = info.InterfaceGuid;

                    uint scanResult = WlanScan(
                        clientHandle,
                        ref interfaceGuid,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        IntPtr.Zero
                    );

                    scanResults.Add(scanResult);

                    if (scanResult == 0)
                    {
                        result.SuccessfulScanRequests++;
                        result.ScanRequested = true;
                    }

                    current = IntPtr.Add(current, infoSize);
                }

                result.InterfaceDescriptions = descriptions.ToArray();
                result.ScanResults = scanResults.ToArray();

                // WlanScan() is asynchronous. Microsoft documents that Windows-logo
                // compliant WLAN drivers should finish a requested scan within 4 seconds.
                // Waiting here intentionally avoids reading the pre-scan AutoConfig cache.
                if (result.SuccessfulScanRequests > 0 && waitMilliseconds > 0)
                {
                    Thread.Sleep(waitMilliseconds);
                }

                if (result.InterfaceCount == 0)
                {
                    result.Error = "WlanEnumInterfaces returned no enabled WLAN interfaces.";
                }
                else if (result.SuccessfulScanRequests == 0)
                {
                    result.Error = "WlanScan did not succeed on any enabled WLAN interface.";
                }

                return result;
            }
            catch (DllNotFoundException ex)
            {
                result.ApiAvailable = false;
                result.Error = ex.Message;
                return result;
            }
            catch (Exception ex)
            {
                result.Error = ex.GetType().Name + ": " + ex.Message;
                return result;
            }
            finally
            {
                if (interfaceList != IntPtr.Zero)
                {
                    WlanFreeMemory(interfaceList);
                }

                if (clientHandle != IntPtr.Zero)
                {
                    WlanCloseHandle(clientHandle, IntPtr.Zero);
                }
            }
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    }
    catch {
        throw ('Unable to initialize Native Wi-Fi WlanScan API wrapper: {0}' -f $_.Exception.Message)
    }
}

function Invoke-WindowsNativeWlanScanRefresh {
    if ((Get-PlatformName) -ne 'Windows') {
        return [pscustomobject]@{
            Status                   = 'NotWindows'
            ScanRequested            = $false
            InterfaceCount           = 0
            SuccessfulScanRequests   = 0
            InterfaceDescriptions    = @()
            ScanResults              = @()
            ErrorText                = $null
            WaitMilliseconds         = 0
        }
    }

    try {
        Initialize-WindowsNativeWlanScanApi
        $native = [DeviceCoords.NativeWlanV32]::Refresh(4250)

        $scanResults = @($native.ScanResults)

        $status = if ($native.SuccessfulScanRequests -gt 0) {
            'Success'
        }
        elseif ($scanResults -contains [uint32]5) {
            'AccessDenied'
        }
        elseif ($native.InterfaceCount -eq 0) {
            'NoWifiInterfaces'
        }
        elseif (-not $native.ApiAvailable) {
            'ApiUnavailable'
        }
        else {
            'Failed'
        }

        return [pscustomobject]@{
            Status                   = $status
            ScanRequested            = [bool]$native.ScanRequested
            InterfaceCount           = [int]$native.InterfaceCount
            SuccessfulScanRequests   = [int]$native.SuccessfulScanRequests
            InterfaceDescriptions    = @($native.InterfaceDescriptions)
            ScanResults              = $scanResults
            ErrorText                = if ([string]::IsNullOrWhiteSpace([string]$native.Error)) { $null } else { [string]$native.Error }
            WaitMilliseconds         = [int]$native.WaitMilliseconds
        }
    }
    catch {
        return [pscustomobject]@{
            Status                   = 'WrapperError'
            ScanRequested            = $false
            InterfaceCount           = 0
            SuccessfulScanRequests   = 0
            InterfaceDescriptions    = @()
            ScanResults              = @()
            ErrorText                = $_.Exception.Message
            WaitMilliseconds         = 0
        }
    }
}

function Initialize-WindowsNativeWlanBssApi {
    if ((Get-PlatformName) -ne 'Windows') {
        return
    }

    # Versioned type name prevents conflicts when an older revision of this script
    # has already loaded a different WLAN interop type into the same PowerShell host.
    if ($null -ne ('DeviceCoords.NativeWlanBssV329' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DeviceCoords
{
    public sealed class NativeWlanBssRecordV329
    {
        public string InterfaceDescription { get; set; }
        public string Bssid { get; set; }
        public string Ssid { get; set; }
        public int RssiDbm { get; set; }
        public uint LinkQuality { get; set; }
        public uint CenterFrequencyKHz { get; set; }
    }

    internal enum DOT11_BSS_TYPE_V329
    {
        Infrastructure = 1,
        Independent = 2,
        Any = 3
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WLAN_INTERFACE_INFO_V329
    {
        public Guid InterfaceGuid;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string InterfaceDescription;

        public int InterfaceState;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DOT11_SSID_V329
    {
        public uint uSSIDLength;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] ucSSID;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WLAN_RATE_SET_V329
    {
        public uint uRateSetLength;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 126)]
        public ushort[] usRateSet;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WLAN_BSS_ENTRY_V329
    {
        public DOT11_SSID_V329 dot11Ssid;
        public uint uPhyId;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] dot11Bssid;

        public DOT11_BSS_TYPE_V329 dot11BssType;
        public int dot11BssPhyType;
        public int lRssi;
        public uint uLinkQuality;
        public byte bInRegDomain;
        public ushort usBeaconPeriod;
        public ulong ullTimestamp;
        public ulong ullHostTimestamp;
        public ushort usCapabilityInformation;
        public uint ulChCenterFrequency;
        public WLAN_RATE_SET_V329 wlanRateSet;
        public uint ulIeOffset;
        public uint ulIeSize;
    }

    public static class NativeWlanBssV329
    {
        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanOpenHandle(
            uint dwClientVersion,
            IntPtr pReserved,
            out uint pdwNegotiatedVersion,
            out IntPtr phClientHandle
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanCloseHandle(
            IntPtr hClientHandle,
            IntPtr pReserved
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanEnumInterfaces(
            IntPtr hClientHandle,
            IntPtr pReserved,
            out IntPtr ppInterfaceList
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern uint WlanGetNetworkBssList(
            IntPtr hClientHandle,
            ref Guid pInterfaceGuid,
            IntPtr pDot11Ssid,
            DOT11_BSS_TYPE_V329 dot11BssType,
            bool bSecurityEnabled,
            IntPtr pReserved,
            out IntPtr ppWlanBssList
        );

        [DllImport("wlanapi.dll", SetLastError = false)]
        private static extern void WlanFreeMemory(IntPtr pMemory);

        private static string FormatBssid(byte[] value)
        {
            if (value == null || value.Length < 6)
            {
                return null;
            }

            return String.Format(
                "{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}",
                value[0], value[1], value[2],
                value[3], value[4], value[5]
            );
        }

        private static string DecodeSsid(DOT11_SSID_V329 ssid)
        {
            if (ssid.ucSSID == null || ssid.uSSIDLength == 0)
            {
                return String.Empty;
            }

            int length = (int)Math.Min(ssid.uSSIDLength, 32U);

            try
            {
                return Encoding.UTF8.GetString(ssid.ucSSID, 0, length);
            }
            catch
            {
                return Encoding.Default.GetString(ssid.ucSSID, 0, length);
            }
        }

        public static NativeWlanBssRecordV329[] ReadAll()
        {
            List<NativeWlanBssRecordV329> records =
                new List<NativeWlanBssRecordV329>();

            IntPtr clientHandle = IntPtr.Zero;
            IntPtr interfaceList = IntPtr.Zero;

            try
            {
                uint negotiatedVersion;
                uint openResult = WlanOpenHandle(
                    2,
                    IntPtr.Zero,
                    out negotiatedVersion,
                    out clientHandle
                );

                if (openResult != 0)
                {
                    return records.ToArray();
                }

                uint enumResult = WlanEnumInterfaces(
                    clientHandle,
                    IntPtr.Zero,
                    out interfaceList
                );

                if (enumResult != 0 || interfaceList == IntPtr.Zero)
                {
                    return records.ToArray();
                }

                int numberOfItems = Marshal.ReadInt32(interfaceList, 0);
                int infoSize = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO_V329));
                IntPtr currentInterface = IntPtr.Add(interfaceList, 8);

                for (int interfaceIndex = 0;
                     interfaceIndex < numberOfItems;
                     interfaceIndex++)
                {
                    WLAN_INTERFACE_INFO_V329 info =
                        (WLAN_INTERFACE_INFO_V329)Marshal.PtrToStructure(
                            currentInterface,
                            typeof(WLAN_INTERFACE_INFO_V329)
                        );

                    Guid interfaceGuid = info.InterfaceGuid;
                    IntPtr bssList = IntPtr.Zero;

                    try
                    {
                        uint bssResult = WlanGetNetworkBssList(
                            clientHandle,
                            ref interfaceGuid,
                            IntPtr.Zero,
                            DOT11_BSS_TYPE_V329.Any,
                            false,
                            IntPtr.Zero,
                            out bssList
                        );

                        if (bssResult != 0 || bssList == IntPtr.Zero)
                        {
                            continue;
                        }

                        int bssCount = Marshal.ReadInt32(bssList, 4);
                        int entrySize =
                            Marshal.SizeOf(typeof(WLAN_BSS_ENTRY_V329));
                        IntPtr currentEntry = IntPtr.Add(bssList, 8);

                        for (int bssIndex = 0;
                             bssIndex < bssCount;
                             bssIndex++)
                        {
                            WLAN_BSS_ENTRY_V329 entry =
                                (WLAN_BSS_ENTRY_V329)Marshal.PtrToStructure(
                                    currentEntry,
                                    typeof(WLAN_BSS_ENTRY_V329)
                                );

                            string bssid = FormatBssid(entry.dot11Bssid);

                            if (!String.IsNullOrWhiteSpace(bssid))
                            {
                                records.Add(
                                    new NativeWlanBssRecordV329
                                    {
                                        InterfaceDescription =
                                            info.InterfaceDescription,
                                        Bssid = bssid,
                                        Ssid = DecodeSsid(entry.dot11Ssid),
                                        RssiDbm = entry.lRssi,
                                        LinkQuality = entry.uLinkQuality,
                                        CenterFrequencyKHz =
                                            entry.ulChCenterFrequency
                                    }
                                );
                            }

                            currentEntry =
                                IntPtr.Add(currentEntry, entrySize);
                        }
                    }
                    finally
                    {
                        if (bssList != IntPtr.Zero)
                        {
                            WlanFreeMemory(bssList);
                        }
                    }

                    currentInterface =
                        IntPtr.Add(currentInterface, infoSize);
                }

                return records.ToArray();
            }
            finally
            {
                if (interfaceList != IntPtr.Zero)
                {
                    WlanFreeMemory(interfaceList);
                }

                if (clientHandle != IntPtr.Zero)
                {
                    WlanCloseHandle(clientHandle, IntPtr.Zero);
                }
            }
        }
    }
}
'@

    try {
        Add-Type `
            -TypeDefinition $source `
            -Language CSharp `
            -ErrorAction Stop
    }
    catch {
        Write-Verbose (
            'Native WLAN BSS/RSSI API initialization failed: {0}' -f
                $_.Exception.Message
        )
    }
}

function Get-WindowsNativeBssSignalMap {
    $map = @{}

    if ((Get-PlatformName) -ne 'Windows') {
        return $map
    }

    try {
        Initialize-WindowsNativeWlanBssApi

        if ($null -eq ('DeviceCoords.NativeWlanBssV329' -as [type])) {
            return $map
        }

        $nativeRows = @(
            [DeviceCoords.NativeWlanBssV329]::ReadAll()
        )

        foreach ($row in $nativeRows) {
            $bssid = ([string]$row.Bssid).ToUpperInvariant()

            if ([string]::IsNullOrWhiteSpace($bssid)) {
                continue
            }

            $rssi = [int]$row.RssiDbm

            # Real WLAN RSSI values are negative dBm. Reject zero/obviously
            # invalid values instead of fabricating a conversion from Sig%.
            if ($rssi -gt 0 -or $rssi -lt -128) {
                continue
            }

            if (-not $map.ContainsKey($bssid) -or
                $rssi -gt [int]$map[$bssid].RssiDbm) {
                $map[$bssid] = [pscustomobject]@{
                    RssiDbm           = $rssi
                    LinkQuality       = [int]$row.LinkQuality
                    CenterFrequencyKHz = [uint32]$row.CenterFrequencyKHz
                    NativeSsid        = [string]$row.Ssid
                    Interface         = [string]$row.InterfaceDescription
                }
            }
        }

        Write-Verbose (
            'Native WLAN BSS RSSI: rows={0}; uniqueBssids={1}' -f
                $nativeRows.Count,
                $map.Count
        )
    }
    catch {
        Write-Verbose (
            'Native WLAN BSS/RSSI read failed: {0}' -f
                $_.Exception.Message
        )
    }

    return $map
}


function ConvertFrom-WindowsCurrentWifiInterfaceText {
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    # Native output can occasionally contain NUL characters when captured
    # through different host/runtime combinations. Remove them before parsing.
    $cleanText = $Text -replace "`0", ''

    $records = [System.Collections.Generic.List[object]]::new()

    $interfaceMatches = [regex]::Matches(
        $cleanText,
        '(?ms)^\s*Name\s*:\s*(?<Name>[^\r\n]+)\r?\n(?<Body>.*?)(?=^\s*Name\s*:|\z)'
    )

    foreach ($interfaceMatch in $interfaceMatches) {
        $body = [string]$interfaceMatch.Groups['Body'].Value

        $stateMatch = [regex]::Match(
            $body,
            '(?mi)^\s*State\s*:\s*(?<Value>[^\r\n]+)'
        )

        if (-not $stateMatch.Success -or
            $stateMatch.Groups['Value'].Value.Trim() -notmatch '(?i)^connected$') {
            continue
        }

        $bssidMatch = [regex]::Match(
            $body,
            '(?mi)^\s*BSSID\s*:\s*(?<Value>(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2})\s*$'
        )

        if (-not $bssidMatch.Success) {
            continue
        }

        $bssid = $bssidMatch.Groups['Value'].Value.
            Replace('-', ':').
            ToUpperInvariant()

        $ssidMatch = [regex]::Match(
            $body,
            '(?mi)^\s*SSID\s*:\s*(?<Value>[^\r\n]*)'
        )

        $signalMatch = [regex]::Match(
            $body,
            '(?mi)^\s*Signal\s*:\s*(?<Value>\d{1,3})\s*%'
        )

        $channelMatch = [regex]::Match(
            $body,
            '(?mi)^\s*Channel\s*:\s*(?<Value>\d+)\s*$'
        )

        $ssid = if ($ssidMatch.Success) {
            $ssidMatch.Groups['Value'].Value.Trim()
        }
        else {
            $null
        }

        $signalPercent = if ($signalMatch.Success) {
            $candidate = [int]$signalMatch.Groups['Value'].Value
            if ($candidate -ge 0 -and $candidate -le 100) {
                $candidate
            }
            else {
                $null
            }
        }
        else {
            $null
        }

        $channel = if ($channelMatch.Success) {
            [int]$channelMatch.Groups['Value'].Value
        }
        else {
            $null
        }

        $records.Add(
            (New-WifiEvidenceRecord `
                -Bssid $bssid `
                -Ssid $ssid `
                -SignalPercent $signalPercent `
                -SignalDbm $null `
                -Channel $channel `
                -Source $Source)
        )
    }

    # Fallback for formatting variants where the "Name :" section delimiter
    # isn't parsable but the standard association fields are still present.
    if ($records.Count -eq 0) {
        $stateMatch = [regex]::Match(
            $cleanText,
            '(?mi)^\s*State\s*:\s*connected\s*$'
        )

        $bssidMatch = [regex]::Match(
            $cleanText,
            '(?mi)^\s*BSSID\s*:\s*(?<Value>(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2})\s*$'
        )

        if ($stateMatch.Success -and $bssidMatch.Success) {
            $bssid = $bssidMatch.Groups['Value'].Value.
                Replace('-', ':').
                ToUpperInvariant()

            $ssidMatch = [regex]::Match(
                $cleanText,
                '(?mi)^\s*SSID\s*:\s*(?<Value>[^\r\n]*)'
            )

            $signalMatch = [regex]::Match(
                $cleanText,
                '(?mi)^\s*Signal\s*:\s*(?<Value>\d{1,3})\s*%'
            )

            $channelMatch = [regex]::Match(
                $cleanText,
                '(?mi)^\s*Channel\s*:\s*(?<Value>\d+)\s*$'
            )

            $ssid = if ($ssidMatch.Success) {
                $ssidMatch.Groups['Value'].Value.Trim()
            }
            else {
                $null
            }

            $signalPercent = if ($signalMatch.Success) {
                [int]$signalMatch.Groups['Value'].Value
            }
            else {
                $null
            }

            $channel = if ($channelMatch.Success) {
                [int]$channelMatch.Groups['Value'].Value
            }
            else {
                $null
            }

            $records.Add(
                (New-WifiEvidenceRecord `
                    -Bssid $bssid `
                    -Ssid $ssid `
                    -SignalPercent $signalPercent `
                    -SignalDbm $null `
                    -Channel $channel `
                    -Source $Source)
            )
        }
    }

    return @(
        Merge-WifiEvidence -AccessPoints @($records)
    )
}

function Get-WindowsCurrentWifiAssociation {
    if ((Get-PlatformName) -ne 'Windows') {
        return @()
    }

    $netshPath = if ($env:SystemRoot) {
        Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
    }
    else {
        Get-CommandPath -Candidates @('netsh.exe', 'netsh')
    }

    if ([string]::IsNullOrWhiteSpace([string]$netshPath) -or
        -not (Test-Path -LiteralPath $netshPath)) {
        return @()
    }

    $records = [System.Collections.Generic.List[object]]::new()

    # Capture path 1: standard production ProcessStartInfo helper.
    try {
        $capture = Invoke-NativeCapture `
            -FilePath $netshPath `
            -ArgumentList @('wlan', 'show', 'interfaces') `
            -TimeoutSeconds 5

        $capturedText = [string]$capture.StdOut

        foreach ($record in @(
            ConvertFrom-WindowsCurrentWifiInterfaceText `
                -Text $capturedText `
                -Source 'WindowsNetshCurrentInterface'
        )) {
            $records.Add($record)
        }

        Write-Verbose ('Current Wi-Fi association ProcessStartInfo capture: exitCode={0}; chars={1}; parsed={2}' -f
            $capture.ExitCode,
            $(if ($null -eq $capturedText) { 0 } else { $capturedText.Length }),
            $records.Count)
    }
    catch {
        Write-Verbose ('Current Wi-Fi association ProcessStartInfo capture failed: {0}' -f
            $_.Exception.Message)
    }

    # Capture path 2: mirror the exact command that succeeds interactively.
    if ($records.Count -eq 0) {
        try {
            $directLines = @(
                & $netshPath wlan show interfaces 2>&1
            )

            $directText = @(
                $directLines |
                    ForEach-Object {
                        [string]$_
                    }
            ) -join [Environment]::NewLine

            foreach ($record in @(
                ConvertFrom-WindowsCurrentWifiInterfaceText `
                    -Text $directText `
                    -Source 'WindowsNetshCurrentInterfaceDirect'
            )) {
                $records.Add($record)
            }

            Write-Verbose ('Current Wi-Fi association direct capture: chars={0}; parsed={1}' -f
                $(if ($null -eq $directText) { 0 } else { $directText.Length }),
                $records.Count)
        }
        catch {
            Write-Verbose ('Current Wi-Fi association direct capture failed: {0}' -f
                $_.Exception.Message)
        }
    }

    $merged = @(
        Merge-WifiEvidence -AccessPoints @($records)
    )

    foreach ($ap in $merged) {
        Write-Verbose ('Current Wi-Fi association recovered: source={0}; SSID={1}; BSSID={2}; signalPct={3}; channel={4}; googleUsable={5}; eligibility={6}' -f
            $ap.Source,
            $(if ([string]::IsNullOrWhiteSpace([string]$ap.SSID)) { '<hidden>' } else { $ap.SSID }),
            $ap.BSSID,
            $(if ($null -eq $ap.SignalPercent) { '<none>' } else { $ap.SignalPercent }),
            $(if ($null -eq $ap.Channel) { '<none>' } else { $ap.Channel }),
            $ap.GoogleUsable,
            $ap.GoogleEligibility)
    }

    return $merged
}

function Get-WindowsNearbyWifiAccessPoint {
    # Force the same class of WLAN refresh that opening the Windows Available Wi-Fi
    # UI triggers. WlanScan is the supported Win32 request for a fresh nearby-network
    # scan. We deliberately wait for the documented four-second completion window
    # before asking netsh to render the refreshed AutoConfig BSS cache.
    $nativeRefresh = Invoke-WindowsNativeWlanScanRefresh
    $nativeBssSignalMap = Get-WindowsNativeBssSignalMap
    $currentAssociations = @(Get-WindowsCurrentWifiAssociation)

    $netshPath = if ($env:SystemRoot) {
        Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
    }
    else {
        Get-CommandPath -Candidates @('netsh.exe', 'netsh')
    }

    if ([string]::IsNullOrWhiteSpace($netshPath) -or -not (Test-Path -LiteralPath $netshPath)) {
        return [pscustomobject]@{
            Status       = 'CollectorUnavailable'
            ExitCode     = -1
            ErrorText    = 'netsh.exe was not found.'
            Collector                  = 'WindowsNativeWlanScan+Netsh'
            RefreshMethod              = if ($nativeRefresh.Status -eq 'Success') { 'WlanScan' } else { 'NetshCacheFallback' }
            NativeScanStatus           = $nativeRefresh.Status
            NativeScanInterfaceCount   = $nativeRefresh.InterfaceCount
            NativeScanSuccessfulCount  = $nativeRefresh.SuccessfulScanRequests
            NativeScanInterfaces       = @($nativeRefresh.InterfaceDescriptions)
            NativeScanResults          = @($nativeRefresh.ScanResults)
            NativeScanError            = $nativeRefresh.ErrorText
            NativeScanWaitMilliseconds = $nativeRefresh.WaitMilliseconds
            ScanAttempts               = 0
            RawBssidCount              = 0
            AccessPoints               = @()
        }
    }

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($currentAssociation in $currentAssociations) {
        $records.Add($currentAssociation)
    }

    $scanTexts = [System.Collections.Generic.List[string]]::new()
    $scanErrors = [System.Collections.Generic.List[string]]::new()
    $lastExitCode = 0
    $attemptsUsed = 0
    $scanBssidRecordCount = 0
    $permissionDenied = $false
    $rawBssids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($currentAssociation in $currentAssociations) {
        if (-not [string]::IsNullOrWhiteSpace([string]$currentAssociation.BSSID)) {
            $null = $rawBssids.Add([string]$currentAssociation.BSSID)
        }
    }

    # WlanScan above is the refresh operation. netsh is now only the first test reader
    # for the refreshed WLAN AutoConfig cache. If that rendered cache is still very small,
    # take two additional reads and union them to tolerate transient publication delays.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $attemptsUsed = $attempt

        $scan = Invoke-NativeCapture `
            -FilePath $netshPath `
            -ArgumentList @('wlan', 'show', 'networks', 'mode=bssid') `
            -TimeoutSeconds 6

        $lastExitCode = $scan.ExitCode
        $snapshotText = [string]$scan.StdOut

        if (-not [string]::IsNullOrWhiteSpace($snapshotText)) {
            $scanTexts.Add($snapshotText)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$scan.StdErr)) {
            $scanErrors.Add(([string]$scan.StdErr).Trim())
        }

        $permissionDenied = (
            $permissionDenied -or
            $snapshotText -match '(?i)location permission|location services|access is denied|permission' -or
            [string]$scan.StdErr -match '(?i)location permission|location services|access is denied|permission'
        )

        if (-not [string]::IsNullOrWhiteSpace($snapshotText)) {
            $lines = @($snapshotText -split "`r?`n")
            $currentSsid = $null

            for ($index = 0; $index -lt $lines.Count; $index++) {
                $line = [string]$lines[$index]

                if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*)$' -and $line -notmatch '^\s*BSSID') {
                    $currentSsid = $Matches[1].Trim()
                    continue
                }

                $macMatches = [regex]::Matches(
                    $line,
                    '(?i)(?<![0-9A-F])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F])'
                )

                foreach ($macMatch in $macMatches) {
                    $normalizedBssid = $macMatch.Value.Replace('-', ':').ToUpperInvariant()
                    $null = $rawBssids.Add($normalizedBssid)

                    $signalPercent = $null
                    $channel = $null

                    for ($lookAhead = $index + 1; $lookAhead -lt $lines.Count; $lookAhead++) {
                        $nextLine = [string]$lines[$lookAhead]

                        if ([regex]::IsMatch(
                            $nextLine,
                            '(?i)(?<![0-9A-F])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F])'
                        )) {
                            break
                        }

                        if ($nextLine -match '^\s*SSID\s+\d+\s*:') {
                            break
                        }

                        if ($null -eq $signalPercent -and $nextLine -match '(\d{1,3})\s*%') {
                            $candidate = [int]$Matches[1]
                            if ($candidate -ge 0 -and $candidate -le 100) {
                                $signalPercent = $candidate
                            }
                        }

                        if ($null -eq $channel -and $nextLine -match '(?i)^\s*Channel\s*:\s*(\d+)') {
                            $channel = [int]$Matches[1]
                        }
                    }

                    $nativeSignal = if (
                        $nativeBssSignalMap.ContainsKey($normalizedBssid)
                    ) {
                        $nativeBssSignalMap[$normalizedBssid]
                    }
                    else {
                        $null
                    }

                    $signalDbm = if ($null -ne $nativeSignal) {
                        [int]$nativeSignal.RssiDbm
                    }
                    else {
                        $null
                    }

                    $scanBssidRecordCount++

                    $records.Add(
                        (New-WifiEvidenceRecord `
                            -Bssid $normalizedBssid `
                            -Ssid $currentSsid `
                            -SignalPercent $signalPercent `
                            -SignalDbm $signalDbm `
                            -Channel $channel `
                            -Source $(if ($null -ne $nativeSignal) {
                                          'WindowsNetsh+NativeBss'
                                      }
                                      else {
                                          'WindowsNetsh'
                                      }))
                    )
                }
            }
        }

        $mergedSoFar = @(Merge-WifiEvidence -AccessPoints @($records))

        if ($permissionDenied -or $mergedSoFar.Count -ge 2 -or $scan.ExitCode -ne 0) {
            break
        }

        if ($attempt -lt 3) {
            Start-Sleep -Milliseconds 350
        }
    }

    $merged = @(Merge-WifiEvidence -AccessPoints @($records))
    $combinedText = ($scanTexts -join [Environment]::NewLine)

    $status = if ($scanBssidRecordCount -gt 0) {
        'Success'
    }
    elseif ($currentAssociations.Count -gt 0 -and
            (
                $nativeRefresh.Status -eq 'AccessDenied' -or
                $combinedText -match '(?i)location permission|location services|access is denied|permission'
            )) {
        'CurrentAssociationFallback'
    }
    elseif ($currentAssociations.Count -gt 0) {
        'CurrentAssociationOnly'
    }
    elseif ($combinedText -match '(?i)location permission|location services|access is denied|permission') {
        'BlockedByLocationPermission'
    }
    elseif ($lastExitCode -ne 0) {
        'CollectorError'
    }
    else {
        'NoBssidsParsed'
    }

    return [pscustomobject]@{
        Status        = $status
        ExitCode      = $lastExitCode
        ErrorText     = if ($scanErrors.Count -gt 0) {
                            (($scanErrors | Select-Object -Unique) -join ' | ')
                        }
                        else {
                            $null
                        }
        Collector                  = 'WindowsNativeWlanScan+Netsh'
        RefreshMethod              = if ($nativeRefresh.Status -eq 'Success') { 'WlanScan' } else { 'NetshCacheFallback' }
        NativeScanStatus           = $nativeRefresh.Status
        NativeScanInterfaceCount   = $nativeRefresh.InterfaceCount
        NativeScanSuccessfulCount  = $nativeRefresh.SuccessfulScanRequests
        NativeScanInterfaces       = @($nativeRefresh.InterfaceDescriptions)
        NativeScanResults          = @($nativeRefresh.ScanResults)
        NativeScanError            = $nativeRefresh.ErrorText
        NativeScanWaitMilliseconds = $nativeRefresh.WaitMilliseconds
        NativeBssRssiCount         = $nativeBssSignalMap.Count
        CurrentAssociationCount    = $currentAssociations.Count
        ScanBssidRecordCount       = $scanBssidRecordCount
        ScanAttempts               = $attemptsUsed
        RawBssidCount              = $rawBssids.Count
        AccessPoints               = $merged
    }
}

function Get-LinuxNearbyWifiAccessPoint {
    $nmcli = Get-CommandPath -Candidates @('nmcli')

    if ([string]::IsNullOrWhiteSpace($nmcli)) {
        return [pscustomobject]@{
            Status       = 'CollectorUnavailable'
            ExitCode     = -1
            ErrorText    = 'nmcli was not found. NetworkManager is required for the primary Linux Wi-Fi collector.'
            Collector     = 'LinuxNetworkManager'
            ScanAttempts  = 0
            RawBssidCount = 0
            AccessPoints  = @()
        }
    }

    # Terse output escapes ':' in the BSSID, which makes the record unambiguous:
    # AA\:BB\:CC\:DD\:EE\:FF:82:44:SSID
    $scan = Invoke-NativeCapture `
        -FilePath $nmcli `
        -ArgumentList @('-t', '-f', 'BSSID,SIGNAL,CHAN,SSID', 'device', 'wifi', 'list', '--rescan', 'yes') `
        -TimeoutSeconds 8 `
        -Environment @{ LC_ALL = 'C'; LANG = 'C' }

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($line in @([string]$scan.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^(?<bssid>(?:[0-9A-Fa-f]{2}\\:){5}[0-9A-Fa-f]{2}):(?<signal>\d{1,3}):(?<channel>\d+):(?<ssid>.*)$') {
            $bssid = $Matches.bssid.Replace('\:', ':')
            $signal = [int]$Matches.signal
            $channel = [int]$Matches.channel
            $ssid = $Matches.ssid.Replace('\:', ':').Replace('\\', '\')

            $records.Add(
                (New-WifiEvidenceRecord `
                    -Bssid $bssid `
                    -Ssid $ssid `
                    -SignalPercent $signal `
                    -SignalDbm $null `
                    -Channel $channel `
                    -Source 'LinuxNetworkManager')
            )
        }
    }

    $merged = @(Merge-WifiEvidence -AccessPoints @($records))

    $status = if ($merged.Count -gt 0) {
        'Success'
    }
    elseif ($scan.ExitCode -ne 0) {
        'CollectorError'
    }
    else {
        'NoBssidsParsed'
    }

    return [pscustomobject]@{
        Status       = $status
        ExitCode     = $scan.ExitCode
        ErrorText    = if ([string]::IsNullOrWhiteSpace([string]$scan.StdErr)) { $null } else { $scan.StdErr.Trim() }
        Collector     = 'LinuxNetworkManager'
        ScanAttempts  = 1
        RawBssidCount = $merged.Count
        AccessPoints  = $merged
    }
}

function Get-MacNearbyWifiAccessPointViaCoreWlan {
    $osascript = Get-CommandPath -Candidates @('/usr/bin/osascript', 'osascript')

    if ([string]::IsNullOrWhiteSpace($osascript)) {
        return [pscustomobject]@{
            Status       = 'CollectorUnavailable'
            ExitCode     = -1
            ErrorText    = 'osascript was not found.'
            Collector     = 'MacCoreWLAN'
            ScanAttempts  = 0
            RawBssidCount = 0
            AccessPoints  = @()
        }
    }

    $jxa = @'
ObjC.import('CoreWLAN');
ObjC.import('Foundation');

function unwrapString(value) {
    try {
        if (!value) return null;
        var s = ObjC.unwrap(value);
        if (s === undefined || s === null) return null;
        return String(s);
    } catch (e) {
        return null;
    }
}

var client = $.CWWiFiClient.sharedWiFiClient;
var iface = client.interface;
if (!iface) {
    JSON.stringify({ error: 'No Wi-Fi interface returned by CoreWLAN.', networks: [] });
} else {
    var err = Ref();
    var set = iface.scanForNetworksWithNameError(null, err);
    var result = [];

    if (set) {
        var array = set.allObjects;
        var count = Number(array.count);

        for (var i = 0; i < count; i++) {
            var network = array.objectAtIndex(i);
            var wlanChannel = network.wlanChannel;

            result.push({
                ssid: unwrapString(network.ssid),
                bssid: unwrapString(network.bssid),
                rssi: Number(network.rssiValue),
                channel: wlanChannel ? Number(wlanChannel.channelNumber) : null
            });
        }
    }

    JSON.stringify({
        error: err[0] ? unwrapString(err[0].localizedDescription) : null,
        networks: result
    });
}
'@

    $tempJs = Join-Path ([IO.Path]::GetTempPath()) ('Get-DeviceCoords-CoreWLAN-{0}.js' -f [guid]::NewGuid().ToString('N'))

    try {
        [IO.File]::WriteAllText($tempJs, $jxa, [Text.UTF8Encoding]::new($false))

        $scan = Invoke-NativeCapture `
            -FilePath $osascript `
            -ArgumentList @('-l', 'JavaScript', $tempJs) `
            -TimeoutSeconds 10

        $records = [System.Collections.Generic.List[object]]::new()
        $errorText = $null

        if (-not [string]::IsNullOrWhiteSpace([string]$scan.StdOut)) {
            try {
                $payload = ([string]$scan.StdOut).Trim() | ConvertFrom-Json

                if ($payload.PSObject.Properties.Name -contains 'error' -and
                    -not [string]::IsNullOrWhiteSpace([string]$payload.error)) {
                    $errorText = [string]$payload.error
                }

                foreach ($network in @($payload.networks)) {
                    if ([string]::IsNullOrWhiteSpace([string]$network.bssid) -or
                        [string]$network.bssid -eq '<redacted>') {
                        continue
                    }

                    $signalDbm = $null
                    if ($null -ne $network.rssi) {
                        $candidateDbm = [int]$network.rssi
                        if ($candidateDbm -le 0 -and $candidateDbm -ge -128) {
                            $signalDbm = $candidateDbm
                        }
                    }

                    $channel = if ($null -ne $network.channel) { [int]$network.channel } else { $null }

                    $records.Add(
                        (New-WifiEvidenceRecord `
                            -Bssid ([string]$network.bssid) `
                            -Ssid ([string]$network.ssid) `
                            -SignalPercent $null `
                            -SignalDbm $signalDbm `
                            -Channel $channel `
                            -Source 'MacCoreWLAN')
                    )
                }
            }
            catch {
                $errorText = 'CoreWLAN output could not be parsed: {0}' -f $_.Exception.Message
            }
        }

        $merged = @(Merge-WifiEvidence -AccessPoints @($records))

        $status = if ($merged.Count -gt 0) {
            'Success'
        }
        elseif ($scan.ExitCode -ne 0) {
            'CollectorError'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($errorText)) {
            'BlockedOrUnavailable'
        }
        else {
            'NoBssidsParsed'
        }

        return [pscustomobject]@{
            Status       = $status
            ExitCode     = $scan.ExitCode
            ErrorText    = if (-not [string]::IsNullOrWhiteSpace($errorText)) {
                                $errorText
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace([string]$scan.StdErr)) {
                                $scan.StdErr.Trim()
                            }
                            else {
                                $null
                            }
            Collector     = 'MacCoreWLAN'
            ScanAttempts  = 1
            RawBssidCount = $merged.Count
            AccessPoints  = $merged
        }
    }
    finally {
        Remove-Item -LiteralPath $tempJs -Force -ErrorAction SilentlyContinue
    }
}

function Get-MacNearbyWifiAccessPointViaAirport {
    $airport = Get-CommandPath -Candidates @(
        '/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport',
        '/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport'
    )

    if ([string]::IsNullOrWhiteSpace($airport)) {
        return [pscustomobject]@{
            Status       = 'CollectorUnavailable'
            ExitCode     = -1
            ErrorText    = 'Legacy airport utility was not found.'
            Collector     = 'MacAirportLegacy'
            ScanAttempts  = 0
            RawBssidCount = 0
            AccessPoints  = @()
        }
    }

    $scan = Invoke-NativeCapture -FilePath $airport -ArgumentList @('-s') -TimeoutSeconds 8
    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($line in @([string]$scan.StdOut -split "`r?`n")) {
        $macMatch = [regex]::Match(
            [string]$line,
            '(?i)(?<![0-9A-F])(?:[0-9A-F]{2}:){5}[0-9A-F]{2}(?![0-9A-F])'
        )

        if (-not $macMatch.Success) { continue }

        $ssid = ([string]$line.Substring(0, $macMatch.Index)).Trim()
        $remainder = ([string]$line.Substring($macMatch.Index + $macMatch.Length)).Trim()
        $parts = @($remainder -split '\s+')

        $rssi = $null
        $channel = $null

        if ($parts.Count -ge 1 -and $parts[0] -match '^-?\d+$') {
            $rssi = [int]$parts[0]
        }

        if ($parts.Count -ge 2 -and $parts[1] -match '^(\d+)') {
            $channel = [int]$Matches[1]
        }

        $records.Add(
            (New-WifiEvidenceRecord `
                -Bssid $macMatch.Value `
                -Ssid $ssid `
                -SignalPercent $null `
                -SignalDbm $rssi `
                -Channel $channel `
                -Source 'MacAirportLegacy')
        )
    }

    $merged = @(Merge-WifiEvidence -AccessPoints @($records))

    return [pscustomobject]@{
        Status       = if ($merged.Count -gt 0) { 'Success' } elseif ($scan.ExitCode -ne 0) { 'CollectorError' } else { 'NoBssidsParsed' }
        ExitCode     = $scan.ExitCode
        ErrorText    = if ([string]::IsNullOrWhiteSpace([string]$scan.StdErr)) { $null } else { $scan.StdErr.Trim() }
        Collector     = 'MacAirportLegacy'
        ScanAttempts  = 1
        RawBssidCount = $merged.Count
        AccessPoints  = $merged
    }
}

function Get-MacNearbyWifiAccessPoint {
    $coreWlan = Get-MacNearbyWifiAccessPointViaCoreWlan

    if (@($coreWlan.AccessPoints).Count -gt 0) {
        return $coreWlan
    }

    $legacy = Get-MacNearbyWifiAccessPointViaAirport

    if (@($legacy.AccessPoints).Count -gt 0) {
        return $legacy
    }

    return [pscustomobject]@{
        Status       = if ($coreWlan.Status -eq 'BlockedOrUnavailable') { 'BlockedOrUnavailable' } else { $legacy.Status }
        ExitCode     = if ($coreWlan.ExitCode -ne 0) { $coreWlan.ExitCode } else { $legacy.ExitCode }
        ErrorText    = (@($coreWlan.ErrorText, $legacy.ErrorText) |
                            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                            Select-Object -Unique) -join ' | '
        Collector     = 'MacCoreWLAN+LegacyFallback'
        ScanAttempts  = 1
        RawBssidCount = 0
        AccessPoints  = @()
    }
}

function Get-NearbyWifiAccessPoint {
    $platform = Get-PlatformName

    switch ($platform) {
        'Windows' { return Get-WindowsNearbyWifiAccessPoint }
        'Linux'   { return Get-LinuxNearbyWifiAccessPoint }
        'macOS'   { return Get-MacNearbyWifiAccessPoint }
        default {
            return [pscustomobject]@{
                Status       = 'UnsupportedPlatform'
                ExitCode     = -1
                ErrorText    = ('Unsupported platform [{0}].' -f $platform)
                Collector     = 'None'
                ScanAttempts  = 0
                RawBssidCount = 0
                AccessPoints  = @()
            }
        }
    }
}

function Get-StrongestGoogleUsableWifiAccessPoint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AccessPoints)

    return @(
        $AccessPoints |
            Where-Object GoogleUsable |
            Sort-Object -Property @{ Expression = { Get-WifiSortScore -AccessPoint $_ }; Descending = $true },
                                  @{ Expression = { [string]$_.BSSID }; Descending = $false }
    ) | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Wi-Fi location resolvers shared across platforms
# ---------------------------------------------------------------------------

function Get-KnownWifiLocation {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AccessPoints,
        [Parameter(Mandatory)][string]$Path
    )

    if ($AccessPoints.Count -eq 0) { return $null }

    try {
        $map = Import-Csv -LiteralPath $Path
        if ($null -eq $map) { return $null }

        $visible = @{}

        foreach ($ap in $AccessPoints) {
            $visible[$ap.BSSID.ToUpperInvariant()] = $ap
        }

        $matches = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $map) {
            if ($null -eq $row.BSSID) { continue }

            $bssid = ([string]$row.BSSID).Trim().Replace('-', ':').ToUpperInvariant()

            if ($visible.ContainsKey($bssid)) {
                $matches.Add([pscustomobject]@{
                    Row         = $row
                    AccessPoint = $visible[$bssid]
                })
            }
        }

        if ($matches.Count -eq 0) { return $null }

        # Prefer the site with the greatest number of visible mapped APs. Within that site,
        # use the strongest visible mapped BSSID as the anchor.
        $winningSiteName = $matches |
            Group-Object -Property { [string]$_.Row.Site } |
            Sort-Object Count -Descending |
            Select-Object -First 1 |
            Select-Object -ExpandProperty Name

        $siteMatches = @($matches | Where-Object { [string]$_.Row.Site -eq $winningSiteName })

        $selectedMatch = $siteMatches |
            Sort-Object -Property @{ Expression = { Get-WifiSortScore -AccessPoint $_.AccessPoint }; Descending = $true } |
            Select-Object -First 1

        $selected = $selectedMatch.Row
        $latitude = 0.0
        $longitude = 0.0

        if (-not [double]::TryParse([string]$selected.Latitude, [ref]$latitude) -or
            -not [double]::TryParse([string]$selected.Longitude, [ref]$longitude)) {
            return $null
        }

        $accuracy = 50.0

        if ($selected.PSObject.Properties.Name -contains 'AccuracyMeters') {
            $parsedAccuracy = 0.0

            if ([double]::TryParse([string]$selected.AccuracyMeters, [ref]$parsedAccuracy) -and
                $parsedAccuracy -gt 0) {
                $accuracy = $parsedAccuracy
            }
        }

        return [pscustomobject]@{
            Method              = 'KnownWiFi'
            Latitude            = $latitude
            Longitude           = $longitude
            AccuracyMeters      = $accuracy
            Site                = [string]$selected.Site
            VpnResistant        = $true
            AnchorBssid         = [string]$selectedMatch.AccessPoint.BSSID
            AnchorSsid          = [string]$selectedMatch.AccessPoint.SSID
            AnchorSignalPercent = $selectedMatch.AccessPoint.SignalPercent
            AnchorSignalDbm     = $selectedMatch.AccessPoint.SignalDbm
            Detail              = ('Matched {0} known Wi-Fi BSSID(s) at site [{1}]; strongest mapped anchor [{2}]' -f
                                      $siteMatches.Count, [string]$selected.Site, [string]$selectedMatch.AccessPoint.BSSID)
        }
    }
    catch {
        Write-Verbose ('Known Wi-Fi lookup failed: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-HttpErrorResponseDetail {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = $null
    $bodyText = $null
    $reason = $null
    $message = $null

    try {
        if ($null -ne $ErrorRecord.Exception.Response) {
            $response = $ErrorRecord.Exception.Response

            try {
                if ($null -ne $response.StatusCode) {
                    $statusCode = [int]$response.StatusCode
                }
            }
            catch { }

            # PowerShell 7 / HttpResponseMessage
            try {
                if ($null -ne $response.Content) {
                    $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
            }
            catch { }

            # Windows PowerShell 5.1 / WebResponse
            if ([string]::IsNullOrWhiteSpace([string]$bodyText)) {
                try {
                    $stream = $response.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        try {
                            $bodyText = $reader.ReadToEnd()
                        }
                        finally {
                            $reader.Dispose()
                            $stream.Dispose()
                        }
                    }
                }
                catch { }
            }
        }
    }
    catch { }

    # PowerShell often places the HTTP response body here even when Response.Content
    # is unavailable.
    if ([string]::IsNullOrWhiteSpace([string]$bodyText)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
                $bodyText = [string]$ErrorRecord.ErrorDetails.Message
            }
        }
        catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$bodyText)) {
        try {
            $parsed = $bodyText | ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $parsed.error) {
                if (-not [string]::IsNullOrWhiteSpace([string]$parsed.error.message)) {
                    $message = [string]$parsed.error.message
                }

                if ($null -ne $parsed.error.errors) {
                    $firstReason = @($parsed.error.errors) | Select-Object -First 1
                    if ($null -ne $firstReason -and
                        -not [string]::IsNullOrWhiteSpace([string]$firstReason.reason)) {
                        $reason = [string]$firstReason.reason
                    }
                }

                # Newer Google APIs sometimes expose status rather than errors[].reason.
                if ([string]::IsNullOrWhiteSpace([string]$reason) -and
                    -not [string]::IsNullOrWhiteSpace([string]$parsed.error.status)) {
                    $reason = [string]$parsed.error.status
                }
            }
        }
        catch { }
    }

    if ([string]::IsNullOrWhiteSpace([string]$message)) {
        $message = [string]$ErrorRecord.Exception.Message
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Reason     = $reason
        Message    = $message
        Body       = $bodyText
    }
}

function Get-GoogleWifiLocation {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AccessPoints,
        [Parameter(Mandatory)][string]$ApiKey
    )

    $usable = @(
        $AccessPoints |
            Where-Object GoogleUsable |
            Sort-Object -Property @{ Expression = { Get-WifiSortScore -AccessPoint $_ }; Descending = $true }
    )

    if ($usable.Count -lt 2) { return $null }

    $wifi = @(
        $usable |
            Select-Object -First 30 |
            ForEach-Object {
                $entry = @{
                    macAddress = $_.BSSID.ToLowerInvariant()
                }

                if ($null -ne $_.SignalDbm) {
                    $entry.signalStrength = [double]$_.SignalDbm
                }

                if ($null -ne $_.Channel) {
                    $entry.channel = [int]$_.Channel
                }

                $entry
            }
    )

    $body = @{
        considerIp       = $false
        wifiAccessPoints = $wifi
    } | ConvertTo-Json -Depth 5 -Compress

    $script:GoogleWifiLastHttpStatus = $null
    $script:GoogleWifiLastErrorReason = $null
    $script:GoogleWifiLastErrorMessage = $null

    try {
        $uri = 'https://www.googleapis.com/geolocation/v1/geolocate?key={0}' -f [uri]::EscapeDataString($ApiKey)

        # Suppress verbose request output so the API key in the query string is not echoed
        # into normal interactive/automation verbose logs.
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $uri `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 6 `
            -ErrorAction Stop `
            -Verbose:$false

        if ($null -eq $response.location) { return $null }

        $anchor = $usable | Select-Object -First 1

        return [pscustomobject]@{
            Method                    = 'GoogleWiFi'
            Latitude                  = [double]$response.location.lat
            Longitude                 = [double]$response.location.lng
            AccuracyMeters            = [double]$response.accuracy
            Site                      = $null
            VpnResistant              = $true
            GoogleAccessPointsUsed    = $wifi.Count
            AnchorBssid               = [string]$anchor.BSSID
            AnchorSsid                = [string]$anchor.SSID
            AnchorSignalPercent       = $anchor.SignalPercent
            AnchorSignalDbm           = $anchor.SignalDbm
            Detail                    = ('Geolocated from {0} nearby universally administered Wi-Fi BSSID(s); strongest usable anchor [{1}]; IP fallback disabled' -f
                                           $wifi.Count, $anchor.BSSID)
        }
    }
    catch {
        $httpDetail = Get-HttpErrorResponseDetail -ErrorRecord $_

        $script:GoogleWifiLastHttpStatus = $httpDetail.StatusCode
        $script:GoogleWifiLastErrorReason = $httpDetail.Reason
        $script:GoogleWifiLastErrorMessage = $httpDetail.Message

        Write-Verbose ('Google Wi-Fi geolocation failed: httpStatus={0}; reason={1}; message={2}' -f
            $(if ($null -eq $httpDetail.StatusCode) { '<unknown>' } else { $httpDetail.StatusCode }),
            $(if ([string]::IsNullOrWhiteSpace([string]$httpDetail.Reason)) { '<unknown>' } else { $httpDetail.Reason }),
            $(if ([string]::IsNullOrWhiteSpace([string]$httpDetail.Message)) { $_.Exception.Message } else { $httpDetail.Message }))

        return $null
    }
}


# ---------------------------------------------------------------------------
# WiGLE exact-BSSID fallback
# ---------------------------------------------------------------------------

function Get-DeviceCoordsCacheBasePath {
    $basePath = $null

    switch (Get-PlatformName) {
        'Windows' {
            if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
                $basePath = [string]$env:LOCALAPPDATA
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
                $basePath = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Local'
            }
        }

        'Linux' {
            if (-not [string]::IsNullOrWhiteSpace([string]$env:XDG_CACHE_HOME)) {
                $basePath = [string]$env:XDG_CACHE_HOME
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$HOME)) {
                $basePath = Join-Path -Path $HOME -ChildPath '.cache'
            }
        }

        'macOS' {
            if (-not [string]::IsNullOrWhiteSpace([string]$HOME)) {
                $basePath = Join-Path -Path $HOME -ChildPath 'Library/Caches'
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$basePath)) {
        return $null
    }

    return Join-Path -Path $basePath -ChildPath 'Get-DeviceCoords'
}

function Get-WigleCachePath {
    $basePath = Get-DeviceCoordsCacheBasePath

    if ([string]::IsNullOrWhiteSpace([string]$basePath)) {
        return $null
    }

    return Join-Path -Path $basePath -ChildPath 'wigle-bssid-cache.json'
}

function Read-WigleBssidCache {
    $path = Get-WigleCachePath
    $cache = @{}

    if ([string]::IsNullOrWhiteSpace([string]$path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $cache
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return $cache
        }

        foreach ($entry in @($raw | ConvertFrom-Json -ErrorAction Stop)) {
            $bssid = Normalize-Bssid -Bssid ([string]$entry.BSSID)

            if ($null -eq $bssid) {
                continue
            }

            $cache[$bssid] = [pscustomobject]@{
                BSSID      = $bssid
                Found      = [bool]$entry.Found
                Latitude   = $entry.Latitude
                Longitude  = $entry.Longitude
                SSID       = [string]$entry.SSID
                LastUpdate = [string]$entry.LastUpdate
                CheckedUtc = [string]$entry.CheckedUtc
            }
        }
    }
    catch {
        Write-Verbose ('WiGLE cache read failed [{0}]: {1}' -f
            $path,
            $_.Exception.Message)
    }

    return $cache
}

function Test-WigleCacheEntryFresh {
    param(
        [AllowNull()]
        [object]$Entry
    )

    if ($null -eq $Entry -or
        [string]::IsNullOrWhiteSpace([string]$Entry.CheckedUtc)) {
        return $false
    }

    try {
        $checkedUtc = [datetime]::Parse(
            [string]$Entry.CheckedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    }
    catch {
        return $false
    }

    # Positive BSSID locations are expensive to reacquire and usually stable.
    # Misses are retried more frequently because WiGLE's crowdsourced database grows.
    $ttlDays = if ([bool]$Entry.Found) { 180 } else { 14 }

    return (((Get-Date).ToUniversalTime() - $checkedUtc).TotalDays -lt $ttlDays)
}

function Write-WigleBssidCache {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $path = Get-WigleCachePath

    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return
    }

    try {
        $directory = Split-Path -Path $path -Parent

        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item `
                -ItemType Directory `
                -Path $directory `
                -Force `
                -ErrorAction Stop)
        }

        $entries = @(
            foreach ($key in @($Cache.Keys | Sort-Object)) {
                $entry = $Cache[$key]

                [pscustomobject][ordered]@{
                    BSSID      = [string]$entry.BSSID
                    Found      = [bool]$entry.Found
                    Latitude   = $entry.Latitude
                    Longitude  = $entry.Longitude
                    SSID       = [string]$entry.SSID
                    LastUpdate = [string]$entry.LastUpdate
                    CheckedUtc = [string]$entry.CheckedUtc
                }
            }
        )

        $tempPath = '{0}.{1}.tmp' -f $path, [Guid]::NewGuid().ToString('N')

        $entries |
            ConvertTo-Json -Depth 4 |
            Set-Content `
                -LiteralPath $tempPath `
                -Encoding UTF8 `
                -Force `
                -ErrorAction Stop

        Move-Item `
            -LiteralPath $tempPath `
            -Destination $path `
            -Force `
            -ErrorAction Stop
    }
    catch {
        Write-Verbose ('WiGLE cache write failed [{0}]: {1}' -f
            $path,
            $_.Exception.Message)
    }
}

function Get-WigleHeaderValue {
    param(
        [AllowNull()]
        [object]$Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    try {
        foreach ($key in @($Headers.Keys)) {
            if ([string]$key -ieq $Name) {
                return [string]$Headers[$key]
            }
        }
    }
    catch { }

    return $null
}

function Invoke-WigleBssidLookup {
    param(
        [Parameter(Mandatory)]
        [string]$Bssid,

        [Parameter(Mandatory)]
        [string]$ApiName,

        [Parameter(Mandatory)]
        [string]$ApiToken
    )

    $script:WigleLastHttpStatus = $null
    $script:WigleLastErrorMessage = $null
    $script:WigleLastErrorBody = $null

    if ($script:WigleRateLimited -or $script:WigleTerminalFailure) {
        return $null
    }

    $normalized = Normalize-Bssid -Bssid $Bssid

    if ($null -eq $normalized) {
        return $null
    }

    $credentialText = [string]::Concat(
        [string]$ApiName,
        ':',
        [string]$ApiToken
    )

    $credentialBytes = [Text.Encoding]::ASCII.GetBytes($credentialText)
    $basic = [Convert]::ToBase64String($credentialBytes)

    $uri = 'https://api.wigle.net/api/v2/network/search?onlymine=false&resultsPerPage=1&netid={0}' -f
        [Uri]::EscapeDataString($normalized)

    $headers = @{
        Accept        = 'application/json'
        Authorization = 'Basic {0}' -f $basic
    }

    try {
        $request = @{
            Uri         = $uri
            Method      = 'Get'
            Headers     = $headers
            TimeoutSec  = 8
            ErrorAction = 'Stop'
            Verbose     = $false
        }

        if ($PSVersionTable.PSVersion.Major -le 5) {
            $request.UseBasicParsing = $true
        }

        $response = Invoke-WebRequest @request
        $script:WigleLiveQueriesUsed++

        if ($response.PSObject.Properties.Name -contains 'StatusCode') {
            $script:WigleLastHttpStatus = [int]$response.StatusCode
        }

        $script:WigleRateLimitRemaining = Get-WigleHeaderValue `
            -Headers $response.Headers `
            -Name 'X-RateLimit-Remaining'

        $script:WigleRateLimitLimit = Get-WigleHeaderValue `
            -Headers $response.Headers `
            -Name 'X-RateLimit-Limit'

        $script:WigleRateLimitReset = Get-WigleHeaderValue `
            -Headers $response.Headers `
            -Name 'X-RateLimit-Reset'

        Write-Verbose ('WiGLE BSSID lookup: bssid={0}; http={1}; rateRemaining={2}; rateLimit={3}; rateReset={4}' -f
            $normalized,
            $(if ($null -eq $script:WigleLastHttpStatus) { '<unknown>' } else { $script:WigleLastHttpStatus }),
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitRemaining)) { '<not-supplied>' } else { $script:WigleRateLimitRemaining }),
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitLimit)) { '<not-supplied>' } else { $script:WigleRateLimitLimit }),
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitReset)) { '<not-supplied>' } else { $script:WigleRateLimitReset }))

        $payload = [string]$response.Content | ConvertFrom-Json -ErrorAction Stop

        if ($payload.success -ne $true) {
            $message = [string]$payload.message
            $script:WigleLastErrorMessage = $message

            if ($message -match '(?i)too many queries|rate.?limit') {
                $script:WigleRateLimited = $true
                $script:WigleRateLimitBasis = 'ApiMessage'
                $script:WigleTerminalFailure = $true
                $script:WigleTerminalFailureBasis = 'ApiMessageRateLimit'
            }
            elseif ($message -match '(?i)unauthorized|forbidden|not authorized|authenticat|credential|api.?key|token') {
                $script:WigleTerminalFailure = $true
                $script:WigleTerminalFailureBasis = 'ApiMessageAuthenticationOrAuthorization'
            }

            return $null
        }

        $exact = @(
            @($payload.results) |
                Where-Object {
                    (Normalize-Bssid -Bssid ([string]$_.netid)) -eq $normalized
                } |
                Select-Object -First 1
        )

        if ($exact.Count -eq 0) {
            return [pscustomobject]@{
                Found      = $false
                BSSID      = $normalized
                Latitude   = $null
                Longitude  = $null
                SSID       = $null
                LastUpdate = $null
            }
        }

        $result = $exact[0]

        if ($null -eq $result.trilat -or $null -eq $result.trilong) {
            return [pscustomobject]@{
                Found      = $false
                BSSID      = $normalized
                Latitude   = $null
                Longitude  = $null
                SSID       = [string]$result.ssid
                LastUpdate = [string]$result.lastupdt
            }
        }

        return [pscustomobject]@{
            Found      = $true
            BSSID      = $normalized
            Latitude   = [double]$result.trilat
            Longitude  = [double]$result.trilong
            SSID       = [string]$result.ssid
            LastUpdate = [string]$result.lastupdt
        }
    }
    catch {
        # Count the attempted live request even when the server returns non-2xx.
        $script:WigleLiveQueriesUsed++

        $httpDetail = Get-HttpErrorResponseDetail -ErrorRecord $_
        $script:WigleLastHttpStatus = $httpDetail.StatusCode
        $script:WigleLastErrorBody = if (
            -not [string]::IsNullOrWhiteSpace([string]$httpDetail.Body)
        ) {
            $bodyText = (([string]$httpDetail.Body) -replace '\s+', ' ').Trim()

            if ($bodyText.Length -gt 500) {
                $bodyText.Substring(0, 500)
            }
            else {
                $bodyText
            }
        }
        else {
            $null
        }

        $script:WigleLastErrorMessage = if (
            -not [string]::IsNullOrWhiteSpace([string]$httpDetail.Message)
        ) {
            [string]$httpDetail.Message
        }
        else {
            [string]$_.Exception.Message
        }

        # Preserve rate-limit headers from an HTTP error response where possible.
        try {
            if ($null -ne $_.Exception.Response -and
                $null -ne $_.Exception.Response.Headers) {

                $script:WigleRateLimitRemaining = Get-WigleHeaderValue `
                    -Headers $_.Exception.Response.Headers `
                    -Name 'X-RateLimit-Remaining'

                $script:WigleRateLimitLimit = Get-WigleHeaderValue `
                    -Headers $_.Exception.Response.Headers `
                    -Name 'X-RateLimit-Limit'

                $script:WigleRateLimitReset = Get-WigleHeaderValue `
                    -Headers $_.Exception.Response.Headers `
                    -Name 'X-RateLimit-Reset'
            }
        }
        catch { }

        if ($httpDetail.StatusCode -eq 401) {
            $script:WigleTerminalFailure = $true
            $script:WigleTerminalFailureBasis = 'Http401Unauthorized'
        }
        elseif ($httpDetail.StatusCode -eq 403) {
            # 403 is deliberately classified as Forbidden rather than blindly
            # calling it invalid credentials. WiGLE may use forbidden responses
            # for authorization/account/policy restrictions as well.
            $script:WigleTerminalFailure = $true
            $script:WigleTerminalFailureBasis = 'Http403Forbidden'
        }
        elseif ($httpDetail.StatusCode -eq 429) {
            $script:WigleRateLimited = $true
            $script:WigleRateLimitBasis = 'Http429'
            $script:WigleTerminalFailure = $true
            $script:WigleTerminalFailureBasis = 'Http429RateLimit'
        }
        elseif ([string]$httpDetail.Message -match '(?i)too many queries|rate.?limit') {
            $script:WigleRateLimited = $true
            $script:WigleRateLimitBasis = 'HttpErrorMessage'
            $script:WigleTerminalFailure = $true
            $script:WigleTerminalFailureBasis = 'HttpErrorMessageRateLimit'
        }
        elseif ([string]$httpDetail.Body -match '(?i)too many queries|rate.?limit') {
            $script:WigleRateLimited = $true
            $script:WigleRateLimitBasis = 'HttpErrorBody'
            $script:WigleTerminalFailure = $true
            $script:WigleTerminalFailureBasis = 'HttpErrorBodyRateLimit'
        }

        Write-Verbose ('WiGLE BSSID lookup failed: bssid={0}; httpStatus={1}; terminal={2}; terminalBasis={3}; rateLimited={4}; rateBasis={5}; message={6}; body={7}' -f
            $normalized,
            $(if ($null -eq $httpDetail.StatusCode) { '<unknown>' } else { $httpDetail.StatusCode }),
            $script:WigleTerminalFailure,
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleTerminalFailureBasis)) { '<none>' } else { $script:WigleTerminalFailureBasis }),
            $script:WigleRateLimited,
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitBasis)) { '<none>' } else { $script:WigleRateLimitBasis }),
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorMessage)) { '<none>' } else { $script:WigleLastErrorMessage }),
            $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorBody)) { '<none>' } else { $script:WigleLastErrorBody }))

        return $null
    }
}


function Get-WigleWifiLocation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$AccessPoints,

        [Parameter(Mandatory)]
        [string]$ApiName,

        [Parameter(Mandatory)]
        [string]$ApiToken,

        [AllowNull()]
        [string]$CurrentBssid,

        [ValidateRange(1, 20)]
        [int]$MaxLiveLookups = 8
    )

    $baseCandidates = @(
        $AccessPoints |
            Where-Object GoogleUsable |
            Sort-Object -Property @{
                Expression = { Get-WifiSortScore -AccessPoint $_ }
                Descending = $true
            },
            @{
                Expression = { [string]$_.BSSID }
                Descending = $false
            }
    )

    $script:WigleCandidateCount = $baseCandidates.Count
    $script:WigleCandidateOrder = @()
    $script:WigleCacheCandidatesChecked = 0
    $script:WigleLiveCandidatesEligible = 0
    $script:WigleCurrentBssidPrioritized = $false

    if ($baseCandidates.Count -eq 0) {
        return $null
    }

    $normalizedCurrentBssid = Normalize-Bssid -Bssid ([string]$CurrentBssid)
    $script:WigleCurrentBssid = $normalizedCurrentBssid

    $orderedCandidates = [System.Collections.Generic.List[object]]::new()
    $addedBssids = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $seenFamilies = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    function Get-WigleCandidateFamilyKey {
        param(
            [Parameter(Mandatory)]
            [object]$Candidate
        )

        $ssid = ([string]$Candidate.SSID).Trim()

        if (-not [string]::IsNullOrWhiteSpace($ssid) -and
            $ssid -notin @('<hidden>', '<unknown>')) {

            return 'SSID:{0}' -f $ssid.ToLowerInvariant()
        }

        $normalizedBssid = Normalize-Bssid -Bssid ([string]$Candidate.BSSID)

        if ($null -ne $normalizedBssid -and $normalizedBssid.Length -ge 14) {
            # First five octets: likely sibling radios are deferred.
            return 'BSSIDPREFIX:{0}' -f $normalizedBssid.Substring(0, 14)
        }

        return 'UNIQUE:{0}' -f [string]$Candidate.BSSID
    }

    function Add-WigleCandidate {
        param(
            [AllowNull()]
            [object]$Candidate
        )

        if ($null -eq $Candidate) {
            return
        }

        $candidateBssid = Normalize-Bssid -Bssid ([string]$Candidate.BSSID)

        if ($null -eq $candidateBssid) {
            return
        }

        if ($addedBssids.Add($candidateBssid)) {
            $orderedCandidates.Add($Candidate)
        }
    }

    # 1. Prefer the AP the endpoint is actually associated with.
    if ($null -ne $normalizedCurrentBssid) {
        $currentCandidate = @(
            $baseCandidates |
                Where-Object {
                    (Normalize-Bssid -Bssid ([string]$_.BSSID)) -eq
                        $normalizedCurrentBssid
                } |
                Select-Object -First 1
        )

        if ($currentCandidate.Count -gt 0) {
            Add-WigleCandidate -Candidate $currentCandidate[0]
            $script:WigleCurrentBssidPrioritized = $true
            $script:WigleCurrentBssidEligibility = 'EligibleAndPrioritized'
            [void]$seenFamilies.Add(
                (Get-WigleCandidateFamilyKey -Candidate $currentCandidate[0])
            )
        }
        else {
            $script:WigleCurrentBssidEligibility = 'NotInResolverEligibleSet'
        }
    }

    # 2. One representative from each visible network/AP family.
    foreach ($candidate in $baseCandidates) {
        $candidateBssid = Normalize-Bssid -Bssid ([string]$candidate.BSSID)

        if ($null -eq $candidateBssid -or
            $addedBssids.Contains($candidateBssid)) {
            continue
        }

        $familyKey = Get-WigleCandidateFamilyKey -Candidate $candidate

        if ($seenFamilies.Add($familyKey)) {
            Add-WigleCandidate -Candidate $candidate
        }
    }

    # 3. Only then append remaining sibling radios.
    foreach ($candidate in $baseCandidates) {
        Add-WigleCandidate -Candidate $candidate
    }

    $script:WigleCandidateOrder = @(
        $orderedCandidates |
            ForEach-Object {
                '{0}|{1}' -f
                    (Normalize-Bssid -Bssid ([string]$_.BSSID)),
                    $(if ([string]::IsNullOrWhiteSpace([string]$_.SSID)) {
                        '<hidden>'
                    }
                    else {
                        [string]$_.SSID
                    })
            }
    )

    $cache = Read-WigleBssidCache
    $cacheChanged = $false
    $freshCachedBssids = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    # PASS 1: inspect every fresh cache entry before spending a live request.
    foreach ($candidate in $orderedCandidates) {
        $bssid = Normalize-Bssid -Bssid ([string]$candidate.BSSID)

        if ($null -eq $bssid) {
            continue
        }

        if ($cache.ContainsKey($bssid) -and
            (Test-WigleCacheEntryFresh -Entry $cache[$bssid])) {

            [void]$freshCachedBssids.Add($bssid)
            $script:WigleCacheHits++
            $script:WigleCacheCandidatesChecked++

            $cached = $cache[$bssid]

            if (-not [bool]$cached.Found) {
                continue
            }

            return [pscustomobject]@{
                Method                 = 'WiGLEWiFi'
                Latitude               = [double]$cached.Latitude
                Longitude              = [double]$cached.Longitude
                AccuracyMeters         = $null
                Site                   = $null
                VpnResistant           = $true
                AnchorBssid            = $bssid
                AnchorSsid             = if (-not [string]::IsNullOrWhiteSpace([string]$cached.SSID)) {
                                             [string]$cached.SSID
                                         }
                                         else {
                                             [string]$candidate.SSID
                                         }
                AnchorSignalPercent    = $candidate.SignalPercent
                AnchorSignalDbm        = $candidate.SignalDbm
                WigleLastUpdate        = [string]$cached.LastUpdate
                WigleLiveQueriesUsed   = $script:WigleLiveQueriesUsed
                WigleCacheHits         = $script:WigleCacheHits
                Detail                 = ('WiGLE exact-BSSID cache matched [{0}] before any live request. Coordinate is crowdsourced/historical Wi-Fi evidence; liveQueries={1}; cacheHits={2}.' -f
                                            $bssid,
                                            $script:WigleLiveQueriesUsed,
                                            $script:WigleCacheHits)
            }
        }
    }

    $script:WigleLiveCandidatesEligible = @(
        $orderedCandidates |
            Where-Object {
                $candidateBssid = Normalize-Bssid -Bssid ([string]$_.BSSID)
                $null -ne $candidateBssid -and
                -not $freshCachedBssids.Contains($candidateBssid)
            }
    ).Count

    # PASS 2: live lookups in optimized candidate order.
    foreach ($candidate in $orderedCandidates) {
        if ($script:WigleRateLimited -or $script:WigleTerminalFailure) {
            break
        }

        if ($script:WigleLiveQueriesUsed -ge $MaxLiveLookups) {
            break
        }

        $bssid = Normalize-Bssid -Bssid ([string]$candidate.BSSID)

        if ($null -eq $bssid -or
            $freshCachedBssids.Contains($bssid)) {
            continue
        }

        $lookup = Invoke-WigleBssidLookup `
            -Bssid $bssid `
            -ApiName $ApiName `
            -ApiToken $ApiToken

        if ($null -eq $lookup) {
            continue
        }

        $cache[$bssid] = [pscustomobject]@{
            BSSID      = $bssid
            Found      = [bool]$lookup.Found
            Latitude   = $lookup.Latitude
            Longitude  = $lookup.Longitude
            SSID       = [string]$lookup.SSID
            LastUpdate = [string]$lookup.LastUpdate
            CheckedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        $cacheChanged = $true

        if (-not [bool]$lookup.Found) {
            continue
        }

        Write-WigleBssidCache -Cache $cache

        return [pscustomobject]@{
            Method                 = 'WiGLEWiFi'
            Latitude               = [double]$lookup.Latitude
            Longitude              = [double]$lookup.Longitude
            AccuracyMeters         = $null
            Site                   = $null
            VpnResistant           = $true
            AnchorBssid            = $bssid
            AnchorSsid             = if (-not [string]::IsNullOrWhiteSpace([string]$lookup.SSID)) {
                                         [string]$lookup.SSID
                                     }
                                     else {
                                         [string]$candidate.SSID
                                     }
            AnchorSignalPercent    = $candidate.SignalPercent
            AnchorSignalDbm        = $candidate.SignalDbm
            WigleLastUpdate        = [string]$lookup.LastUpdate
            WigleLiveQueriesUsed   = $script:WigleLiveQueriesUsed
            WigleCacheHits         = $script:WigleCacheHits
            Detail                 = ('WiGLE exact-BSSID live lookup matched [{0}] after cache-first candidate evaluation. Coordinate is crowdsourced/historical Wi-Fi evidence; liveQueries={1}; cacheHits={2}.' -f
                                        $bssid,
                                        $script:WigleLiveQueriesUsed,
                                        $script:WigleCacheHits)
        }
    }

    if ($cacheChanged) {
        Write-WigleBssidCache -Cache $cache
    }

    return $null
}


# ---------------------------------------------------------------------------
# Bluetooth LE proximity evidence
# ---------------------------------------------------------------------------

function Normalize-BluetoothAddress {
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $null
    }

    $hex = ($Address -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()

    if ($hex.Length -ne 12) {
        return $null
    }

    return ([regex]::Replace($hex, '(.{2})(?!$)', '$1:'))
}

function Format-BluetoothAddressFromUInt64 {
    param(
        [Parameter(Mandatory)]
        [UInt64]$Address
    )

    $hex = ('{0:X12}' -f $Address)
    return ([regex]::Replace($hex, '(.{2})(?!$)', '$1:'))
}

function Get-BluetoothManufacturerName {
    param(
        [AllowNull()]
        [Nullable[int]]$CompanyId
    )

    if ($null -eq $CompanyId) {
        return $null
    }

    switch ([int]$CompanyId) {
        6     { return 'Microsoft' }
        10    { return 'Qualcomm' }
        13    { return 'Texas Instruments' }
        15    { return 'Broadcom' }
        48    { return 'STMicroelectronics' }
        76    { return 'Apple' }
        89    { return 'Nordic Semiconductor' }
        117   { return 'Samsung' }
        224   { return 'Google' }
        240   { return 'Garmin' }
        301   { return 'Sony' }
        658   { return 'Fitbit' }
        741   { return 'Amazon' }
        0xFFFF { return 'Reserved/Test' }
        default { return ('CompanyId:{0}' -f [int]$CompanyId) }
    }
}

function ConvertTo-CompactBleText {
    param(
        [AllowNull()]
        [string]$Value,

        [int]$MaxLength = 18
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    $clean = ([string]$Value -replace '\s+', ' ').Trim()

    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    if ($MaxLength -le 3) {
        return $clean.Substring(0, $MaxLength)
    }

    return ('{0}...' -f $clean.Substring(0, $MaxLength - 3))
}

function Get-BluetoothPrimaryManufacturerId {
    param(
        [AllowNull()]
        [object]$ManufacturerIds
    )

    if ($null -eq $ManufacturerIds) {
        return $null
    }

    $text = ([string]$ManufacturerIds).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $first = @($text -split '[;, ]+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)

    if ($first.Count -eq 0) {
        return $null
    }

    return [int]$first[0]
}

function Get-BluetoothServiceSummary {
    param(
        [AllowNull()]
        [string]$ServiceUuids
    )

    if ([string]::IsNullOrWhiteSpace([string]$ServiceUuids)) {
        return ''
    }

    $known = @{
        '1800' = 'GenericAccess'
        '1801' = 'GenericAttribute'
        '180A' = 'DeviceInfo'
        '180D' = 'HeartRate'
        '180F' = 'Battery'
        '1812' = 'HID'
        '181A' = 'Environmental'
        '181C' = 'UserData'
        'FEAA' = 'Eddystone'
        'FE2C' = 'FastPair'
        'FD6F' = 'ExposureNotif'
    }

    $items = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in @(([string]$ServiceUuids) -split '[;, ]+')) {
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }

        $uuid = $raw.Trim().ToUpperInvariant()
        $short = $null

        if ($uuid -match '^0000([0-9A-F]{4})-0000-1000-8000-00805F9B34FB$') {
            $short = $matches[1]
        }
        elseif ($uuid -match '^[0-9A-F]{4}$') {
            $short = $uuid
        }

        if ($null -ne $short -and $known.ContainsKey($short)) {
            $items.Add([string]$known[$short])
        }
        elseif ($null -ne $short) {
            $items.Add($short)
        }
        elseif ($uuid.Length -ge 8) {
            $items.Add($uuid.Substring(0, 8))
        }
    }

    return (@($items | Select-Object -Unique | Select-Object -First 3) -join ',')
}

function Get-BluetoothOuiFromAddress {
    param(
        [AllowNull()]
        [string]$Address
    )

    $normalized = Normalize-BluetoothAddress -Address $Address

    if ($null -eq $normalized) {
        return $null
    }

    return (($normalized -replace ':', '').Substring(0, 6)).ToUpperInvariant()
}

function Test-BluetoothAddressLooksLocallyAdministered {
    param(
        [AllowNull()]
        [string]$Address
    )

    $normalized = Normalize-BluetoothAddress -Address $Address

    if ($null -eq $normalized) {
        return $true
    }

    $firstOctet = [Convert]::ToInt32($normalized.Substring(0, 2), 16)
    return (($firstOctet -band 0x02) -ne 0)
}

function Get-BluetoothEvidenceVendor {
    param(
        [AllowNull()]
        [string]$Address,

        [AllowNull()]
        [string]$AddressType,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    if ([string]$AddressType -match '(?i)Random') {
        return '<random>'
    }

    $oui = Get-BluetoothOuiFromAddress -Address $Address

    if ([string]::IsNullOrWhiteSpace([string]$oui)) {
        return 'Unknown'
    }

    if (Test-BluetoothAddressLooksLocallyAdministered -Address $Address) {
        return 'Private'
    }

    if ($Cache.ContainsKey($oui)) {
        return [string]$Cache[$oui]
    }

    try {
        $vendor = Get-GatewayVendor -Mac $Address

        if ([string]::IsNullOrWhiteSpace([string]$vendor)) {
            $vendor = 'Unknown'
        }

        $Cache[$oui] = ConvertTo-CompactBleText -Value $vendor -MaxLength 16
        return [string]$Cache[$oui]
    }
    catch {
        Write-Verbose ('Bluetooth OUI lookup failed for [{0}]: {1}' -f $oui, $_.Exception.Message)
        $Cache[$oui] = 'Unknown'
        return 'Unknown'
    }
}

function Get-BluetoothIdentityConfidence {
    param(
        [AllowNull()]
        [string]$AddressType,

        [AllowNull()]
        [string]$Name,

        [AllowNull()]
        [string]$ManufacturerIds,

        [AllowNull()]
        [string]$ServiceUuids,

        [AllowNull()]
        [string]$Vendor
    )

    $hasName = (-not [string]::IsNullOrWhiteSpace([string]$Name) -and [string]$Name -ne '<unknown>')
    $hasMfr = -not [string]::IsNullOrWhiteSpace([string]$ManufacturerIds)
    $hasSvc = -not [string]::IsNullOrWhiteSpace([string]$ServiceUuids)
    $isRandom = [string]$AddressType -match '(?i)Random'
    $hasVendor = (-not [string]::IsNullOrWhiteSpace([string]$Vendor) -and [string]$Vendor -notin @('<random>', 'Unknown', 'Private'))

    if (($hasMfr -and $hasSvc) -or ($hasName -and ($hasMfr -or $hasSvc))) {
        return 'High'
    }

    if ($hasMfr -or $hasSvc -or ($hasVendor -and $hasName)) {
        return 'Medium'
    }

    if ($isRandom -and -not $hasName -and -not $hasMfr -and -not $hasSvc) {
        return 'Ephemeral'
    }

    if ($hasName -or $hasVendor) {
        return 'Low'
    }

    return 'Ephemeral'
}

function Get-BluetoothFingerprint {
    param(
        [AllowNull()]
        [string]$AddressType,

        [AllowNull()]
        [string]$Name,

        [AllowNull()]
        [string]$AdvertisementType,

        [AllowNull()]
        [string]$ManufacturerIds,

        [AllowNull()]
        [string]$ServiceUuids,

        [AllowNull()]
        [string]$Vendor
    )

    $canonical = @(
        'BLEV1'
        ([string]$AddressType).ToUpperInvariant()
        ([string]$Name).ToUpperInvariant()
        ([string]$AdvertisementType).ToUpperInvariant()
        ([string]$ManufacturerIds).ToUpperInvariant()
        ([string]$ServiceUuids).ToUpperInvariant()
        ([string]$Vendor).ToUpperInvariant()
    ) -join '|'

    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
        return ('BLEV1:{0}' -f (([BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 10)))
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertFrom-BluetoothLeAdvertisementEventArgs {
    param(
        [Parameter(Mandatory)]
        [object]$EventArgs
    )

    $rawHex = ('{0:X12}' -f [UInt64]$EventArgs.BluetoothAddress)
    $address = [regex]::Replace($rawHex, '(.{2})(?!$)', '$1:')
    $rssi = [int]$EventArgs.RawSignalStrengthInDBm
    $name = [string]$EventArgs.Advertisement.LocalName

    $manufacturerIds = @()

    try {
        foreach ($m in @($EventArgs.Advertisement.ManufacturerData)) {
            $manufacturerIds += [int]$m.CompanyId
        }
    }
    catch { }

    $serviceUuids = @()

    try {
        foreach ($uuid in @($EventArgs.Advertisement.ServiceUuids)) {
            $serviceUuids += [string]$uuid
        }
    }
    catch { }

    $manufacturerId = if ($manufacturerIds.Count -gt 0) {
        [int]$manufacturerIds[0]
    }
    else {
        $null
    }

    $advType = try { [string]$EventArgs.AdvertisementType } catch { '' }
    $addrType = try { [string]$EventArgs.BluetoothAddressType } catch { '' }
    $manufacturerIdsText = (@($manufacturerIds | Select-Object -Unique) -join ';')
    $serviceUuidsText = (@($serviceUuids | Select-Object -Unique) -join ';')

    return [pscustomobject]@{
        Address           = $address
        Name              = if ([string]::IsNullOrWhiteSpace($name)) { '<unknown>' } else { $name }
        Rssi              = $rssi
        AdvertisementType = $advType
        AddressType       = $addrType
        ManufacturerIds   = $manufacturerIdsText
        ManufacturerId    = $manufacturerId
        Manufacturer      = Get-BluetoothManufacturerName -CompanyId $manufacturerId
        ServiceUuids      = $serviceUuidsText
        ServiceNames      = Get-BluetoothServiceSummary -ServiceUuids $serviceUuidsText
        SeenCount         = 1
        FirstSeenUtc      = [DateTime]::UtcNow
        LastSeenUtc       = [DateTime]::UtcNow
        Source            = 'WindowsBluetoothLEAdvertisementWatcher'
    }
}

function Invoke-BluetoothLeScanInProcess {
    param(
        [ValidateRange(1, 30)]
        [int]$ScanSeconds = 4
    )

    $sourceIdentifier = 'GetDeviceCoords.BluetoothLE.{0}' -f [Guid]::NewGuid().ToString('N')
    $watcher = $null
    $seen = @{}

    try {
        # Modern PowerShell can project the WinRT class directly. Do not preload
        # the legacy assembly-qualified type name here; that is what failed in v3.44.
        $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()

        # Resolve Passive from the projected property type instead of introducing
        # another WinRT type literal.
        $scanModeType = $watcher.ScanningMode.GetType()
        $watcher.ScanningMode = [Enum]::Parse($scanModeType, 'Passive')

        Register-ObjectEvent `
            -InputObject $watcher `
            -EventName Received `
            -SourceIdentifier $sourceIdentifier | Out-Null

        $watcher.Start()
        $deadline = [DateTime]::UtcNow.AddSeconds($ScanSeconds)

        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [Math]::Max(
                0.05,
                [Math]::Min(
                    0.50,
                    ($deadline - [DateTime]::UtcNow).TotalSeconds
                )
            )

            $event = Wait-Event `
                -SourceIdentifier $sourceIdentifier `
                -Timeout $remaining `
                -ErrorAction SilentlyContinue

            if ($null -eq $event) {
                continue
            }

            try {
                $record = ConvertFrom-BluetoothLeAdvertisementEventArgs `
                    -EventArgs $event.SourceEventArgs

                if ($null -ne $record -and
                    (
                        -not $seen.ContainsKey($record.Address) -or
                        [int]$record.Rssi -gt [int]$seen[$record.Address].Rssi
                    )) {
                    if ($seen.ContainsKey($record.Address) -and
                        $seen[$record.Address].PSObject.Properties.Name -contains 'SeenCount') {
                        $seen[$record.Address].SeenCount = [int]$seen[$record.Address].SeenCount + 1
                    }
                    $seen[$record.Address] = $record
                }
            }
            catch {
                Write-Verbose ('BLE advertisement parse failed: {0}' -f $_.Exception.Message)
            }
            finally {
                Remove-Event `
                    -EventIdentifier $event.EventIdentifier `
                    -ErrorAction SilentlyContinue
            }
        }

        $watcher.Stop()

        # Drain advertisements that arrived immediately before Stop().
        foreach ($event in @(
            Get-Event `
                -SourceIdentifier $sourceIdentifier `
                -ErrorAction SilentlyContinue
        )) {
            try {
                $record = ConvertFrom-BluetoothLeAdvertisementEventArgs `
                    -EventArgs $event.SourceEventArgs

                if ($null -ne $record -and
                    (
                        -not $seen.ContainsKey($record.Address) -or
                        [int]$record.Rssi -gt [int]$seen[$record.Address].Rssi
                    )) {
                    $seen[$record.Address] = $record
                }
            }
            catch { }
            finally {
                Remove-Event `
                    -EventIdentifier $event.EventIdentifier `
                    -ErrorAction SilentlyContinue
            }
        }

        $devices = @(
            $seen.Values |
                Sort-Object -Property @{
                    Expression = { [int]$_.Rssi }
                    Descending = $true
                }, @{
                    Expression = { [string]$_.Address }
                    Descending = $false
                }
        )

        return [pscustomobject]@{
            Status  = 'Success'
            Devices = @($devices)
            Detail  = ('Passive BLE advertisement scan completed in current PowerShell host for {0} second(s); devices={1}.' -f
                $ScanSeconds,
                $devices.Count)
            Engine  = 'CurrentPowerShellWinRT'
        }
    }
    catch {
        return [pscustomobject]@{
            Status  = 'Failed'
            Devices = @()
            Detail  = ('Current-host WinRT BLE scan failed: {0}' -f $_.Exception.Message)
            Engine  = 'CurrentPowerShellWinRT'
        }
    }
    finally {
        try {
            if ($null -ne $watcher) {
                $watcher.Stop()
            }
        }
        catch { }

        Get-EventSubscriber `
            -SourceIdentifier $sourceIdentifier `
            -ErrorAction SilentlyContinue |
            Unregister-Event -ErrorAction SilentlyContinue

        foreach ($event in @(
            Get-Event `
                -SourceIdentifier $sourceIdentifier `
                -ErrorAction SilentlyContinue
        )) {
            Remove-Event `
                -EventIdentifier $event.EventIdentifier `
                -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-BluetoothLeScanWindowsPowerShell {
    param(
        [ValidateRange(1, 30)]
        [int]$ScanSeconds = 4
    )

    $powershellCandidates = @(
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        (Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe')
    ) |
        Select-Object -Unique

    $powershellExe = @(
        $powershellCandidates |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_) -and
                (Test-Path -LiteralPath $_ -PathType Leaf)
            } |
            Select-Object -First 1
    )

    if ($powershellExe.Count -eq 0) {
        return [pscustomobject]@{
            Status  = 'Failed'
            Devices = @()
            Detail  = 'Windows PowerShell 5.1 compatibility host was not found.'
            Engine  = 'WindowsPowerShell51-InMemoryCSharp'
        }
    }

    $workerScript = @'
param(
    [ValidateRange(1, 30)]
    [int]$ScanSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$csharp = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq.Expressions;
using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;

public sealed class GdcBleRecordV152
{
    public string Address { get; set; }
    public int Rssi { get; set; }
    public string Name { get; set; }
    public string AdvertisementType { get; set; }
    public string AddressType { get; set; }
    public string ManufacturerIds { get; set; }
    public string ServiceUuids { get; set; }
    public int SeenCount { get; set; }
    public DateTime FirstSeenUtc { get; set; }
    public DateTime LastSeenUtc { get; set; }
}

public sealed class GdcBleScanResultV152
{
    public string Status { get; set; }
    public string Engine { get; set; }
    public string Detail { get; set; }
    public string WatcherStartStatus { get; set; }
    public GdcBleRecordV152[] Devices { get; set; }
}

public static class GdcBleInMemoryV152
{
    private static readonly object SyncRoot = new object();
    private static readonly Dictionary<ulong, GdcBleRecordV152> Seen =
        new Dictionary<ulong, GdcBleRecordV152>();

    private static object GetProperty(object instance, string name)
    {
        if (instance == null)
        {
            return null;
        }

        PropertyInfo property = instance.GetType().GetProperty(
            name,
            BindingFlags.Public | BindingFlags.Instance
        );

        if (property == null)
        {
            return null;
        }

        return property.GetValue(instance, null);
    }

    private static string FormatBluetoothAddress(ulong address)
    {
        string hex = address.ToString("X12", CultureInfo.InvariantCulture);

        return String.Format(
            CultureInfo.InvariantCulture,
            "{0}:{1}:{2}:{3}:{4}:{5}",
            hex.Substring(0, 2),
            hex.Substring(2, 2),
            hex.Substring(4, 2),
            hex.Substring(6, 2),
            hex.Substring(8, 2),
            hex.Substring(10, 2)
        );
    }

    private static string JoinCollectionProperty(object instance, string collectionName, string itemPropertyName)
    {
        object collection = GetProperty(instance, collectionName);

        if (collection == null)
        {
            return "";
        }

        IEnumerable enumerable = collection as IEnumerable;

        if (enumerable == null)
        {
            return "";
        }

        List<string> values = new List<string>();

        foreach (object item in enumerable)
        {
            object value = null;

            if (!String.IsNullOrWhiteSpace(itemPropertyName))
            {
                value = GetProperty(item, itemPropertyName);
            }
            else
            {
                value = item;
            }

            if (value == null)
            {
                continue;
            }

            string text = Convert.ToString(value, CultureInfo.InvariantCulture);

            if (!String.IsNullOrWhiteSpace(text) && !values.Contains(text))
            {
                values.Add(text);
            }
        }

        return String.Join(";", values.ToArray());
    }

    private static void OnReceived(object sender, object args)
    {
        try
        {
            object addressValue = GetProperty(args, "BluetoothAddress");
            object rssiValue = GetProperty(args, "RawSignalStrengthInDBm");

            if (addressValue == null || rssiValue == null)
            {
                return;
            }

            ulong address = Convert.ToUInt64(
                addressValue,
                CultureInfo.InvariantCulture
            );

            int rssi = Convert.ToInt32(
                rssiValue,
                CultureInfo.InvariantCulture
            );

            object advertisement = GetProperty(args, "Advertisement");

            string name = "";
            object localName = GetProperty(advertisement, "LocalName");

            if (localName != null)
            {
                name = Convert.ToString(
                    localName,
                    CultureInfo.InvariantCulture
                );
            }

            if (String.IsNullOrWhiteSpace(name))
            {
                name = "<unknown>";
            }

            object advertisementTypeValue = GetProperty(
                args,
                "AdvertisementType"
            );

            string advertisementType = advertisementTypeValue == null
                ? ""
                : advertisementTypeValue.ToString();

            object addressTypeValue = GetProperty(
                args,
                "BluetoothAddressType"
            );

            string addressType = addressTypeValue == null
                ? ""
                : addressTypeValue.ToString();

            string manufacturerIds = JoinCollectionProperty(
                advertisement,
                "ManufacturerData",
                "CompanyId"
            );

            string serviceUuids = JoinCollectionProperty(
                advertisement,
                "ServiceUuids",
                null
            );

            DateTime now = DateTime.UtcNow;

            lock (SyncRoot)
            {
                GdcBleRecordV152 previous;

                if (Seen.TryGetValue(address, out previous))
                {
                    previous.LastSeenUtc = now;
                    previous.SeenCount = previous.SeenCount + 1;

                    if (!String.IsNullOrWhiteSpace(manufacturerIds))
                    {
                        previous.ManufacturerIds = manufacturerIds;
                    }

                    if (!String.IsNullOrWhiteSpace(serviceUuids))
                    {
                        previous.ServiceUuids = serviceUuids;
                    }

                    if (rssi > previous.Rssi)
                    {
                        previous.Rssi = rssi;
                        previous.Name = name;
                        previous.AdvertisementType = advertisementType;
                        previous.AddressType = addressType;
                    }
                }
                else
                {
                    Seen[address] = new GdcBleRecordV152
                    {
                        Address = FormatBluetoothAddress(address),
                        Rssi = rssi,
                        Name = name,
                        AdvertisementType = advertisementType,
                        AddressType = addressType,
                        ManufacturerIds = manufacturerIds,
                        ServiceUuids = serviceUuids,
                        SeenCount = 1,
                        FirstSeenUtc = now,
                        LastSeenUtc = now
                    };
                }
            }
        }
        catch
        {
            // Ignore a malformed advertisement and keep listening.
        }
    }

    private static Delegate BuildReceivedDelegate(Type handlerType)
    {
        MethodInfo invoke = handlerType.GetMethod("Invoke");

        if (invoke == null)
        {
            throw new InvalidOperationException(
                "Unable to inspect the WinRT Received delegate."
            );
        }

        ParameterInfo[] parameters = invoke.GetParameters();

        if (parameters.Length != 2)
        {
            throw new InvalidOperationException(
                "Unexpected WinRT Received delegate signature."
            );
        }

        ParameterExpression sender = Expression.Parameter(
            parameters[0].ParameterType,
            "sender"
        );

        ParameterExpression args = Expression.Parameter(
            parameters[1].ParameterType,
            "args"
        );

        MethodInfo callback = typeof(GdcBleInMemoryV152).GetMethod(
            "OnReceived",
            BindingFlags.NonPublic | BindingFlags.Static
        );

        MethodCallExpression body = Expression.Call(
            callback,
            Expression.Convert(sender, typeof(object)),
            Expression.Convert(args, typeof(object))
        );

        return Expression.Lambda(
            handlerType,
            body,
            sender,
            args
        ).Compile();
    }

    private static void AddWinRtHandler<T>(
        object instance,
        EventInfo runtimeEvent,
        T handler)
    {
        MethodInfo addMethod = runtimeEvent.GetAddMethod(true);
        MethodInfo removeMethod = runtimeEvent.GetRemoveMethod(true);

        if (addMethod == null || removeMethod == null)
        {
            throw new InvalidOperationException(
                "WinRT event add/remove accessors were unavailable."
            );
        }

        Func<T, EventRegistrationToken> add =
            delegate(T value)
            {
                object token = addMethod.Invoke(
                    instance,
                    new object[] { value }
                );

                return (EventRegistrationToken)token;
            };

        Action<EventRegistrationToken> remove =
            delegate(EventRegistrationToken token)
            {
                removeMethod.Invoke(
                    instance,
                    new object[] { token }
                );
            };

        WindowsRuntimeMarshal.AddEventHandler<T>(
            add,
            remove,
            handler
        );
    }

    private static void RemoveWinRtHandler<T>(
        object instance,
        EventInfo runtimeEvent,
        T handler)
    {
        MethodInfo removeMethod = runtimeEvent.GetRemoveMethod(true);

        if (removeMethod == null)
        {
            return;
        }

        Action<EventRegistrationToken> remove =
            delegate(EventRegistrationToken token)
            {
                removeMethod.Invoke(
                    instance,
                    new object[] { token }
                );
            };

        WindowsRuntimeMarshal.RemoveEventHandler<T>(
            remove,
            handler
        );
    }

    private static void AddHandlerDynamic(
        object instance,
        EventInfo runtimeEvent,
        Delegate handler)
    {
        MethodInfo generic = typeof(GdcBleInMemoryV152).GetMethod(
            "AddWinRtHandler",
            BindingFlags.NonPublic | BindingFlags.Static
        );

        MethodInfo closed = generic.MakeGenericMethod(
            handler.GetType()
        );

        closed.Invoke(
            null,
            new object[] {
                instance,
                runtimeEvent,
                handler
            }
        );
    }

    private static void RemoveHandlerDynamic(
        object instance,
        EventInfo runtimeEvent,
        Delegate handler)
    {
        MethodInfo generic = typeof(GdcBleInMemoryV152).GetMethod(
            "RemoveWinRtHandler",
            BindingFlags.NonPublic | BindingFlags.Static
        );

        MethodInfo closed = generic.MakeGenericMethod(
            handler.GetType()
        );

        closed.Invoke(
            null,
            new object[] {
                instance,
                runtimeEvent,
                handler
            }
        );
    }

    public static GdcBleScanResultV152 Scan(int seconds)
    {
        lock (SyncRoot)
        {
            Seen.Clear();
        }

        const string watcherTypeName =
            "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType=WindowsRuntime";

        Type watcherType = Type.GetType(
            watcherTypeName,
            false
        );

        if (watcherType == null)
        {
            return new GdcBleScanResultV152
            {
                Status = "WinRTTypeUnavailable",
                Engine = "WindowsPowerShell51-InMemoryCSharp",
                Detail = "The Desktop CLR could not resolve BluetoothLEAdvertisementWatcher.",
                WatcherStartStatus = "",
                Devices = new GdcBleRecordV152[0]
            };
        }

        object watcher = null;
        EventInfo receivedEvent = null;
        Delegate receivedHandler = null;

        try
        {
            watcher = Activator.CreateInstance(watcherType);

            PropertyInfo scanningMode = watcherType.GetProperty(
                "ScanningMode",
                BindingFlags.Public | BindingFlags.Instance
            );

            if (scanningMode != null)
            {
                object passive = Enum.Parse(
                    scanningMode.PropertyType,
                    "Passive",
                    true
                );

                scanningMode.SetValue(
                    watcher,
                    passive,
                    null
                );
            }

            receivedEvent = watcherType.GetEvent(
                "Received",
                BindingFlags.Public | BindingFlags.Instance
            );

            if (receivedEvent == null)
            {
                throw new InvalidOperationException(
                    "BluetoothLEAdvertisementWatcher.Received was not found."
                );
            }

            receivedHandler = BuildReceivedDelegate(
                receivedEvent.EventHandlerType
            );

            AddHandlerDynamic(
                watcher,
                receivedEvent,
                receivedHandler
            );

            MethodInfo startMethod = watcherType.GetMethod(
                "Start",
                BindingFlags.Public | BindingFlags.Instance
            );

            MethodInfo stopMethod = watcherType.GetMethod(
                "Stop",
                BindingFlags.Public | BindingFlags.Instance
            );

            PropertyInfo statusProperty = watcherType.GetProperty(
                "Status",
                BindingFlags.Public | BindingFlags.Instance
            );

            startMethod.Invoke(
                watcher,
                null
            );

            string startStatus = statusProperty == null
                ? ""
                : Convert.ToString(
                    statusProperty.GetValue(watcher, null),
                    CultureInfo.InvariantCulture
                );

            if (String.Equals(
                startStatus,
                "Aborted",
                StringComparison.OrdinalIgnoreCase))
            {
                return new GdcBleScanResultV152
                {
                    Status = "Failed",
                    Engine = "WindowsPowerShell51-InMemoryCSharp",
                    Detail = "BluetoothLEAdvertisementWatcher entered Aborted state immediately after Start().",
                    WatcherStartStatus = startStatus,
                    Devices = new GdcBleRecordV152[0]
                };
            }

            Thread.Sleep(
                Math.Max(1, Math.Min(30, seconds)) * 1000
            );

            if (stopMethod != null)
            {
                stopMethod.Invoke(
                    watcher,
                    null
                );
            }

            Thread.Sleep(250);

            List<GdcBleRecordV152> records;

            lock (SyncRoot)
            {
                records = new List<GdcBleRecordV152>(
                    Seen.Values
                );
            }

            records.Sort(
                delegate(
                    GdcBleRecordV152 left,
                    GdcBleRecordV152 right)
                {
                    int compare = right.Rssi.CompareTo(
                        left.Rssi
                    );

                    if (compare != 0)
                    {
                        return compare;
                    }

                    return String.Compare(
                        left.Address,
                        right.Address,
                        StringComparison.OrdinalIgnoreCase
                    );
                }
            );

            return new GdcBleScanResultV152
            {
                Status = "Success",
                Engine = "WindowsPowerShell51-InMemoryCSharp",
                Detail = String.Format(
                    CultureInfo.InvariantCulture,
                    "Passive BLE scan completed in-memory for {0} second(s); unique advertisers={1}.",
                    seconds,
                    records.Count
                ),
                WatcherStartStatus = startStatus,
                Devices = records.ToArray()
            };
        }
        catch (Exception ex)
        {
            Exception useful = ex;

            if (ex is TargetInvocationException &&
                ex.InnerException != null)
            {
                useful = ex.InnerException;
            }

            return new GdcBleScanResultV152
            {
                Status = "Failed",
                Engine = "WindowsPowerShell51-InMemoryCSharp",
                Detail = useful.GetType().FullName + ": " + useful.Message,
                WatcherStartStatus = "",
                Devices = new GdcBleRecordV152[0]
            };
        }
        finally
        {
            if (watcher != null &&
                receivedEvent != null &&
                receivedHandler != null)
            {
                try
                {
                    RemoveHandlerDynamic(
                        watcher,
                        receivedEvent,
                        receivedHandler
                    );
                }
                catch
                {
                }
            }

            if (watcher != null)
            {
                try
                {
                    MethodInfo stopMethod = watcherType.GetMethod(
                        "Stop",
                        BindingFlags.Public | BindingFlags.Instance
                    );

                    if (stopMethod != null)
                    {
                        stopMethod.Invoke(
                            watcher,
                            null
                        );
                    }
                }
                catch
                {
                }
            }
        }
    }
}
"@

if (-not ('GdcBleInMemoryV152' -as [type])) {
    Add-Type `
        -TypeDefinition $csharp `
        -Language CSharp `
        -ErrorAction Stop
}

$result = [GdcBleInMemoryV152]::Scan(
    [int]$ScanSeconds
)

$result |
    ConvertTo-Json `
        -Depth 8 `
        -Compress
'@

    # Match the standalone Test-BluetoothLEScan-v1.3.0 execution model.
    # Do not rely on a param() block over stdin; append an explicit scan invocation
    # and remove the worker's embedded default invocation so exactly one JSON
    # result is emitted.
    $tail = @'
$result = [GdcBleInMemoryV152]::Scan(
    [int]$ScanSeconds
)

$result |
    ConvertTo-Json `
        -Depth 8 `
        -Compress
'@

    $payload = $workerScript + [Environment]::NewLine +
        ('[GdcBleInMemoryV152]::Scan({0}) | ConvertTo-Json -Depth 8 -Compress' -f $ScanSeconds)

    $payload = $payload.Replace(
        $tail,
        ''
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [string]$powershellExe[0]
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw 'Unable to start Windows PowerShell 5.1 BLE worker.'
        }

        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(($ScanSeconds + 20) * 1000)) {
            try { $process.Kill() } catch { }
            throw 'Windows PowerShell in-memory BLE worker timed out.'
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        $jsonLine = @(
            $stdout -split "`r?`n" |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_) -and
                    $_.TrimStart().StartsWith('{')
                } |
                Select-Object -Last 1
        )

        if ($jsonLine.Count -eq 0) {
            return [pscustomobject]@{
                Status  = 'Failed'
                Devices = @()
                Detail  = ('Windows PowerShell in-memory BLE worker returned no JSON after v1.3 payload invocation. ExitCode={0}; stderr={1}; stdout={2}' -f
                    $process.ExitCode,
                    $(if ([string]::IsNullOrWhiteSpace([string]$stderr)) { '<none>' } else { $stderr.Trim() }),
                    $(if ([string]::IsNullOrWhiteSpace([string]$stdout)) { '<none>' } else { $stdout.Trim() }))
                Engine  = 'WindowsPowerShell51-InMemoryCSharp'
            }
        }

        $parsed = [string]$jsonLine[0] |
            ConvertFrom-Json -ErrorAction Stop

        $devices = @(
            foreach ($device in @($parsed.Devices)) {
                $manufacturerIdsText = [string]$device.ManufacturerIds
                $manufacturerId = Get-BluetoothPrimaryManufacturerId -ManufacturerIds $manufacturerIdsText
                $manufacturerName = Get-BluetoothManufacturerName -CompanyId $manufacturerId
                $serviceUuidsText = [string]$device.ServiceUuids

                [pscustomobject]@{
                    Address           = [string]$device.Address
                    Name              = [string]$device.Name
                    Rssi              = [int]$device.Rssi
                    AdvertisementType = [string]$device.AdvertisementType
                    AddressType       = [string]$device.AddressType
                    ManufacturerIds   = $manufacturerIdsText
                    ManufacturerId    = $manufacturerId
                    Manufacturer      = $manufacturerName
                    ServiceUuids      = $serviceUuidsText
                    ServiceNames      = Get-BluetoothServiceSummary -ServiceUuids $serviceUuidsText
                    SeenCount         = if ($null -ne $device.SeenCount) { [int]$device.SeenCount } else { 1 }
                    FirstSeenUtc      = $device.FirstSeenUtc
                    LastSeenUtc       = $device.LastSeenUtc
                    Source            = 'WindowsPowerShell51-InMemoryCSharp'
                }
            }
        )

        return [pscustomobject]@{
            Status  = [string]$parsed.Status
            Devices = @($devices)
            Detail  = ('{0} WorkerHost=WindowsPowerShell5.1; Transport=StdIn; WatcherStartStatus={1}.' -f
                [string]$parsed.Detail,
                $(if ([string]::IsNullOrWhiteSpace([string]$parsed.WatcherStartStatus)) { '<none>' } else { [string]$parsed.WatcherStartStatus }))
            Engine  = 'WindowsPowerShell51-InMemoryCSharp'
        }
    }
    catch {
        return [pscustomobject]@{
            Status  = 'Failed'
            Devices = @()
            Detail  = ('Windows PowerShell in-memory BLE worker failed: {0}' -f $_.Exception.Message)
            Engine  = 'WindowsPowerShell51-InMemoryCSharp'
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-BluetoothLeEvidence {
    param(
        [ValidateRange(1, 30)]
        [int]$ScanSeconds = 4
    )

    if ((Get-PlatformName) -ne 'Windows') {
        return [pscustomobject]@{
            Status  = 'UnsupportedPlatform'
            Devices = @()
            Detail  = 'Bluetooth LE advertisement scanning is currently implemented for Windows only.'
            Engine  = 'None'
        }
    }

    $primary = Invoke-BluetoothLeScanInProcess `
        -ScanSeconds $ScanSeconds

    if ($primary.Status -eq 'Success') {
        return $primary
    }

    Write-Verbose ('Bluetooth current-host engine failed; trying Windows PowerShell 5.1 in-memory C# compatibility helper. Primary error: {0}' -f
        $primary.Detail)

    $compat = Invoke-BluetoothLeScanWindowsPowerShell `
        -ScanSeconds $ScanSeconds

    if ($compat.Status -eq 'Success') {
        $compat.Detail = '{0} Primary engine failure was: {1}' -f
            $compat.Detail,
            $primary.Detail

        return $compat
    }

    return [pscustomobject]@{
        Status  = 'Failed'
        Devices = @()
        Detail  = ('Bluetooth LE scan failed in both engines. Primary=[{0}] Compatibility=[{1}]' -f
            $primary.Detail,
            $compat.Detail)
        Engine  = 'FailedBoth'
    }
}

function Get-KnownBluetoothLocation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Devices,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $anchors = @(Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Verbose ('Known Bluetooth map could not be read [{0}]: {1}' -f $Path, $_.Exception.Message)
        return $null
    }

    $matches = [System.Collections.Generic.List[object]]::new()

    foreach ($device in @($Devices)) {
        foreach ($anchor in @($anchors)) {
            $matchedBy = $null
            $anchorAddress = Normalize-BluetoothAddress -Address ([string]$anchor.Address)

            if ($null -ne $anchorAddress -and $anchorAddress -eq (Normalize-BluetoothAddress -Address ([string]$device.Address))) {
                $matchedBy = 'Address'
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$anchor.ServiceUuid) -and
                    -not [string]::IsNullOrWhiteSpace([string]$device.ServiceUuids) -and
                    [string]$device.ServiceUuids -match [regex]::Escape([string]$anchor.ServiceUuid)) {
                $matchedBy = 'ServiceUuid'
            }
            elseif ($null -ne $anchor.ManufacturerId -and
                    $null -ne $device.ManufacturerId -and
                    [int]$anchor.ManufacturerId -eq [int]$device.ManufacturerId -and
                    -not [string]::IsNullOrWhiteSpace([string]$anchor.Name) -and
                    [string]$device.Name -eq [string]$anchor.Name) {
                $matchedBy = 'ManufacturerId+Name'
            }

            if ($null -ne $matchedBy -and
                $null -ne $anchor.Latitude -and
                $null -ne $anchor.Longitude) {

                $matches.Add([pscustomobject]@{
                    AnchorName  = [string]$anchor.Name
                    Address     = [string]$device.Address
                    DeviceName  = [string]$device.Name
                    Rssi        = $device.Rssi
                    MatchedBy   = $matchedBy
                    Latitude    = [double]$anchor.Latitude
                    Longitude   = [double]$anchor.Longitude
                    Site        = [string]$anchor.Site
                })
            }
        }
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    $best = @($matches | Sort-Object -Property @{ Expression = { [int]$_.Rssi }; Descending = $true }) | Select-Object -First 1

    return [pscustomobject]@{
        Method         = 'KnownBluetooth'
        Latitude       = [double]$best.Latitude
        Longitude      = [double]$best.Longitude
        AccuracyMeters = $null
        Site           = $best.Site
        VpnResistant   = $true
        AnchorName     = $best.AnchorName
        AnchorAddress  = $best.Address
        AnchorRssi     = $best.Rssi
        AnchorCount    = $matches.Count
        Detail         = ('Known Bluetooth anchor matched [{0}] by {1}; anchorCount={2}; rssi={3} dBm. Passive BLE evidence only; no pairing, connection, or GATT interrogation was performed.' -f
                            $best.AnchorName,
                            $best.MatchedBy,
                            $matches.Count,
                            $best.Rssi)
    }
}

function Get-BluetoothEvidenceFlat {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Devices,

        [AllowNull()]
        [object]$AnchorLocation,

        [AllowNull()]
        [string]$Status,

        [AllowNull()]
        [string]$Detail,

        [int]$ScanSeconds = 4,

        [switch]$ForceStatusOutput
    )

    $btVendorCache = @{}

    $rows = @(
        $Devices |
            Sort-Object -Property @{ Expression = { [int]$_.Rssi }; Descending = $true } |
            Select-Object -First 25 |
            ForEach-Object {
                $isAnchor = $false

                if ($null -ne $AnchorLocation -and
                    -not [string]::IsNullOrWhiteSpace([string]$AnchorLocation.AnchorAddress) -and
                    (Normalize-BluetoothAddress -Address ([string]$_.Address)) -eq (Normalize-BluetoothAddress -Address ([string]$AnchorLocation.AnchorAddress))) {
                    $isAnchor = $true
                }

                $advType = if ($_.PSObject.Properties.Name -contains 'AdvertisementType') { [string]$_.AdvertisementType } else { '' }
                $addrType = if ($_.PSObject.Properties.Name -contains 'AddressType') { [string]$_.AddressType } else { '' }
                $manufacturerIds = if ($_.PSObject.Properties.Name -contains 'ManufacturerIds') { [string]$_.ManufacturerIds } else { '' }
                $manufacturerId = if ($_.PSObject.Properties.Name -contains 'ManufacturerId') { $_.ManufacturerId } else { Get-BluetoothPrimaryManufacturerId -ManufacturerIds $manufacturerIds }
                $company = if ($_.PSObject.Properties.Name -contains 'Manufacturer' -and -not [string]::IsNullOrWhiteSpace([string]$_.Manufacturer)) {
                    [string]$_.Manufacturer
                }
                else {
                    Get-BluetoothManufacturerName -CompanyId $manufacturerId
                }
                $serviceUuids = if ($_.PSObject.Properties.Name -contains 'ServiceUuids') { [string]$_.ServiceUuids } else { '' }
                $serviceSummary = if ($_.PSObject.Properties.Name -contains 'ServiceNames' -and -not [string]::IsNullOrWhiteSpace([string]$_.ServiceNames)) {
                    [string]$_.ServiceNames
                }
                else {
                    Get-BluetoothServiceSummary -ServiceUuids $serviceUuids
                }
                $seenCount = if ($_.PSObject.Properties.Name -contains 'SeenCount' -and $null -ne $_.SeenCount) {
                    [int]$_.SeenCount
                }
                else {
                    1
                }
                $vendor = Get-BluetoothEvidenceVendor `
                    -Address ([string]$_.Address) `
                    -AddressType $addrType `
                    -Cache $btVendorCache

                $confidence = Get-BluetoothIdentityConfidence `
                    -AddressType $addrType `
                    -Name ([string]$_.Name) `
                    -ManufacturerIds $manufacturerIds `
                    -ServiceUuids $serviceUuids `
                    -Vendor $vendor

                $fingerprint = Get-BluetoothFingerprint `
                    -AddressType $addrType `
                    -Name ([string]$_.Name) `
                    -AdvertisementType $advType `
                    -ManufacturerIds $manufacturerIds `
                    -ServiceUuids $serviceUuids `
                    -Vendor $vendor

                [pscustomobject][ordered]@{
                    RSSI               = $_.Rssi
                    Address            = $_.Address
                    Name               = ConvertTo-CompactBleText -Value $_.Name -MaxLength 14
                    Addr               = if ([string]::IsNullOrWhiteSpace($addrType)) { '' } else { $addrType }
                    Company_Name       = ConvertTo-CompactBleText -Value $company -MaxLength 18
                    Svc                = ConvertTo-CompactBleText -Value $serviceSummary -MaxLength 12
                    Seen               = $seenCount
                    FP                 = $fingerprint.Replace('BLEV1:', '')
                    Conf               = $confidence
                    vendor_information = ConvertTo-CompactBleText -Value $vendor -MaxLength 256
                }
            }
    )

    $statusText = if ([string]::IsNullOrWhiteSpace([string]$Status)) {
        'Unknown'
    }
    else {
        [string]$Status
    }

    $detailText = if ([string]::IsNullOrWhiteSpace([string]$Detail)) {
        '<none>'
    }
    else {
        ([string]$Detail).Trim()
    }

    if ($rows.Count -eq 0) {
        if ($ForceStatusOutput) {
            return (
                'Status={0}; Devices=0; ScanSeconds={1}; Detail={2}' -f
                    $statusText,
                    $ScanSeconds,
                    $detailText
            )
        }

        return 'None'
    }

    function Split-BluetoothEvidenceText {
        param(
            [AllowNull()]
            [string]$Value,

            [ValidateRange(8, 80)]
            [int]$Width = 36
        )

        $textValue = if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            ''
        }
        else {
            (([string]$Value) -replace '\s+', ' ').Trim()
        }

        if ($textValue.Length -le $Width) {
            return @($textValue)
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        $remaining = $textValue

        while ($remaining.Length -gt $Width) {
            $breakIndex = $remaining.LastIndexOf(' ', $Width)

            if ($breakIndex -lt [Math]::Floor($Width * 0.55)) {
                $breakIndex = $Width
            }

            $segment = $remaining.Substring(0, $breakIndex).Trim()

            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                $parts.Add($segment)
            }

            $remaining = $remaining.Substring($breakIndex).Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($remaining)) {
            $parts.Add($remaining)
        }

        return @($parts)
    }

    # Deterministic fixed-width rendering is used here because PowerShell's
    # table formatter still shortens the final field when the formatted table
    # is embedded as a multiline property in the outer result object.
    $header = '{0,4} {1,-17} {2,-14} {3,-6} {4,-18} {5,-12} {6,4} {7,-10} {8,-9} {9,-36}' -f `
        'RSSI',
        'Address',
        'Name',
        'Addr',
        'Company_Name',
        'Svc',
        'Seen',
        'FP',
        'Conf',
        'vendor_information'

    $divider = '{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}' -f `
        ('-' * 4),
        ('-' * 17),
        ('-' * 14),
        ('-' * 6),
        ('-' * 18),
        ('-' * 12),
        ('-' * 4),
        ('-' * 10),
        ('-' * 9),
        ('-' * 36)

    $tableLines = [System.Collections.Generic.List[string]]::new()
    $tableLines.Add($header)
    $tableLines.Add($divider)

    foreach ($row in @($rows)) {
        $vendorLines = @(
            Split-BluetoothEvidenceText `
                -Value ([string]$row.vendor_information) `
                -Width 36
        )

        if ($vendorLines.Count -eq 0) {
            $vendorLines = @('')
        }

        $firstLine = '{0,4} {1,-17} {2,-14} {3,-6} {4,-18} {5,-12} {6,4} {7,-10} {8,-9} {9,-36}' -f `
            [string]$row.RSSI,
            [string]$row.Address,
            [string]$row.Name,
            [string]$row.Addr,
            [string]$row.Company_Name,
            [string]$row.Svc,
            [string]$row.Seen,
            [string]$row.FP,
            [string]$row.Conf,
            [string]$vendorLines[0]

        $tableLines.Add($firstLine.TrimEnd())

        for ($vendorLineIndex = 1; $vendorLineIndex -lt $vendorLines.Count; $vendorLineIndex++) {
            $continuation = '{0,4} {1,-17} {2,-14} {3,-6} {4,-18} {5,-12} {6,4} {7,-10} {8,-9} {9,-36}' -f `
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                [string]$vendorLines[$vendorLineIndex]

            $tableLines.Add($continuation.TrimEnd())
        }
    }

    $tableText = ($tableLines -join "`r`n").Trim()

    if ($ForceStatusOutput) {
        return (
            "Status={0}; Devices={1}; ScanSeconds={2}; Detail={3}`r`n{4}" -f
                $statusText,
                $rows.Count,
                $ScanSeconds,
                $detailText,
                $tableText
        )
    }

    return $tableText
}

# ---------------------------------------------------------------------------
# Windows GPS / GNSS
# ---------------------------------------------------------------------------

function Get-WindowsGpsHardwareEvidence {
    if ((Get-PlatformName) -ne 'Windows') {
        return @()
    }

    # Match candidate GPS/WWAN tokens using alphanumeric boundaries rather than \b.
    # This accepts punctuation-separated names such as LTE\5G\GPS, LTE_5G_GPS, or -LTE-
    # while avoiding substring false positives such as Realtek, XLTE, or LTEAdvanced.
    $pattern = @'
(?ix)
(
    (?<![\p{L}\p{N}])
    (?:GPS|GNSS|NMEA|WWAN|LTE|5G)
    (?![\p{L}\p{N}])
    |
    Mobile\s+Broadband
    |
    Global\s+Navigation\s+Satellite
    |
    u-blox
    |
    Quectel.*(?:GNSS|GPS)
    |
    Sierra\s+Wireless.*(?:GNSS|GPS)
    |
    Fibocom.*(?:GNSS|GPS)
    |
    Telit.*(?:GNSS|GPS)
)
'@
    $items = @()

    try {
        if (Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue) {
            $items = @(
                Get-PnpDevice -PresentOnly -ErrorAction Stop |
                    Where-Object {
                        ('{0} {1} {2} {3}' -f
                            [string]$_.FriendlyName,
                            [string]$_.Class,
                            [string]$_.InstanceId,
                            [string]$_.Status) -match $pattern
                    } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name       = if ([string]::IsNullOrWhiteSpace([string]$_.FriendlyName)) {
                                            [string]$_.InstanceId
                                         }
                                         else {
                                            [string]$_.FriendlyName
                                         }
                            Class      = [string]$_.Class
                            InstanceId = [string]$_.InstanceId
                        }
                    }
            )
        }
        elseif (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
            $items = @(
                Get-CimInstance -ClassName Win32_PnPEntity `
                    -Property Name, PNPClass, DeviceID, Status `
                    -ErrorAction Stop |
                    Where-Object {
                        ('{0} {1} {2} {3}' -f
                            [string]$_.Name,
                            [string]$_.PNPClass,
                            [string]$_.DeviceID,
                            [string]$_.Status) -match $pattern
                    } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name       = [string]$_.Name
                            Class      = [string]$_.PNPClass
                            InstanceId = [string]$_.DeviceID
                        }
                    }
            )
        }
        elseif (Get-Command -Name Get-WmiObject -ErrorAction SilentlyContinue) {
            $items = @(
                Get-WmiObject -Class Win32_PnPEntity `
                    -Property Name, PNPClass, DeviceID, Status `
                    -ErrorAction Stop |
                    Where-Object {
                        ('{0} {1} {2} {3}' -f
                            [string]$_.Name,
                            [string]$_.PNPClass,
                            [string]$_.DeviceID,
                            [string]$_.Status) -match $pattern
                    } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name       = [string]$_.Name
                            Class      = [string]$_.PNPClass
                            InstanceId = [string]$_.DeviceID
                        }
                    }
            )
        }
    }
    catch {
        Write-Verbose ('GPS/GNSS hardware detection failed: {0}' -f $_.Exception.Message)
    }

    return @(
        $items |
            Sort-Object Name, InstanceId -Unique
    )
}

function Get-WindowsWinRtHighAccuracyLocation {
    param(
        [Parameter(Mandatory)]
        [int]$Timeout
    )

    $powershellExe = Join-Path `
        -Path $env:SystemRoot `
        -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        return [pscustomobject]@{
            Status               = 'Unavailable'
            PositionSource       = $null
            Latitude             = $null
            Longitude            = $null
            AccuracyMeters       = $null
            AltitudeMeters       = $null
            HorizontalDop        = $null
            PositionDop          = $null
            Detail               = 'Windows PowerShell compatibility host was not found.'
        }
    }

    $childScript = @"
`$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

    `$null = [Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType=WindowsRuntime]
    `$null = [Windows.Devices.Geolocation.Geoposition, Windows.Devices.Geolocation, ContentType=WindowsRuntime]
    `$null = [Windows.Devices.Geolocation.PositionAccuracy, Windows.Devices.Geolocation, ContentType=WindowsRuntime]

    `$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            `$_.Name -eq 'AsTask' -and
            `$_.IsGenericMethod -and
            `$_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if (`$null -eq `$asTaskGeneric) {
        throw 'Unable to locate System.WindowsRuntimeSystemExtensions.AsTask<T>.'
    }

    function Await-WinRtOperation {
        param(
            [Parameter(Mandatory)]`$Operation,
            [Parameter(Mandatory)][Type]`$ResultType
        )

        `$asTask = `$asTaskGeneric.MakeGenericMethod(`$ResultType)
        `$task = `$asTask.Invoke(`$null, @(`$Operation))
        `$task.GetAwaiter().GetResult()
    }

    `$locator = [Windows.Devices.Geolocation.Geolocator]::new()
    `$locator.DesiredAccuracy = [Windows.Devices.Geolocation.PositionAccuracy]::High

    try {
        `$locator.DesiredAccuracyInMeters = 10
    }
    catch { }

    `$operation = `$locator.GetGeopositionAsync(
        [TimeSpan]::Zero,
        [TimeSpan]::FromSeconds($Timeout)
    )

    `$position = Await-WinRtOperation `
        -Operation `$operation `
        -ResultType ([Windows.Devices.Geolocation.Geoposition])

    if (`$null -eq `$position -or `$null -eq `$position.Coordinate) {
        throw 'Windows Geolocator returned no coordinate.'
    }

    `$coordinate = `$position.Coordinate
    `$satelliteData = `$null

    try {
        `$satelliteData = `$coordinate.SatelliteData
    }
    catch { }

    `$payload = [ordered]@{
        Latitude       = [double]`$coordinate.Latitude
        Longitude      = [double]`$coordinate.Longitude
        AccuracyMeters = [double]`$coordinate.Accuracy
        PositionSource = [string]`$coordinate.PositionSource
        AltitudeMeters = if (`$null -ne `$coordinate.Altitude) {
                            [double]`$coordinate.Altitude
                         }
                         else {
                            `$null
                         }
        HorizontalDop  = if (`$null -ne `$satelliteData -and
                             `$null -ne `$satelliteData.HorizontalDilutionOfPrecision) {
                            [double]`$satelliteData.HorizontalDilutionOfPrecision
                         }
                         else {
                            `$null
                         }
        PositionDop    = if (`$null -ne `$satelliteData -and
                             `$null -ne `$satelliteData.PositionDilutionOfPrecision) {
                            [double]`$satelliteData.PositionDilutionOfPrecision
                         }
                         else {
                            `$null
                         }
    }

    [pscustomobject]`$payload | ConvertTo-Json -Compress
}
catch {
    [pscustomobject]@{
        Error = `$_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
"@

    try {
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($childScript)
        )

        $capture = Invoke-NativeCapture `
            -FilePath $powershellExe `
            -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-EncodedCommand',
                $encoded
            ) `
            -TimeoutSeconds ($Timeout + 5)

        $jsonLine = @(
            ([string]$capture.StdOut) -split "`r?`n" |
                Where-Object { $_ -match '^\s*\{' }
        ) | Select-Object -Last 1

        if ([string]::IsNullOrWhiteSpace([string]$jsonLine)) {
            return [pscustomobject]@{
                Status               = if ($capture.TimedOut) { 'TimedOut' } else { 'NoFix' }
                PositionSource       = $null
                Latitude             = $null
                Longitude            = $null
                AccuracyMeters       = $null
                AltitudeMeters       = $null
                HorizontalDop        = $null
                PositionDop          = $null
                Detail               = if ($capture.TimedOut) {
                                           'Windows WinRT Geolocator timed out.'
                                       }
                                       else {
                                           'Windows WinRT Geolocator returned no parseable result.'
                                       }
            }
        }

        $payload = $jsonLine | ConvertFrom-Json

        if ($payload.PSObject.Properties.Name -contains 'Error' -and
            -not [string]::IsNullOrWhiteSpace([string]$payload.Error)) {

            return [pscustomobject]@{
                Status               = 'NoFix'
                PositionSource       = $null
                Latitude             = $null
                Longitude            = $null
                AccuracyMeters       = $null
                AltitudeMeters       = $null
                HorizontalDop        = $null
                PositionDop          = $null
                Detail               = [string]$payload.Error
            }
        }

        $source = [string]$payload.PositionSource

        return [pscustomobject]@{
            Status               = if ($source -eq 'Satellite') {
                                       'SatelliteFix'
                                   }
                                   else {
                                       'NonSatelliteFix'
                                   }
            PositionSource       = $source
            Latitude             = [double]$payload.Latitude
            Longitude            = [double]$payload.Longitude
            AccuracyMeters       = if ($null -ne $payload.AccuracyMeters) {
                                       [double]$payload.AccuracyMeters
                                   }
                                   else {
                                       $null
                                   }
            AltitudeMeters       = if ($null -ne $payload.AltitudeMeters) {
                                       [double]$payload.AltitudeMeters
                                   }
                                   else {
                                       $null
                                   }
            HorizontalDop        = if ($null -ne $payload.HorizontalDop) {
                                       [double]$payload.HorizontalDop
                                   }
                                   else {
                                       $null
                                   }
            PositionDop          = if ($null -ne $payload.PositionDop) {
                                       [double]$payload.PositionDop
                                   }
                                   else {
                                       $null
                                   }
            Detail               = 'Windows WinRT Geolocator high-accuracy result.'
        }
    }
    catch {
        return [pscustomobject]@{
            Status               = 'Unavailable'
            PositionSource       = $null
            Latitude             = $null
            Longitude            = $null
            AccuracyMeters       = $null
            AltitudeMeters       = $null
            HorizontalDop        = $null
            PositionDop          = $null
            Detail               = 'Windows WinRT Geolocator probe failed: {0}' -f $_.Exception.Message
        }
    }
}

function ConvertTo-WindowsGpsLocation {
    param(
        [Parameter(Mandatory)]
        [object]$Probe
    )

    if ($Probe.Status -ne 'SatelliteFix' -or
        $Probe.PositionSource -ne 'Satellite' -or
        $null -eq $Probe.Latitude -or
        $null -eq $Probe.Longitude) {

        return $null
    }

    return [pscustomobject]@{
        Method         = 'WindowsGPS'
        Latitude       = [double]$Probe.Latitude
        Longitude      = [double]$Probe.Longitude
        AccuracyMeters = $Probe.AccuracyMeters
        Site           = $null
        VpnResistant   = $true
        PositionSource = 'Satellite'
        AltitudeMeters = $Probe.AltitudeMeters
        HorizontalDop  = $Probe.HorizontalDop
        PositionDop    = $Probe.PositionDop
        Detail         = 'Verified satellite/GNSS fix from Windows.Devices.Geolocation (PositionSource=Satellite)'
    }
}

# ---------------------------------------------------------------------------
# Native physical location
# ---------------------------------------------------------------------------

function Get-WindowsSystemDeviceLocationInCurrentHost {
    param([Parameter(Mandatory)][int]$Timeout)

    try {
        Add-Type -AssemblyName System.Device -ErrorAction Stop
        $watcher = [System.Device.Location.GeoCoordinateWatcher]::new(
            [System.Device.Location.GeoPositionAccuracy]::High
        )

        try {
            $watcher.MovementThreshold = 1

            if (-not $watcher.TryStart($true, [TimeSpan]::FromSeconds($Timeout))) {
                return $null
            }

            $coordinate = $watcher.Position.Location

            if ($null -eq $coordinate -or $coordinate.IsUnknown) {
                return $null
            }

            $accuracy = $null

            if (-not [double]::IsNaN([double]$coordinate.HorizontalAccuracy) -and
                $coordinate.HorizontalAccuracy -ge 0) {
                $accuracy = [double]$coordinate.HorizontalAccuracy
            }

            return [pscustomobject]@{
                Method         = 'WindowsLocation'
                Latitude       = [double]$coordinate.Latitude
                Longitude      = [double]$coordinate.Longitude
                AccuracyMeters = $accuracy
                Site           = $null
                VpnResistant   = $null
                Detail         = 'Windows Location service provider'
            }
        }
        finally {
            $watcher.Stop()

            if ($watcher -is [System.IDisposable]) {
                $watcher.Dispose()
            }
        }
    }
    catch {
        Write-Verbose ('System.Device.Location is unavailable in this PowerShell host: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-WindowsSystemDeviceLocationViaWindowsPowerShell {
    param([Parameter(Mandatory)][int]$Timeout)

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $powershellExe)) {
        return $null
    }

    $childScript = @"
`$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Device
    `$watcher = [System.Device.Location.GeoCoordinateWatcher]::new([System.Device.Location.GeoPositionAccuracy]::High)
    try {
        `$watcher.MovementThreshold = 1
        if (-not `$watcher.TryStart(`$true, [TimeSpan]::FromSeconds($Timeout))) { exit 2 }

        `$coordinate = `$watcher.Position.Location
        if (`$null -eq `$coordinate -or `$coordinate.IsUnknown) { exit 3 }

        `$accuracy = `$null
        if (-not [double]::IsNaN([double]`$coordinate.HorizontalAccuracy) -and `$coordinate.HorizontalAccuracy -ge 0) {
            `$accuracy = [double]`$coordinate.HorizontalAccuracy
        }

        [pscustomobject]@{
            Latitude       = [double]`$coordinate.Latitude
            Longitude      = [double]`$coordinate.Longitude
            AccuracyMeters = `$accuracy
        } | ConvertTo-Json -Compress
    }
    finally {
        `$watcher.Stop()
        if (`$watcher -is [System.IDisposable]) { `$watcher.Dispose() }
    }
}
catch { exit 1 }
"@

    try {
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
        $raw = & $powershellExe -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>$null
        $json = $raw | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1

        if ([string]::IsNullOrWhiteSpace([string]$json)) {
            return $null
        }

        $position = $json | ConvertFrom-Json

        return [pscustomobject]@{
            Method         = 'WindowsLocation'
            Latitude       = [double]$position.Latitude
            Longitude      = [double]$position.Longitude
            AccuracyMeters = if ($null -ne $position.AccuracyMeters) { [double]$position.AccuracyMeters } else { $null }
            Site           = $null
            VpnResistant   = $null
            Detail         = 'Windows Location service provider via Windows PowerShell compatibility host'
        }
    }
    catch {
        Write-Verbose ('Windows PowerShell location fallback failed: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-WindowsPhysicalLocation {
    param([Parameter(Mandatory)][int]$Timeout)

    # Prefer the modern WinRT provider because it reports PositionSource, allowing
    # us to distinguish a true satellite/GNSS fix from Wi-Fi/IP-derived location.
    $winRtProbe = Get-WindowsWinRtHighAccuracyLocation -Timeout $Timeout

    if ($winRtProbe.Status -eq 'SatelliteFix') {
        return ConvertTo-WindowsGpsLocation -Probe $winRtProbe
    }

    if ($winRtProbe.Status -eq 'NonSatelliteFix' -and
        $null -ne $winRtProbe.Latitude -and
        $null -ne $winRtProbe.Longitude) {

        return [pscustomobject]@{
            Method         = 'WindowsLocation'
            Latitude       = [double]$winRtProbe.Latitude
            Longitude      = [double]$winRtProbe.Longitude
            AccuracyMeters = $winRtProbe.AccuracyMeters
            Site           = $null
            VpnResistant   = $null
            PositionSource = $winRtProbe.PositionSource
            AltitudeMeters = $winRtProbe.AltitudeMeters
            HorizontalDop  = $winRtProbe.HorizontalDop
            PositionDop    = $winRtProbe.PositionDop
            Detail         = 'Windows WinRT Geolocator high-accuracy provider; PositionSource={0}' -f
                                $winRtProbe.PositionSource
        }
    }

    $location = Get-WindowsSystemDeviceLocationInCurrentHost -Timeout $Timeout

    if ($null -ne $location) {
        return $location
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return Get-WindowsSystemDeviceLocationViaWindowsPowerShell -Timeout $Timeout
    }

    return $null
}

function Get-MacPhysicalLocation {
    param([Parameter(Mandatory)][int]$Timeout)

    $osascript = Get-CommandPath -Candidates @('/usr/bin/osascript', 'osascript')

    if ([string]::IsNullOrWhiteSpace($osascript)) {
        return $null
    }

    $jxa = @'
ObjC.import('CoreLocation');

var app = Application.currentApplication();
app.includeStandardAdditions = true;

var manager = $.CLLocationManager.alloc.init;
manager.desiredAccuracy = $.kCLLocationAccuracyBest;
manager.startUpdatingLocation;

var timeoutSeconds = __TIMEOUT__;
var end = Date.now() + (timeoutSeconds * 1000);
var location = null;

while (Date.now() < end) {
    app.delay(0.25);
    location = manager.location;

    if (location) {
        var accuracy = Number(location.horizontalAccuracy);
        if (!isNaN(accuracy) && accuracy >= 0) {
            break;
        }
    }
}

manager.stopUpdatingLocation;

if (!location) {
    JSON.stringify({ error: 'Core Location did not return a fix.' });
} else {
    JSON.stringify({
        latitude: Number(location.coordinate.latitude),
        longitude: Number(location.coordinate.longitude),
        accuracy: Number(location.horizontalAccuracy)
    });
}
'@

    $jxa = $jxa.Replace('__TIMEOUT__', [string]$Timeout)
    $tempJs = Join-Path ([IO.Path]::GetTempPath()) ('Get-DeviceCoords-CoreLocation-{0}.js' -f [guid]::NewGuid().ToString('N'))

    try {
        [IO.File]::WriteAllText($tempJs, $jxa, [Text.UTF8Encoding]::new($false))

        $result = Invoke-NativeCapture `
            -FilePath $osascript `
            -ArgumentList @('-l', 'JavaScript', $tempJs) `
            -TimeoutSeconds ($Timeout + 3)

        if ([string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
            return $null
        }

        $payload = ([string]$result.StdOut).Trim() | ConvertFrom-Json

        if ($payload.PSObject.Properties.Name -contains 'error' -and
            -not [string]::IsNullOrWhiteSpace([string]$payload.error)) {
            Write-Verbose ('macOS Core Location: {0}' -f $payload.error)
            return $null
        }

        if ($null -eq $payload.latitude -or $null -eq $payload.longitude) {
            return $null
        }

        return [pscustomobject]@{
            Method         = 'MacCoreLocation'
            Latitude       = [double]$payload.latitude
            Longitude      = [double]$payload.longitude
            AccuracyMeters = if ($null -ne $payload.accuracy) { [double]$payload.accuracy } else { $null }
            Site           = $null
            VpnResistant   = $null
            Detail         = 'macOS Core Location provider'
        }
    }
    catch {
        Write-Verbose ('macOS Core Location failed: {0}' -f $_.Exception.Message)
        return $null
    }
    finally {
        Remove-Item -LiteralPath $tempJs -Force -ErrorAction SilentlyContinue
    }
}

function Get-LinuxPhysicalLocation {
    param([Parameter(Mandatory)][int]$Timeout)

    $whereAmI = Get-CommandPath -Candidates @(
        'where-am-i',
        'geoclue-where-am-i',
        '/usr/libexec/geoclue-2.0/demos/where-am-i',
        '/usr/lib/geoclue-2.0/demos/where-am-i'
    )

    if ([string]::IsNullOrWhiteSpace($whereAmI)) {
        return $null
    }

    try {
        $result = Invoke-NativeCapture `
            -FilePath $whereAmI `
            -ArgumentList @() `
            -TimeoutSeconds $Timeout `
            -Environment @{ LC_ALL = 'C'; LANG = 'C' }

        $text = '{0}{1}{2}' -f [string]$result.StdOut, [Environment]::NewLine, [string]$result.StdErr

        $latitudeMatch = [regex]::Match($text, '(?im)^\s*Latitude\s*:\s*(-?\d+(?:\.\d+)?)')
        $longitudeMatch = [regex]::Match($text, '(?im)^\s*Longitude\s*:\s*(-?\d+(?:\.\d+)?)')
        $accuracyMatch = [regex]::Match($text, '(?im)^\s*Accuracy\s*:\s*(\d+(?:\.\d+)?)')

        if (-not $latitudeMatch.Success -or -not $longitudeMatch.Success) {
            return $null
        }

        return [pscustomobject]@{
            Method         = 'LinuxGeoClue'
            Latitude       = [double]::Parse($latitudeMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            Longitude      = [double]::Parse($longitudeMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            AccuracyMeters = if ($accuracyMatch.Success) {
                                [double]::Parse($accuracyMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                             }
                             else {
                                $null
                             }
            Site           = $null
            VpnResistant   = $null
            Detail         = 'Linux GeoClue provider via where-am-i'
        }
    }
    catch {
        Write-Verbose ('Linux GeoClue location failed: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-NativePhysicalLocation {
    param([Parameter(Mandatory)][int]$Timeout)

    switch (Get-PlatformName) {
        'Windows' { return Get-WindowsPhysicalLocation -Timeout $Timeout }
        'macOS'   { return Get-MacPhysicalLocation -Timeout $Timeout }
        'Linux'   { return Get-LinuxPhysicalLocation -Timeout $Timeout }
        default   { return $null }
    }
}

function Get-NativeLocationProviderName {
    switch (Get-PlatformName) {
        'Windows' { return 'WindowsLocation' }
        'macOS'   { return 'CoreLocation' }
        'Linux'   {
            $helper = Get-CommandPath -Candidates @(
                'where-am-i',
                'geoclue-where-am-i',
                '/usr/libexec/geoclue-2.0/demos/where-am-i',
                '/usr/lib/geoclue-2.0/demos/where-am-i'
            )

            if ($helper) { return 'GeoClue' }
            return 'GeoClueUnavailable'
        }
        default { return 'Unsupported' }
    }
}

# ---------------------------------------------------------------------------
# Public-IP and VPN evidence
# ---------------------------------------------------------------------------

function Get-PublicIpLocation {
    $preferredIp = $null
    $preferredIpVersion = $null
    $ipSource = $null

    # Prefer IPv4 when the endpoint has one. ipify's api.ipify.org endpoint is
    # IPv4-only, so this avoids a dual-stack host defaulting PublicIp to IPv6.
    try {
        $ipv4Response = Invoke-RestMethod `
            -Uri 'https://api.ipify.org?format=json' `
            -Method Get `
            -TimeoutSec 5 `
            -ErrorAction Stop

        $candidate = [string]$ipv4Response.ip
        $parsedAddress = $null

        if (
            -not [string]::IsNullOrWhiteSpace($candidate) -and
            [System.Net.IPAddress]::TryParse($candidate, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq
                [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
            $preferredIp = $candidate
            $preferredIpVersion = 'IPv4'
            $ipSource = 'ipify IPv4'
        }
    }
    catch {
        Write-Verbose ('Preferred public IPv4 discovery failed: {0}' -f
            $_.Exception.Message)
    }

    try {
        # When IPv4 was discovered, geolocate that exact IPv4 address. Otherwise
        # fall back to ipwho.is resolving the caller, which can return IPv4 or IPv6.
        $lookupUri = if (
            -not [string]::IsNullOrWhiteSpace([string]$preferredIp)
        ) {
            'https://ipwho.is/{0}' -f
                [Uri]::EscapeDataString($preferredIp)
        }
        else {
            'https://ipwho.is/'
        }

        $response = Invoke-RestMethod `
            -Uri $lookupUri `
            -Method Get `
            -TimeoutSec 5 `
            -ErrorAction Stop

        if ($response.success -ne $true) {
            return $null
        }

        $resolvedIp = [string]$response.ip

        if ([string]::IsNullOrWhiteSpace($preferredIp)) {
            $parsedAddress = $null

            if (
                -not [string]::IsNullOrWhiteSpace($resolvedIp) -and
                [System.Net.IPAddress]::TryParse(
                    $resolvedIp,
                    [ref]$parsedAddress
                )
            ) {
                $preferredIpVersion = switch (
                    $parsedAddress.AddressFamily
                ) {
                    ([System.Net.Sockets.AddressFamily]::InterNetwork) {
                        'IPv4'
                    }

                    ([System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                        'IPv6'
                    }

                    default {
                        'Unknown'
                    }
                }
            }
            else {
                $preferredIpVersion = 'Unknown'
            }

            $ipSource = 'ipwho.is fallback'
        }

        Write-Verbose (
            'Public-IP selection: version={0}; ip={1}; source={2}' -f
                $preferredIpVersion,
                $resolvedIp,
                $ipSource
        )

        $publicIpResult = [pscustomobject]@{
            Method       = 'PublicIP'
            IP           = $resolvedIp
            IpVersion    = $preferredIpVersion
            Latitude     = [double]$response.latitude
            Longitude    = [double]$response.longitude
            City         = [string]$response.city
            Region       = [string]$response.region
            Country      = [string]$response.country
            CountryCode  = [string]$response.country_code
            ISP          = if ($null -ne $response.connection) {
                               [string]$response.connection.isp
                           }
                           else {
                               $null
                           }
            Organization = if ($null -ne $response.connection) {
                               [string]$response.connection.org
                           }
                           else {
                               $null
                           }
            ASN          = if ($null -ne $response.connection) {
                               [string]$response.connection.asn
                           }
                           else {
                               $null
                           }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedIp)) {
            $script:IpGeoCache[$resolvedIp] = $publicIpResult
        }

        return $publicIpResult
    }
    catch {
        Write-Verbose ('Public-IP geolocation failed: {0}' -f
            $_.Exception.Message)
        return $null
    }
}

function Get-WindowsNetAdapterSnapshot {
    if ($script:WindowsNetAdapterCached) {
        return @($script:WindowsNetAdapterCache)
    }

    $script:WindowsNetAdapterCached = $true

    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $script:WindowsNetAdapterCache = @(
            Get-NetAdapter -IncludeHidden -ErrorAction Stop
        )
    }
    catch {
        Write-Verbose ('Windows adapter snapshot failed: {0}' -f $_.Exception.Message)
        $script:WindowsNetAdapterCache = @()
    }

    return @($script:WindowsNetAdapterCache)
}

function Get-WindowsVpnConnectionSnapshot {
    if ($script:WindowsVpnConnectionCached) {
        return @($script:WindowsVpnConnectionCache)
    }

    $script:WindowsVpnConnectionCached = $true

    if (-not (Get-Command -Name Get-VpnConnection -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $connections = @()
        $connections += @(Get-VpnConnection -ErrorAction SilentlyContinue)
        $connections += @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)

        $script:WindowsVpnConnectionCache = @(
            $connections |
                Sort-Object Name -Unique
        )
    }
    catch {
        Write-Verbose ('Windows VPN connection snapshot failed: {0}' -f $_.Exception.Message)
        $script:WindowsVpnConnectionCache = @()
    }

    return @($script:WindowsVpnConnectionCache)
}

function Get-WindowsDetectedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()
    $pattern = '(?i)vpn|wireguard|wintun|tap-windows|openvpn|nordlynx|nordvpn|globalprotect|anyconnect|forti(client|net)|zscaler|pulse secure|ivanti|juniper|check\s*point|tailscale|zerotier|cloudflare.*warp|sonicwall|netextender|big-?ip'

    foreach ($adapter in @(Get-WindowsNetAdapterSnapshot)) {
        $adapterText = '{0} {1}' -f $adapter.Name, $adapter.InterfaceDescription

        if ($adapterText -match $pattern) {
            $evidence.Add(
                ('Adapter present: {0} [Status={1}]' -f
                    $adapterText.Trim(),
                    $adapter.Status)
            )
        }
    }

    foreach ($connection in @(Get-WindowsVpnConnectionSnapshot)) {
        $evidence.Add(
            ('Windows VPN configured: {0} [Status={1}]' -f
                $connection.Name,
                $connection.ConnectionStatus)
        )
    }

    return @($evidence | Select-Object -Unique)
}

function Get-WindowsEstablishedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()
    $pattern = '(?i)vpn|wireguard|wintun|tap-windows|openvpn|nordlynx|nordvpn|globalprotect|anyconnect|forti(client|net)|zscaler|pulse secure|ivanti|juniper|check\s*point|tailscale|zerotier|cloudflare.*warp|sonicwall|netextender|big-?ip'

    foreach ($adapter in @(
        Get-WindowsNetAdapterSnapshot |
            Where-Object Status -eq 'Up'
    )) {
        $adapterText = '{0} {1}' -f $adapter.Name, $adapter.InterfaceDescription

        if ($adapterText -match $pattern) {
            $evidence.Add(('Adapter established: {0}' -f $adapterText.Trim()))
        }
    }

    foreach ($connection in @(
        Get-WindowsVpnConnectionSnapshot |
            Where-Object ConnectionStatus -eq 'Connected'
    )) {
        $evidence.Add(('Windows VPN connection: {0}' -f $connection.Name))
    }

    return @($evidence | Select-Object -Unique)
}

function Get-LinuxDetectedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()
    $pattern = '(?i)\b(tun\d*|tap\d*|wg\d*|nordlynx|tailscale\d*|zt[a-z0-9]+|vpn)\b|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler|warp'

    $ip = Get-CommandPath -Candidates @('ip')

    if ($ip) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $ip `
                -ArgumentList @('-o', 'link', 'show') `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match $pattern) {
                    $evidence.Add(('Interface present: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    $nmcli = Get-CommandPath -Candidates @('nmcli')

    if ($nmcli) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $nmcli `
                -ArgumentList @('-t', '-f', 'NAME,TYPE,DEVICE', 'connection', 'show') `
                -TimeoutSeconds 3 `
                -Environment @{ LC_ALL = 'C'; LANG = 'C' }

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '(?i):vpn:' -or
                    $line -match '(?i):wireguard:' -or
                    $line -match $pattern) {
                    $evidence.Add(('NetworkManager configured: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    return @($evidence | Select-Object -Unique)
}

function Get-LinuxEstablishedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()
    $pattern = '(?i)\b(tun\d*|tap\d*|wg\d*|nordlynx|tailscale\d*|zt[a-z0-9]+|vpn)\b|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler|warp'

    $ip = Get-CommandPath -Candidates @('ip')

    if ($ip) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $ip `
                -ArgumentList @('-o', 'link', 'show', 'up') `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match $pattern) {
                    $evidence.Add(('Interface established: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    $nmcli = Get-CommandPath -Candidates @('nmcli')

    if ($nmcli) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $nmcli `
                -ArgumentList @('-t', '-f', 'NAME,TYPE,DEVICE', 'connection', 'show', '--active') `
                -TimeoutSeconds 3 `
                -Environment @{ LC_ALL = 'C'; LANG = 'C' }

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '(?i):vpn:' -or
                    $line -match '(?i):wireguard:' -or
                    $line -match $pattern) {
                    $evidence.Add(('NetworkManager active: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    return @($evidence | Select-Object -Unique)
}

function Get-MacDetectedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()

    $ifconfig = Get-CommandPath -Candidates @('/sbin/ifconfig', 'ifconfig')

    if ($ifconfig) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $ifconfig `
                -ArgumentList @('-a') `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '^(utun\d+|ppp\d+|tun\d+|tap\d+|wg\d+):') {
                    $evidence.Add(('Interface present: {0}' -f $Matches[1]))
                }
            }
        }
        catch { }
    }

    $scutil = Get-CommandPath -Candidates @('/usr/sbin/scutil', 'scutil')

    if ($scutil) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $scutil `
                -ArgumentList @('--nc', 'list') `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '(?i)\((Connected|Disconnected|Connecting|Disconnecting)\)') {
                    $evidence.Add(('Network service configured: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    return @($evidence | Select-Object -Unique)
}

function Get-MacEstablishedVpnEvidence {
    $evidence = [System.Collections.Generic.List[string]]::new()

    $ifconfig = Get-CommandPath -Candidates @('/sbin/ifconfig', 'ifconfig')

    if ($ifconfig) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $ifconfig `
                -ArgumentList @() `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '^(utun\d+|ppp\d+|tun\d+|tap\d+|wg\d+):') {
                    $evidence.Add(('Interface established: {0}' -f $Matches[1]))
                }
            }
        }
        catch { }
    }

    $scutil = Get-CommandPath -Candidates @('/usr/sbin/scutil', 'scutil')

    if ($scutil) {
        try {
            $result = Invoke-NativeCapture `
                -FilePath $scutil `
                -ArgumentList @('--nc', 'list') `
                -TimeoutSeconds 3

            foreach ($line in @([string]$result.StdOut -split "`r?`n")) {
                if ($line -match '(?i)\(Connected\)') {
                    $evidence.Add(('Network service established: {0}' -f $line.Trim()))
                }
            }
        }
        catch { }
    }

    return @($evidence | Select-Object -Unique)
}

function Get-DetectedVpnEvidence {
    switch (Get-PlatformName) {
        'Windows' { return @(Get-WindowsDetectedVpnEvidence) }
        'Linux'   { return @(Get-LinuxDetectedVpnEvidence) }
        'macOS'   { return @(Get-MacDetectedVpnEvidence) }
        default   { return @() }
    }
}

function Get-EstablishedVpnEvidence {
    switch (Get-PlatformName) {
        'Windows' { return @(Get-WindowsEstablishedVpnEvidence) }
        'Linux'   { return @(Get-LinuxEstablishedVpnEvidence) }
        'macOS'   { return @(Get-MacEstablishedVpnEvidence) }
        default   { return @() }
    }
}

# Compatibility helper: "active" now explicitly means established.
function Get-IpLocationByAddress {
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )

    $cacheKey = $IPAddress.Trim()

    if ($script:IpGeoCache.ContainsKey($cacheKey)) {
        return $script:IpGeoCache[$cacheKey]
    }

    try {
        $parsedAddress = $null

        if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsedAddress)) {
            return $null
        }

        $response = Invoke-RestMethod `
            -Uri ('https://ipwho.is/{0}' -f [Uri]::EscapeDataString($IPAddress)) `
            -Method Get `
            -TimeoutSec 5 `
            -ErrorAction Stop

        if ($response.success -ne $true) {
            return $null
        }

        $result = [pscustomobject]@{
            IP           = [string]$response.ip
            Latitude     = [double]$response.latitude
            Longitude    = [double]$response.longitude
            City         = [string]$response.city
            Region       = [string]$response.region
            Country      = [string]$response.country
            CountryCode  = [string]$response.country_code
            ISP          = if ($null -ne $response.connection) {
                               [string]$response.connection.isp
                           }
                           else {
                               $null
                           }
            Organization = if ($null -ne $response.connection) {
                               [string]$response.connection.org
                           }
                           else {
                               $null
                           }
            ASN          = if ($null -ne $response.connection) {
                               [string]$response.connection.asn
                           }
                           else {
                               $null
                           }
        }

        $script:IpGeoCache[$cacheKey] = $result
        return $result
    }
    catch {
        Write-Verbose ('IP geolocation failed for [{0}]: {1}' -f
            $IPAddress,
            $_.Exception.Message)
        return $null
    }
}

function Test-PublicIpv4Address {
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )

    $parsed = $null

    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) {
        return $false
    }

    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $parsed.GetAddressBytes()
    $a = [int]$bytes[0]
    $b = [int]$bytes[1]

    if ($a -eq 10) { return $false }
    if ($a -eq 127) { return $false }
    if ($a -eq 0) { return $false }
    if ($a -ge 224) { return $false }
    if ($a -eq 169 -and $b -eq 254) { return $false }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $false }
    if ($a -eq 192 -and $b -eq 168) { return $false }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $false }

    return $true
}

function Resolve-HostToPublicIpv4 {
    param(
        [Parameter(Mandatory)]
        [string]$HostName
    )

    $cacheKey = $HostName.Trim().ToLowerInvariant()

    if ($script:DnsIpv4Cache.ContainsKey($cacheKey)) {
        return $script:DnsIpv4Cache[$cacheKey]
    }

    if (Test-PublicIpv4Address -IPAddress $HostName) {
        $script:DnsIpv4Cache[$cacheKey] = $HostName
        return $HostName
    }

    try {
        $resolved = @(
            [System.Net.Dns]::GetHostAddresses($HostName) |
                Where-Object {
                    $_.AddressFamily -eq
                        [System.Net.Sockets.AddressFamily]::InterNetwork -and
                    (Test-PublicIpv4Address -IPAddress $_.IPAddressToString)
                } |
                ForEach-Object { $_.IPAddressToString }
        ) | Select-Object -First 1

        if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
            $script:DnsIpv4Cache[$cacheKey] = [string]$resolved
        }

        return $resolved
    }
    catch {
        Write-Verbose ('Unable to resolve VPN endpoint host [{0}]: {1}' -f
            $HostName,
            $_.Exception.Message)
        return $null
    }
}

function Get-CommandLineOptionValue {
    param(
        [AllowNull()]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [string]$OptionName
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $escaped = [regex]::Escape($OptionName)
    $match = [regex]::Match(
        $CommandLine,
        '(?i)(?:^|\s)--{0}(?:=|\s+)(?:"([^"]+)"|''([^'']+)''|([^\s]+))' -f $escaped
    )

    if (-not $match.Success) {
        return $null
    }

    foreach ($groupIndex in 1..3) {
        if (-not [string]::IsNullOrWhiteSpace($match.Groups[$groupIndex].Value)) {
            return $match.Groups[$groupIndex].Value
        }
    }

    return $null
}

function Get-OpenVpnRemoteEndpoint {
    $candidates = [System.Collections.Generic.List[object]]::new()

    try {
        $processes = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name='openvpn.exe'" `
                -ErrorAction SilentlyContinue
        )

        foreach ($process in $processes) {
            # TCP OpenVPN exposes its actual connected remote peer directly.
            if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                try {
                    $tcpPeers = @(
                        Get-NetTCPConnection `
                            -OwningProcess ([int]$process.ProcessId) `
                            -State Established `
                            -ErrorAction SilentlyContinue |
                            Where-Object {
                                Test-PublicIpv4Address -IPAddress ([string]$_.RemoteAddress)
                            }
                    )

                    foreach ($peer in $tcpPeers) {
                        $candidates.Add([pscustomobject]@{
                            IP     = [string]$peer.RemoteAddress
                            Port   = [int]$peer.RemotePort
                            Source = 'OpenVPN established TCP peer'
                        })
                    }
                }
                catch { }
            }

            $commandLine = [string]$process.CommandLine

            # Direct --remote host [port] on the process command line.
            $remoteMatches = [regex]::Matches(
                $commandLine,
                '(?i)(?:^|\s)--remote(?:=|\s+)(?:"([^"]+)"|''([^'']+)''|([^\s]+))(?:\s+(\d+))?'
            )

            foreach ($remoteMatch in $remoteMatches) {
                $host = $null
                foreach ($groupIndex in 1..3) {
                    if (-not [string]::IsNullOrWhiteSpace($remoteMatch.Groups[$groupIndex].Value)) {
                        $host = $remoteMatch.Groups[$groupIndex].Value
                        break
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($host)) {
                    $ip = Resolve-HostToPublicIpv4 -HostName $host
                    if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                        $port = $null
                        if (-not [string]::IsNullOrWhiteSpace($remoteMatch.Groups[4].Value)) {
                            $port = [int]$remoteMatch.Groups[4].Value
                        }

                        $candidates.Add([pscustomobject]@{
                            IP     = $ip
                            Port   = $port
                            Source = 'OpenVPN --remote command line'
                        })
                    }
                }
            }

            # Common OpenVPN invocation is --config <file>; parse remote directives.
            $configPath = Get-CommandLineOptionValue `
                -CommandLine $commandLine `
                -OptionName 'config'

            if (-not [string]::IsNullOrWhiteSpace([string]$configPath) -and
                (Test-Path -LiteralPath $configPath -PathType Leaf)) {

                try {
                    foreach ($line in @(Get-Content -LiteralPath $configPath -ErrorAction Stop)) {
                        if ($line -match '^\s*remote\s+(?:"([^"]+)"|''([^'']+)''|([^\s#;]+))(?:\s+(\d+))?') {
                            $host = $null
                            foreach ($groupIndex in 1..3) {
                                if (-not [string]::IsNullOrWhiteSpace($Matches[$groupIndex])) {
                                    $host = $Matches[$groupIndex]
                                    break
                                }
                            }

                            if (-not [string]::IsNullOrWhiteSpace($host)) {
                                $ip = Resolve-HostToPublicIpv4 -HostName $host
                                if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                                    $port = $null
                                    if (-not [string]::IsNullOrWhiteSpace($Matches[4])) {
                                        $port = [int]$Matches[4]
                                    }

                                    $candidates.Add([pscustomobject]@{
                                        IP     = $ip
                                        Port   = $port
                                        Source = 'OpenVPN config remote'
                                    })
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose ('Unable to parse OpenVPN config [{0}]: {1}' -f
                        $configPath,
                        $_.Exception.Message)
                }
            }
        }
    }
    catch {
        Write-Verbose ('OpenVPN endpoint discovery failed: {0}' -f
            $_.Exception.Message)
    }

    # Prefer an actually-established TCP peer over configured candidates.
    return @(
        $candidates |
            Sort-Object `
                @{ Expression = { if ($_.Source -eq 'OpenVPN established TCP peer') { 0 } else { 1 } } },
                IP,
                Port -Unique
    ) | Select-Object -First 1
}

function Get-WireGuardRemoteEndpoint {
    $candidates = [System.Collections.Generic.List[object]]::new()

    try {
        $processes = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name='wireguard.exe'" `
                -ErrorAction SilentlyContinue
        )

        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine

            $configMatch = [regex]::Match(
                $commandLine,
                '(?i)/(?:tunnelservice|service)\s+(?:"([^"]+)"|''([^'']+)''|([^\s]+))'
            )

            if (-not $configMatch.Success) {
                continue
            }

            $configPath = $null
            foreach ($groupIndex in 1..3) {
                if (-not [string]::IsNullOrWhiteSpace($configMatch.Groups[$groupIndex].Value)) {
                    $configPath = $configMatch.Groups[$groupIndex].Value
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($configPath) -or
                -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                continue
            }

            foreach ($line in @(Get-Content -LiteralPath $configPath -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*Endpoint\s*=\s*(.+?)\s*$') {
                    $endpoint = $Matches[1].Trim()
                    $host = $endpoint
                    $port = $null

                    if ($endpoint -match '^\[([^\]]+)\]:(\d+)$') {
                        $host = $Matches[1]
                        $port = [int]$Matches[2]
                    }
                    elseif ($endpoint -match '^(.+):(\d+)$') {
                        $host = $Matches[1]
                        $port = [int]$Matches[2]
                    }

                    $ip = Resolve-HostToPublicIpv4 -HostName $host

                    if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                        $candidates.Add([pscustomobject]@{
                            IP     = $ip
                            Port   = $port
                            Source = 'WireGuard config Endpoint'
                        })
                    }
                }
            }
        }
    }
    catch {
        Write-Verbose ('WireGuard endpoint discovery failed: {0}' -f
            $_.Exception.Message)
    }

    return @($candidates | Sort-Object IP, Port -Unique) | Select-Object -First 1
}

function Get-WindowsBuiltInVpnRemoteEndpoint {
    try {
        foreach ($connection in @(
            Get-WindowsVpnConnectionSnapshot |
                Where-Object ConnectionStatus -eq 'Connected'
        )) {
            $server = [string]$connection.ServerAddress

            if (-not [string]::IsNullOrWhiteSpace($server)) {
                $ip = Resolve-HostToPublicIpv4 -HostName $server

                if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                    return [pscustomobject]@{
                        IP     = $ip
                        Port   = $null
                        Source = 'Windows VPN ServerAddress'
                    }
                }
            }
        }
    }
    catch {
        Write-Verbose ('Windows built-in VPN endpoint discovery failed: {0}' -f
            $_.Exception.Message)
    }

    return $null
}

function Test-WindowsVpnFullTunnelRoute {
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex
    )

    if (-not (Get-Command -Name Get-NetRoute -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $prefixes = @(
            Get-NetRoute `
                -InterfaceIndex $InterfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
                Select-Object -ExpandProperty DestinationPrefix
        )

        if ($prefixes -contains '0.0.0.0/0') {
            return $true
        }

        return (
            ($prefixes -contains '0.0.0.0/1') -and
            ($prefixes -contains '128.0.0.0/1')
        )
    }
    catch {
        Write-Verbose ('Unable to inspect VPN routes for interface index [{0}]: {1}' -f
            $InterfaceIndex,
            $_.Exception.Message)
        return $false
    }
}

function Get-WindowsVpnExitPublicHops {
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex,

        [int]$MaxPublicHops = 2
    )

    if (-not (Test-WindowsVpnFullTunnelRoute -InterfaceIndex $InterfaceIndex)) {
        Write-Verbose ('VPN exit-hop trace skipped for interface index [{0}] because it is not a confirmed full-tunnel IPv4 route.' -f
            $InterfaceIndex)
        return @()
    }

    $tracert = Get-CommandPath -Candidates @(
        $(if (-not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
            Join-Path -Path $env:SystemRoot -ChildPath 'System32\tracert.exe'
        }),
        'tracert.exe'
    )

    if ([string]::IsNullOrWhiteSpace([string]$tracert)) {
        Write-Verbose 'VPN exit-hop trace skipped because tracert.exe was not found.'
        return @()
    }

    $target = '1.1.1.1'

    try {
        $capture = Invoke-NativeCapture `
            -FilePath $tracert `
            -ArgumentList @(
                '-4',
                '-d',
                '-h', '6',
                '-w', '500',
                $target
            ) `
            -TimeoutSeconds 12

        $publicHops = [System.Collections.Generic.List[string]]::new()

        foreach ($line in @([string]$capture.StdOut -split "`r?`n")) {
            $matches = [regex]::Matches(
                $line,
                '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)'
            )

            foreach ($match in $matches) {
                $candidate = [string]$match.Value

                if ($candidate -eq $target) {
                    continue
                }

                if (-not (Test-PublicIpv4Address -IPAddress $candidate)) {
                    continue
                }

                if (-not $publicHops.Contains($candidate)) {
                    $publicHops.Add($candidate)
                }

                if ($publicHops.Count -ge $MaxPublicHops) {
                    break
                }
            }

            if ($publicHops.Count -ge $MaxPublicHops) {
                break
            }
        }

        if ($publicHops.Count -eq 0) {
            Write-Verbose ('VPN exit-hop trace found no public IPv4 hops: interfaceIndex={0}; target={1}' -f
                $InterfaceIndex,
                $target)
            return @()
        }

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($hopIp in @($publicHops)) {
            $geo = Get-IpLocationByAddress -IPAddress $hopIp

            $results.Add([pscustomobject]@{
                IP        = $hopIp
                Latitude  = if ($null -ne $geo) { $geo.Latitude } else { $null }
                Longitude = if ($null -ne $geo) { $geo.Longitude } else { $null }
                City      = if ($null -ne $geo) { $geo.City } else { $null }
                Region    = if ($null -ne $geo) { $geo.Region } else { $null }
                Country   = if ($null -ne $geo) { $geo.Country } else { $null }
            })
        }

        Write-Verbose ('VPN exit-hop trace: interfaceIndex={0}; publicHops={1}' -f
            $InterfaceIndex,
            (@($results | ForEach-Object { $_.IP }) -join ' > '))

        return @($results)
    }
    catch {
        Write-Verbose ('VPN exit-hop trace failed for interface index [{0}]: {1}' -f
            $InterfaceIndex,
            $_.Exception.Message)
        return @()
    }
}

function Get-WindowsEstablishedVpnTunnelDetails {
    $details = [System.Collections.Generic.List[object]]::new()
    $pattern = '(?i)vpn|wireguard|wintun|tap-windows|openvpn|nordlynx|nordvpn|globalprotect|anyconnect|forti(client|net)|zscaler|pulse secure|ivanti|juniper|check\s*point|tailscale|zerotier|cloudflare.*warp|sonicwall|netextender|big-?ip'

    try {
        $adapters = @(
            Get-WindowsNetAdapterSnapshot |
                Where-Object {
                    $_.Status -eq 'Up' -and
                    ('{0} {1}' -f $_.Name, $_.InterfaceDescription) -match $pattern
                }
        )

        foreach ($adapter in $adapters) {
            $adapterText = '{0} {1}' -f $adapter.Name, $adapter.InterfaceDescription

            $identity = @(
                Get-VpnTunnelIdentity `
                    -Evidence @('Adapter established: {0}' -f $adapterText.Trim())
            ) | Select-Object -First 1

            if ([string]::IsNullOrWhiteSpace([string]$identity)) {
                $identity = 'VPN/Tunnel'
            }

            $localIpv4 = $null

            if (Get-Command -Name Get-NetIPAddress -ErrorAction SilentlyContinue) {
                $localIpv4 = @(
                    Get-NetIPAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) -and
                            $_.IPAddress -notmatch '^169\.254\.' -and
                            $_.IPAddress -ne '127.0.0.1'
                        } |
                        Sort-Object `
                            @{ Expression = { if ($_.SkipAsSource) { 1 } else { 0 } } },
                            PrefixLength -Descending |
                        Select-Object -ExpandProperty IPAddress
                ) | Select-Object -First 1
            }

            $isPublicTunnelIpv4 = $false
            $geo = $null

            if (-not [string]::IsNullOrWhiteSpace([string]$localIpv4)) {
                $isPublicTunnelIpv4 = Test-PublicIpv4Address -IPAddress $localIpv4

                if ($isPublicTunnelIpv4) {
                    $geo = Get-IpLocationByAddress -IPAddress $localIpv4
                }
            }

            $fullTunnel = Test-WindowsVpnFullTunnelRoute `
                -InterfaceIndex ([int]$adapter.ifIndex)

            $exitHops = if ($fullTunnel) {
                @(
                    Get-WindowsVpnExitPublicHops `
                        -InterfaceIndex ([int]$adapter.ifIndex) `
                        -MaxPublicHops 2
                )
            }
            else {
                @()
            }

            Write-Verbose ('VPN tunnel adapter: identity={0}; interface={1}; tunnelIPv4={2}; public={3}; fullTunnel={4}; exitHopCount={5}' -f
                $identity,
                $adapter.Name,
                $(if ([string]::IsNullOrWhiteSpace([string]$localIpv4)) { '<none>' } else { $localIpv4 }),
                $isPublicTunnelIpv4,
                $fullTunnel,
                @($exitHops).Count)

            $details.Add([pscustomobject]@{
                Identity       = [string]$identity
                InterfaceName  = [string]$adapter.Name
                InterfaceIndex = [int]$adapter.ifIndex
                TunnelIPv4     = $localIpv4
                IsPublicIPv4   = $isPublicTunnelIpv4
                FullTunnel     = $fullTunnel
                ExitHops       = @($exitHops)
                Latitude       = if ($null -ne $geo) { $geo.Latitude } else { $null }
                Longitude      = if ($null -ne $geo) { $geo.Longitude } else { $null }
                City           = if ($null -ne $geo) { $geo.City } else { $null }
                Region         = if ($null -ne $geo) { $geo.Region } else { $null }
                Country        = if ($null -ne $geo) { $geo.Country } else { $null }
            })
        }
    }
    catch {
        Write-Verbose ('Established Windows VPN tunnel enrichment failed: {0}' -f
            $_.Exception.Message)
    }

    return @($details)
}

function Get-LinuxEstablishedVpnTunnelDetails {
    Write-Verbose 'Linux established tunnel remote-endpoint enrichment is not implemented in v3.23; returning identity-only evidence rather than mislabeling normal public egress as the tunnel endpoint.'
    return @()
}

function Get-MacEstablishedVpnTunnelDetails {
    Write-Verbose 'macOS established tunnel remote-endpoint enrichment is not implemented in v3.23; returning identity-only evidence rather than mislabeling normal public egress as the tunnel endpoint.'
    return @()
}

function Get-EstablishedVpnTunnelDetails {
    switch (Get-PlatformName) {
        'Windows' { return @(Get-WindowsEstablishedVpnTunnelDetails) }
        'Linux'   { return @(Get-LinuxEstablishedVpnTunnelDetails) }
        'macOS'   { return @(Get-MacEstablishedVpnTunnelDetails) }
        default   { return @() }
    }
}

function Format-EstablishedVpnTunnel {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Details,

        [AllowNull()]
        [string]$FallbackIdentity
    )

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($detail in @($Details)) {
        $identity = if (
            -not [string]::IsNullOrWhiteSpace([string]$detail.Identity)
        ) {
            [string]$detail.Identity
        }
        else {
            'VPN/Tunnel'
        }

        $tunnelIp = [string]$detail.TunnelIPv4

        if ([string]::IsNullOrWhiteSpace($tunnelIp)) {
            $parts.Add(('{0} = No tunnel IPv4 assigned' -f $identity))
            continue
        }

        # A public tunnel adapter address can be geolocated directly.
        if ($detail.IsPublicIPv4 -eq $true) {
            if ($null -ne $detail.Latitude -and $null -ne $detail.Longitude) {
                $latText = ([double]$detail.Latitude).ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                $lonText = ([double]$detail.Longitude).ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )

                $cityParts = @(
                    [string]$detail.City,
                    [string]$detail.Region,
                    [string]$detail.Country
                ) |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    }

                $geoCity = if (@($cityParts).Count -gt 0) {
                    $cityParts -join ', '
                }
                else {
                    'Unknown location'
                }

                $parts.Add(
                    ('{0} = {1} - {2},{3} - {4}' -f
                        $identity,
                        $tunnelIp,
                        $latText,
                        $lonText,
                        $geoCity)
                )
            }
            else {
                $parts.Add(
                    ('{0} = {1} - Public tunnel IP - No geolocation result' -f
                        $identity,
                        $tunnelIp)
                )
            }

            continue
        }

        # Private tunnel IP: for a confirmed full-tunnel route, annotate the first
        # one or two public hops after the private overlay as an exit-location
        # heuristic. These are routing observations, not claimed VPN-server IPs.
        $exitHops = @($detail.ExitHops)

        if ($exitHops.Count -gt 0) {
            $hopIps = @(
                $exitHops |
                    ForEach-Object { [string]$_.IP }
            ) -join ' > '

            $primaryGeo = @(
                $exitHops |
                    Where-Object {
                        $null -ne $_.Latitude -and
                        $null -ne $_.Longitude
                    }
            ) | Select-Object -First 1

            if ($null -ne $primaryGeo) {
                $latText = ([double]$primaryGeo.Latitude).ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                $lonText = ([double]$primaryGeo.Longitude).ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )

                $cityParts = @(
                    [string]$primaryGeo.City,
                    [string]$primaryGeo.Region,
                    [string]$primaryGeo.Country
                ) |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    }

                $geoCity = if (@($cityParts).Count -gt 0) {
                    $cityParts -join ', '
                }
                else {
                    'Unknown location'
                }

                $parts.Add(
                    ('{0} = {1} - ExitHops {2} - {3},{4} - {5}' -f
                        $identity,
                        $tunnelIp,
                        $hopIps,
                        $latText,
                        $lonText,
                        $geoCity)
                )
            }
            else {
                $parts.Add(
                    ('{0} = {1} - ExitHops {2} - No geolocation result' -f
                        $identity,
                        $tunnelIp,
                        $hopIps)
                )
            }

            continue
        }

        $parts.Add(
            ('{0} = {1} - Private tunnel IP - Exit location unavailable' -f
                $identity,
                $tunnelIp)
        )
    }

    if ($parts.Count -gt 0) {
        return ($parts | Select-Object -Unique) -join '; '
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$FallbackIdentity)) {
        return ('{0} = No tunnel IPv4 assigned' -f $FallbackIdentity)
    }

    return 'None'
}


function Get-VpnTunnelIdentity {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Evidence
    )

    $identities = [System.Collections.Generic.List[string]]::new()

    foreach ($item in @($Evidence)) {
        $text = [string]$item

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        # Prefer stable product/vendor identities instead of returning the entire
        # adapter description. A machine can legitimately expose more than one.
        $identity = switch -Regex ($text) {
            '(?i)Cisco\s+(?:Secure\s+Client|AnyConnect)|\bAnyConnect\b' {
                'Cisco AnyConnect'
                break
            }

            '(?i)\bGlobalProtect\b|Palo\s+Alto' {
                'Palo Alto GlobalProtect'
                break
            }

            '(?i)\bZscaler\b' {
                'Zscaler'
                break
            }

            '(?i)\bForti(?:Client|Net)?\b|\bFortinet\b' {
                'Fortinet FortiClient'
                break
            }

            '(?i)\bWireGuard\b|\bWintun\b|\bwg\d*\b' {
                'WireGuard'
                break
            }

            '(?i)\bOpenVPN\b|TAP-Windows' {
                'OpenVPN'
                break
            }

            '(?i)\bNordLynx\b|\bNordVPN\b' {
                'NordVPN'
                break
            }

            '(?i)\bTailscale\b' {
                'Tailscale'
                break
            }

            '(?i)\bZeroTier\b|\bzt[a-z0-9]+\b' {
                'ZeroTier'
                break
            }

            '(?i)\bCheck\s*Point\b' {
                'Check Point VPN'
                break
            }

            '(?i)\bPulse\s+Secure\b|\bIvanti\s+Connect\s+Secure\b' {
                'Ivanti/Pulse Secure'
                break
            }

            '(?i)\bJuniper\b' {
                'Juniper VPN'
                break
            }

            '(?i)\bSonicWall\b|\bNetExtender\b' {
                'SonicWall NetExtender'
                break
            }

            '(?i)\bF5\b.*\bVPN\b|\bBIG-?IP\b.*\bEdge\b' {
                'F5 BIG-IP Edge'
                break
            }

            '(?i)\bCloudflare\b.*\bWARP\b|\bWARP\b' {
                'Cloudflare WARP'
                break
            }

            '(?i)\bWindows VPN (?:connection|configured):\s*([^\[]+)' {
                'Windows VPN: {0}' -f $Matches[1].Trim()
                break
            }

            '(?i)\bVPN\b' {
                # Generic fallback when the evidence clearly indicates a VPN but
                # the product is not in the canonical mapping above.
                'VPN/Tunnel'
                break
            }

            default {
                $null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$identity) -and
            -not $identities.Contains([string]$identity)) {
            $identities.Add([string]$identity)
        }
    }

    return @($identities)
}

# ---------------------------------------------------------------------------
# Shared scoring/output helpers
# ---------------------------------------------------------------------------

function Get-DistanceKm {
    param(
        [Parameter(Mandatory)][double]$Latitude1,
        [Parameter(Mandatory)][double]$Longitude1,
        [Parameter(Mandatory)][double]$Latitude2,
        [Parameter(Mandatory)][double]$Longitude2
    )

    $earthRadiusKm = 6371.0088
    $degreesToRadians = [Math]::PI / 180.0
    $lat1 = $Latitude1 * $degreesToRadians
    $lat2 = $Latitude2 * $degreesToRadians
    $deltaLat = ($Latitude2 - $Latitude1) * $degreesToRadians
    $deltaLon = ($Longitude2 - $Longitude1) * $degreesToRadians

    $a = [Math]::Sin($deltaLat / 2) * [Math]::Sin($deltaLat / 2) +
         [Math]::Cos($lat1) * [Math]::Cos($lat2) *
         [Math]::Sin($deltaLon / 2) * [Math]::Sin($deltaLon / 2)

    $c = 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))

    return [Math]::Round($earthRadiusKm * $c, 2)
}

function Get-CanadianMajorCityGeoTable {
    # Coarse operational envelopes for local city bucketing. These are intentionally
    # practical city-area ranges, not legal municipal boundaries.
    return @(
        [pscustomobject]@{ City='St. John''s';     Province='NL'; CenterLat=47.5615; CenterLon=-52.7126;  MinLat=47.48; MaxLat=47.66; MinLon=-52.85;  MaxLon=-52.62 }
        [pscustomobject]@{ City='Charlottetown';   Province='PE'; CenterLat=46.2382; CenterLon=-63.1311;  MinLat=46.20; MaxLat=46.30; MinLon=-63.20;  MaxLon=-63.05 }
        [pscustomobject]@{ City='Halifax';         Province='NS'; CenterLat=44.6488; CenterLon=-63.5752;  MinLat=44.55; MaxLat=44.75; MinLon=-63.75;  MaxLon=-63.45 }
        [pscustomobject]@{ City='Moncton';         Province='NB'; CenterLat=46.0878; CenterLon=-64.7782;  MinLat=46.00; MaxLat=46.18; MinLon=-64.90;  MaxLon=-64.68 }
        [pscustomobject]@{ City='Fredericton';     Province='NB'; CenterLat=45.9636; CenterLon=-66.6431;  MinLat=45.90; MaxLat=46.05; MinLon=-66.75;  MaxLon=-66.55 }
        [pscustomobject]@{ City='Quebec City';     Province='QC'; CenterLat=46.8139; CenterLon=-71.2080;  MinLat=46.72; MaxLat=46.92; MinLon=-71.40;  MaxLon=-71.10 }
        [pscustomobject]@{ City='Montreal';        Province='QC'; CenterLat=45.5019; CenterLon=-73.5674;  MinLat=45.40; MaxLat=45.70; MinLon=-73.95;  MaxLon=-73.45 }
        [pscustomobject]@{ City='Ottawa';          Province='ON'; CenterLat=45.4215; CenterLon=-75.6972;  MinLat=45.25; MaxLat=45.55; MinLon=-75.95;  MaxLon=-75.45 }
        [pscustomobject]@{ City='Kingston';        Province='ON'; CenterLat=44.2312; CenterLon=-76.4860;  MinLat=44.15; MaxLat=44.32; MinLon=-76.65;  MaxLon=-76.35 }
        [pscustomobject]@{ City='Toronto';         Province='ON'; CenterLat=43.6532; CenterLon=-79.3832;  MinLat=43.55; MaxLat=43.85; MinLon=-79.65;  MaxLon=-79.10 }
        [pscustomobject]@{ City='Hamilton';        Province='ON'; CenterLat=43.2557; CenterLon=-79.8711;  MinLat=43.15; MaxLat=43.35; MinLon=-80.05;  MaxLon=-79.70 }
        [pscustomobject]@{ City='London';          Province='ON'; CenterLat=42.9849; CenterLon=-81.2453;  MinLat=42.90; MaxLat=43.10; MinLon=-81.40;  MaxLon=-81.10 }
        [pscustomobject]@{ City='Windsor';         Province='ON'; CenterLat=42.3149; CenterLon=-83.0364;  MinLat=42.22; MaxLat=42.38; MinLon=-83.15;  MaxLon=-82.90 }
        [pscustomobject]@{ City='Thunder Bay';     Province='ON'; CenterLat=48.3809; CenterLon=-89.2477;  MinLat=48.25; MaxLat=48.50; MinLon=-89.45;  MaxLon=-89.05 }
        [pscustomobject]@{ City='Winnipeg';        Province='MB'; CenterLat=49.8951; CenterLon=-97.1384;  MinLat=49.75; MaxLat=50.05; MinLon=-97.35;  MaxLon=-96.95 }
        [pscustomobject]@{ City='Regina';          Province='SK'; CenterLat=50.4452; CenterLon=-104.6189; MinLat=50.35; MaxLat=50.55; MinLon=-104.75; MaxLon=-104.45 }
        [pscustomobject]@{ City='Saskatoon';       Province='SK'; CenterLat=52.1579; CenterLon=-106.6702; MinLat=52.05; MaxLat=52.25; MinLon=-106.85; MaxLon=-106.50 }
        [pscustomobject]@{ City='Edmonton';        Province='AB'; CenterLat=53.5461; CenterLon=-113.4938; MinLat=53.40; MaxLat=53.72; MinLon=-113.75; MaxLon=-113.25 }
        [pscustomobject]@{ City='Calgary';         Province='AB'; CenterLat=51.0447; CenterLon=-114.0719; MinLat=50.85; MaxLat=51.20; MinLon=-114.30; MaxLon=-113.85 }
        [pscustomobject]@{ City='Kelowna';         Province='BC'; CenterLat=49.8880; CenterLon=-119.4960; MinLat=49.75; MaxLat=50.05; MinLon=-119.70; MaxLon=-119.30 }
        [pscustomobject]@{ City='Vancouver';       Province='BC'; CenterLat=49.2827; CenterLon=-123.1207; MinLat=49.18; MaxLat=49.38; MinLon=-123.30; MaxLon=-122.95 }
        [pscustomobject]@{ City='Victoria';        Province='BC'; CenterLat=48.4284; CenterLon=-123.3656; MinLat=48.35; MaxLat=48.52; MinLon=-123.50; MaxLon=-123.25 }
    )
}

function Resolve-CanadianMajorCityLocal {
    param(
        [Parameter(Mandatory)]
        [double]$Latitude,

        [Parameter(Mandatory)]
        [double]$Longitude
    )

    # Canadian-only resolver. Reject obviously non-Canadian coordinates before
    # attempting a nearest-city calculation.
    $insideCanadaEnvelope = (
        $Latitude -ge 41.0 -and
        $Latitude -le 84.0 -and
        $Longitude -ge -142.0 -and
        $Longitude -le -52.0
    )

    if (-not $insideCanadaEnvelope) {
        return $null
    }

    $cities = @(Get-CanadianMajorCityGeoTable)

    if ($cities.Count -eq 0) {
        return $null
    }

    $evaluated = @(
        foreach ($city in $cities) {
            $insideRange = (
                $Latitude  -ge [double]$city.MinLat -and
                $Latitude  -le [double]$city.MaxLat -and
                $Longitude -ge [double]$city.MinLon -and
                $Longitude -le [double]$city.MaxLon
            )

            $distanceKm = Get-DistanceKm `
                -Latitude1 $Latitude `
                -Longitude1 $Longitude `
                -Latitude2 ([double]$city.CenterLat) `
                -Longitude2 ([double]$city.CenterLon)

            [pscustomobject]@{
                City                  = [string]$city.City
                Province              = [string]$city.Province
                CenterLat             = [double]$city.CenterLat
                CenterLon             = [double]$city.CenterLon
                MinLat                = [double]$city.MinLat
                MaxLat                = [double]$city.MaxLat
                MinLon                = [double]$city.MinLon
                MaxLon                = [double]$city.MaxLon
                InsideRange           = [bool]$insideRange
                DistanceFromCenterKm  = [double]$distanceKm
            }
        }
    )

    $inRangeMatches = @(
        $evaluated |
            Where-Object InsideRange |
            Sort-Object DistanceFromCenterKm
    )

    if ($inRangeMatches.Count -gt 0) {
        $selected = $inRangeMatches | Select-Object -First 1
        $matchType = 'InsideRange'
    }
    else {
        $selected = $evaluated |
            Sort-Object DistanceFromCenterKm |
            Select-Object -First 1

        if ($null -eq $selected -or
            [double]$selected.DistanceFromCenterKm -gt 200) {
            return $null
        }

        $matchType = 'NearestCenter'
    }

    if ($null -eq $selected) {
        return $null
    }

    return [pscustomobject]@{
        City                 = $selected.City
        Province             = $selected.Province
        MatchType            = $matchType
        InsideRange          = [bool]$selected.InsideRange
        DistanceFromCenterKm = [double]$selected.DistanceFromCenterKm
        CenterLat            = [double]$selected.CenterLat
        CenterLon            = [double]$selected.CenterLon
        MinLat               = [double]$selected.MinLat
        MaxLat               = [double]$selected.MaxLat
        MinLon               = [double]$selected.MinLon
        MaxLon               = [double]$selected.MaxLon
    }
}

function Get-LocationConfidence {
    param([Parameter(Mandatory)][object]$Location)

    if ($Location.Method -eq 'PublicIP') { return 'Low' }
    if ($Location.Method -eq 'WindowsGPS') { return 'High' }
    if ($Location.Method -eq 'KnownWiFi') { return 'High' }
    if ($Location.Method -eq 'KnownBluetooth') { return 'High' }
    if ($Location.Method -eq 'WindowsLocationOG') { return 'Medium' }

    if ($null -eq $Location.AccuracyMeters) {
        return 'Medium'
    }

    if ([double]$Location.AccuracyMeters -le 250) {
        return 'High'
    }

    if ([double]$Location.AccuracyMeters -le 5000) {
        return 'Medium'
    }

    return 'Low'
}

function Invoke-OgDeviceCoordsScript {
    param(
        [Parameter(Mandatory)]
        [string]$Platform
    )

    if ($Platform -ne 'Windows') {
        return [pscustomobject]@{
            Succeeded      = $false
            Latitude       = $null
            Longitude      = $null
            AccuracyMeters = $null
            MapUri         = $null
            Detail         = 'Revised OG Get-DeviceCoords script is Windows-only.'
        }
    }

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        return [pscustomobject]@{
            Succeeded = $false
            Latitude  = $null
            Longitude = $null
            MapUri    = $null
            Detail    = 'Windows PowerShell 5.1 executable was not found.'
        }
    }

    # Exact body of the freshly supplied revised OG Get-DeviceCoords script.
    # Its logical output is:
    #   coordinates: $lat,$long
    #   map URI:     https://www.google.com/maps/search/?api=1&query=$lat,$long
    #
    # "$lat,$long" emits two pipeline values in PowerShell, so this wrapper accepts both
    # two standalone numeric lines and a single comma-delimited coordinate line.
    $ogScript = @'
$ProgressPreference = 'SilentlyContinue'

try {
    $serviceSids = @('S-1-5-18','S-1-5-19','S-1-5-20')
    $targetSids = @()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = if ($null -ne $identity.User) {
        [string]$identity.User.Value
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($currentSid) -and
        $currentSid -notin $serviceSids) {
        $targetSids = @($currentSid)
    }
    else {
        $consoleUser = $null

        try {
            $computerSystem = Get-WmiObject `
                -Class Win32_ComputerSystem `
                -Property UserName `
                -ErrorAction Stop
            $consoleUser = [string]$computerSystem.UserName
        }
        catch { }

        if (-not [string]::IsNullOrWhiteSpace($consoleUser)) {
            try {
                $account = New-Object `
                    System.Security.Principal.NTAccount($consoleUser)
                $consoleSid = [string](
                    $account.Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    ).Value
                )

                if (-not [string]::IsNullOrWhiteSpace($consoleSid)) {
                    $targetSids = @($consoleSid)
                }
            }
            catch { }
        }
    }

    foreach ($sid in @($targetSids)) {
        $LocationPath =
            "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"

        if (Test-Path -LiteralPath ("Registry::HKEY_USERS\$sid")) {
            if (-not (Test-Path -LiteralPath $LocationPath)) {
                $null = New-Item -Path $LocationPath -Force -ErrorAction Stop
            }

            Set-ItemProperty `
                -LiteralPath $LocationPath `
                -Name Value `
                -Value Allow `
                -ErrorAction Stop
        }
    }
}
catch {
    Write-Verbose (
        'Unable to temporarily allow Location in the interactive user HKU hive: {0}' -f
        $_.Exception.Message
    )
}

Add-Type -AssemblyName System.Device
$GeoWatcher = New-Object System.Device.Location.GeoCoordinateWatcher
sleep 2
$allowed = $GeoWatcher.permission.value__
if($allowed -eq 2){ 
    "GeoCoordinateWatcherPermissionDenied"
    break 
}
$GeoWatcher.Start()
 
write-host "Fetching GeoLocator Coordinates."
$chk = 0
while($GeoWatcher.Position.Location.IsUnknown -and $chk -le 30){
    "waiting for Geowatcher to get an initial position..."|out-string
    sleep -Seconds 2
    $chk++
}

if(($GeoWatcher.Position.Location.Latitude.tostring() -ne "NaN")){
$lat = $GeoWatcher.Position.Location.Latitude
$long = $GeoWatcher.Position.Location.Longitude
$accuracy = $GeoWatcher.Position.Location.HorizontalAccuracy
$lat,$long
'AccuracyMeters={0}' -f $accuracy
'https://www.google.com/maps/search/?api=1&query={0},{1}' -f $lat,$long
}
else{
    "GeoCoordinateWatcherNoFix"
}
 
$GeoWatcher.Stop()
'@

    try {
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($ogScript)
        )

        $capture = Invoke-NativeCapture `
            -FilePath $powershellExe `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
            -TimeoutSeconds 75

        $stdout = [string]$capture.StdOut
        $stderr = [string]$capture.StdErr

        $lines = @(
            $stdout -split "`r?`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        # The OG script has explicit terminal messages. These are authoritative and
        # must outrank child-process stderr, which Windows PowerShell can populate with
        # serialized CLIXML progress records such as "Preparing modules for first use."
        $ogPolicyDenied = (
            @(
                $lines |
                    Where-Object {
                        $_ -eq 'GeoCoordinateWatcherPermissionDenied'
                    }
            ).Count -gt 0
        )

        $ogNoFix = (
            @(
                $lines |
                    Where-Object {
                        $_ -eq 'GeoCoordinateWatcherNoFix'
                    }
            ).Count -gt 0
        )

        if ($ogPolicyDenied) {
            return [pscustomobject]@{
                Succeeded      = $false
                Latitude       = $null
                Longitude      = $null
                AccuracyMeters = $null
                MapUri         = $null
                Detail         = 'Windows Location Services GeoCoordinateWatcher access was denied by Windows location/privacy policy.'
            }
        }

        if ($ogNoFix) {
            return [pscustomobject]@{
                Succeeded      = $false
                Latitude       = $null
                Longitude      = $null
                AccuracyMeters = $null
                MapUri         = $null
                Detail         = 'Windows Location Services GeoCoordinateWatcher did not return a position.'
            }
        }

        # Capture the exact Maps URI emitted by the revised OG script.
        $mapUri = $lines |
            Where-Object {
                $_ -match '^https://www\.google\.com/maps/search/\?api=1&query='
            } |
            Select-Object -Last 1

        $accuracyMeters = $null
        $accuracyLine = $lines |
            Where-Object {
                $_ -match '^AccuracyMeters='
            } |
            Select-Object -Last 1

        if (-not [string]::IsNullOrWhiteSpace([string]$accuracyLine)) {
            $accuracyValue = ([string]$accuracyLine -replace '^AccuracyMeters=', '').Trim()
            $parsedAccuracy = 0.0

            if ([double]::TryParse(
                    $accuracyValue,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsedAccuracy
                ) -and
                -not [double]::IsNaN($parsedAccuracy) -and
                -not [double]::IsInfinity($parsedAccuracy) -and
                $parsedAccuracy -gt 0) {

                $accuracyMeters = [double]$parsedAccuracy
            }
        }

        $latitude = 0.0
        $longitude = 0.0
        $coordinateParsed = $false

        # Form 1: one logical coordinate string: "lat,long".
        $pairLines = @(
            $lines |
                Where-Object {
                    $_ -match '^\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*$'
                }
        )

        if ($pairLines.Count -gt 0) {
            $pairMatch = [regex]::Match(
                $pairLines[$pairLines.Count - 1],
                '^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$'
            )

            if ($pairMatch.Success) {
                $latOk = [double]::TryParse(
                    $pairMatch.Groups[1].Value,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$latitude
                )
                $lonOk = [double]::TryParse(
                    $pairMatch.Groups[2].Value,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$longitude
                )

                $coordinateParsed = ($latOk -and $lonOk)
            }
        }

        # Form 2: the supplied "$lat,$long" expression emits two standalone numeric
        # pipeline values. Take the last two numeric-only lines before/alongside the URI.
        if (-not $coordinateParsed) {
            $numericLines = @(
                $lines |
                    Where-Object {
                        $_ -match '^\s*-?\d+(?:\.\d+)?\s*$'
                    }
            )

            if ($numericLines.Count -ge 2) {
                $latCandidate = $numericLines[$numericLines.Count - 2]
                $lonCandidate = $numericLines[$numericLines.Count - 1]

                $latOk = [double]::TryParse(
                    $latCandidate,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$latitude
                )
                $lonOk = [double]::TryParse(
                    $lonCandidate,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$longitude
                )

                $coordinateParsed = ($latOk -and $lonOk)
            }
        }

        # Last-resort coordinate recovery from the OG-provided Maps URI itself.
        if (-not $coordinateParsed -and
            -not [string]::IsNullOrWhiteSpace([string]$mapUri)) {

            $uriMatch = [regex]::Match(
                [string]$mapUri,
                '[?&]query=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)'
            )

            if ($uriMatch.Success) {
                $latOk = [double]::TryParse(
                    $uriMatch.Groups[1].Value,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$latitude
                )
                $lonOk = [double]::TryParse(
                    $uriMatch.Groups[2].Value,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$longitude
                )

                $coordinateParsed = ($latOk -and $lonOk)
            }
        }

        if (-not $coordinateParsed) {
            $stderrIsCliXmlProgress = (
                -not [string]::IsNullOrWhiteSpace($stderr) -and
                $stderr.TrimStart().StartsWith('#< CLIXML') -and
                $stderr -match '(?i)Preparing modules for first use'
            )

            $detail = if ($capture.TimedOut) {
                'Revised OG Get-DeviceCoords script timed out before returning coordinates.'
            }
            elseif (
                -not [string]::IsNullOrWhiteSpace($stderr) -and
                -not $stderrIsCliXmlProgress
            ) {
                'Revised OG Get-DeviceCoords script returned no parseable coordinate pair. Error: {0}' -f
                    $stderr.Trim()
            }
            else {
                'Revised OG Get-DeviceCoords script returned no parseable coordinate pair.'
            }

            return [pscustomobject]@{
                Succeeded      = $false
                Latitude       = $null
                Longitude      = $null
                AccuracyMeters = $null
                MapUri         = if ([string]::IsNullOrWhiteSpace([string]$mapUri)) { $null } else { [string]$mapUri }
                Detail    = $detail
            }
        }

        return [pscustomobject]@{
            Succeeded      = $true
            Latitude       = $latitude
            Longitude      = $longitude
            AccuracyMeters = $accuracyMeters
            MapUri         = if ([string]::IsNullOrWhiteSpace([string]$mapUri)) {
                            # Normally the revised OG script emits this itself. This fallback
                            # only protects against host-stream quirks.
                            'https://www.google.com/maps/search/?api=1&query={0},{1}' -f
                                $latitude.ToString([Globalization.CultureInfo]::InvariantCulture),
                                $longitude.ToString([Globalization.CultureInfo]::InvariantCulture)
                        }
                        else {
                            [string]$mapUri
                        }
            Detail    = 'Captured from the revised supplied GeoCoordinateWatcher script before the v3.62 workflow.'
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded      = $false
            Latitude       = $null
            Longitude      = $null
            AccuracyMeters = $null
            MapUri         = $null
            Detail         = 'Revised OG Get-DeviceCoords execution failed: {0}' -f $_.Exception.Message
        }
    }
}


# ---------------------------------------------------------------------------
# Router WAN / upstream tunnel evidence
# ---------------------------------------------------------------------------

function Get-Ipv4AddressScope {
    param(
        [AllowNull()]
        [string]$IPAddress
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return 'Unknown'
    }

    $parsed = $null

    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return 'Invalid'
    }

    $bytes = $parsed.GetAddressBytes()
    $a = [int]$bytes[0]
    $b = [int]$bytes[1]

    if ($a -eq 10) { return 'RFC1918' }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return 'RFC1918' }
    if ($a -eq 192 -and $b -eq 168) { return 'RFC1918' }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return 'CGNAT' }
    if ($a -eq 169 -and $b -eq 254) { return 'LinkLocal' }
    if ($a -eq 127) { return 'Loopback' }
    if ($a -eq 0 -or $a -ge 224) { return 'Special' }

    return 'Public'
}

function Get-WindowsInterfaceIpv4 {
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex
    )

    # Prefer Get-NetIPConfiguration because it represents the effective
    # configuration for the interface and behaves well with DHCP-assigned
    # addresses. Fall back to Get-NetIPAddress for older/minimal shells.
    try {
        if (Get-Command -Name Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
            $config = Get-NetIPConfiguration `
                -InterfaceIndex $InterfaceIndex `
                -ErrorAction SilentlyContinue

            foreach ($entry in @($config)) {
                foreach ($address in @($entry.IPv4Address)) {
                    $candidate = [string]$address.IPAddress

                    if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                        $candidate -ne '127.0.0.1' -and
                        $candidate -notmatch '^169\.254\.') {
                        return $candidate
                    }
                }
            }
        }
    }
    catch {
        Write-Verbose ('Get-NetIPConfiguration IPv4 lookup failed for interface index [{0}]: {1}' -f
            $InterfaceIndex,
            $_.Exception.Message)
    }

    try {
        if (Get-Command -Name Get-NetIPAddress -ErrorAction SilentlyContinue) {
            return @(
                Get-NetIPAddress `
                    -InterfaceIndex $InterfaceIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) -and
                        $_.IPAddress -ne '127.0.0.1' -and
                        $_.IPAddress -notmatch '^169\.254\.'
                    } |
                    Sort-Object `
                        @{ Expression = { if ($_.SkipAsSource) { 1 } else { 0 } } },
                        PrefixLength -Descending |
                    Select-Object -ExpandProperty IPAddress
            ) | Select-Object -First 1
        }
    }
    catch {
        Write-Verbose ('Get-NetIPAddress IPv4 lookup failed for interface index [{0}]: {1}' -f
            $InterfaceIndex,
            $_.Exception.Message)
    }

    return $null
}

function Get-PhysicalDefaultGateway {
    $vpnPattern = '(?i)vpn|wireguard|wintun|tap-windows|openvpn|nordlynx|nordvpn|globalprotect|anyconnect|forti(client|net)|zscaler|pulse secure|ivanti|juniper|check\s*point|tailscale|zerotier|cloudflare.*warp|sonicwall|netextender|big-?ip'

    switch (Get-PlatformName) {
        'Windows' {
            try {
                if (-not (Get-Command -Name Get-NetRoute -ErrorAction SilentlyContinue)) {
                    return $null
                }

                $routes = @(
                    Get-NetRoute `
                        -AddressFamily IPv4 `
                        -DestinationPrefix '0.0.0.0/0' `
                        -ErrorAction Stop |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) -and
                            $_.NextHop -ne '0.0.0.0'
                        }
                )

                $candidates = [System.Collections.Generic.List[object]]::new()

                foreach ($route in $routes) {
                    $adapter = $null

                    if (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue) {
                        $adapter = Get-NetAdapter `
                            -InterfaceIndex ([int]$route.InterfaceIndex) `
                            -ErrorAction SilentlyContinue
                    }

                    $adapterText = if ($null -ne $adapter) {
                        '{0} {1}' -f $adapter.Name, $adapter.InterfaceDescription
                    }
                    else {
                        [string]$route.InterfaceAlias
                    }

                    $isVpn = ($adapterText -match $vpnPattern)

                    $interfaceType = if ($adapterText -match '(?i)wi-?fi|wireless|802\.11') {
                        'WiFi'
                    }
                    elseif (-not $isVpn) {
                        'Wired'
                    }
                    else {
                        'Other'
                    }

                    $localIpv4 = Get-WindowsInterfaceIpv4 `
                        -InterfaceIndex ([int]$route.InterfaceIndex)

                    $interfaceMetric = 0

                    try {
                        $ipInterface = Get-NetIPInterface `
                            -InterfaceIndex ([int]$route.InterfaceIndex) `
                            -AddressFamily IPv4 `
                            -ErrorAction Stop |
                            Select-Object -First 1

                        if ($null -ne $ipInterface) {
                            $interfaceMetric = [int]$ipInterface.InterfaceMetric
                        }
                    }
                    catch { }

                    $candidates.Add([pscustomobject]@{
                        Gateway        = [string]$route.NextHop
                        InterfaceIndex = [int]$route.InterfaceIndex
                        InterfaceAlias = [string]$route.InterfaceAlias
                        InterfaceType  = $interfaceType
                        LocalIPv4      = $localIpv4
                        IsVpn          = $isVpn
                        Score          = ([int]$route.RouteMetric + $interfaceMetric)
                    })
                }

                $selected = @(
                    $candidates |
                        Sort-Object `
                            @{ Expression = { if ($_.IsVpn) { 1 } else { 0 } } },
                            Score,
                            InterfaceIndex
                ) | Select-Object -First 1

                return $selected
            }
            catch {
                Write-Verbose ('Physical default-gateway discovery failed on Windows: {0}' -f
                    $_.Exception.Message)
                return $null
            }
        }

        'Linux' {
            $ip = Get-CommandPath -Candidates @('ip')

            if (-not $ip) {
                return $null
            }

            try {
                $capture = Invoke-NativeCapture `
                    -FilePath $ip `
                    -ArgumentList @('-4', 'route', 'show', 'default') `
                    -TimeoutSeconds 3

                foreach ($line in @([string]$capture.StdOut -split "`r?`n")) {
                    if ($line -match '^\s*default\s+via\s+(\d{1,3}(?:\.\d{1,3}){3})\s+dev\s+(\S+)(?:.*?\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3}))?') {
                        $iface = [string]$Matches[2]

                        if ($iface -match $vpnPattern) {
                            continue
                        }

                        return [pscustomobject]@{
                            Gateway        = [string]$Matches[1]
                            InterfaceIndex = $null
                            InterfaceAlias = $iface
                            InterfaceType  = if ($iface -match '^(?i)wl') { 'WiFi' }
                                             elseif ($iface -match '^(?i)(en|eth)') { 'Wired' }
                                             else { 'Other' }
                            LocalIPv4      = if ($Matches.Count -gt 3) { [string]$Matches[3] } else { $null }
                            IsVpn          = $false
                            Score          = 0
                        }
                    }
                }
            }
            catch {
                Write-Verbose ('Physical default-gateway discovery failed on Linux: {0}' -f
                    $_.Exception.Message)
            }

            return $null
        }

        'macOS' {
            $route = Get-CommandPath -Candidates @('/sbin/route', 'route')
            $ipconfig = Get-CommandPath -Candidates @('/usr/sbin/ipconfig', 'ipconfig')

            if (-not $route) {
                return $null
            }

            try {
                $capture = Invoke-NativeCapture `
                    -FilePath $route `
                    -ArgumentList @('-n', 'get', 'default') `
                    -TimeoutSeconds 3

                $gateway = $null
                $iface = $null

                foreach ($line in @([string]$capture.StdOut -split "`r?`n")) {
                    if ($line -match '^\s*gateway:\s*(\S+)') {
                        $gateway = [string]$Matches[1]
                    }
                    elseif ($line -match '^\s*interface:\s*(\S+)') {
                        $iface = [string]$Matches[1]
                    }
                }

                if ([string]::IsNullOrWhiteSpace($gateway) -or
                    [string]::IsNullOrWhiteSpace($iface) -or
                    $iface -match $vpnPattern) {
                    return $null
                }

                $localIpv4 = $null

                if ($ipconfig) {
                    try {
                        $addrCapture = Invoke-NativeCapture `
                            -FilePath $ipconfig `
                            -ArgumentList @('getifaddr', $iface) `
                            -TimeoutSeconds 2

                        $localIpv4 = ([string]$addrCapture.StdOut).Trim()
                    }
                    catch { }
                }

                return [pscustomobject]@{
                    Gateway        = $gateway
                    InterfaceIndex = $null
                    InterfaceAlias = $iface
                    InterfaceType  = 'Other'
                    LocalIPv4      = $localIpv4
                    IsVpn          = $false
                    Score          = 0
                }
            }
            catch {
                Write-Verbose ('Physical default-gateway discovery failed on macOS: {0}' -f
                    $_.Exception.Message)
                return $null
            }
        }
    }

    return $null
}

function Get-NatPmpExternalIpv4 {
    param(
        [Parameter(Mandatory)]
        [string]$Gateway,

        [AllowNull()]
        [string]$LocalIPv4
    )

    $gatewayIp = $null

    if (-not [System.Net.IPAddress]::TryParse($Gateway, [ref]$gatewayIp) -or
        $gatewayIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $null
    }

    $timeouts = @(300, 600)

    foreach ($timeoutMs in $timeouts) {
        $udp = $null

        try {
            $udp = [System.Net.Sockets.UdpClient]::new(
                [System.Net.Sockets.AddressFamily]::InterNetwork
            )

            if (-not [string]::IsNullOrWhiteSpace([string]$LocalIPv4)) {
                $localIp = $null

                if ([System.Net.IPAddress]::TryParse($LocalIPv4, [ref]$localIp)) {
                    $udp.Client.Bind(
                        [System.Net.IPEndPoint]::new($localIp, 0)
                    )
                }
            }

            $udp.Client.ReceiveTimeout = $timeoutMs
            $udp.Connect($gatewayIp, 5351)

            [byte[]]$request = @(0, 0)
            [void]$udp.Send($request, $request.Length)

            $remote = [System.Net.IPEndPoint]::new(
                [System.Net.IPAddress]::Any,
                0
            )

            [byte[]]$response = $udp.Receive([ref]$remote)

            if ($remote.Address.ToString() -ne $gatewayIp.ToString()) {
                continue
            }

            if ($response.Length -lt 12 -or
                $response[0] -ne 0 -or
                $response[1] -ne 128) {
                continue
            }

            $resultCode = ([int]$response[2] * 256) + [int]$response[3]

            if ($resultCode -ne 0) {
                Write-Verbose ('NAT-PMP external-address query returned result code [{0}] from gateway [{1}].' -f
                    $resultCode,
                    $Gateway)
                return $null
            }

            $externalIp = '{0}.{1}.{2}.{3}' -f
                $response[8],
                $response[9],
                $response[10],
                $response[11]

            Write-Verbose ('NAT-PMP external IPv4: gateway={0}; externalIPv4={1}' -f
                $Gateway,
                $externalIp)

            return $externalIp
        }
        catch [System.Net.Sockets.SocketException] {
            # A timeout is expected on routers without NAT-PMP.
        }
        catch {
            Write-Verbose ('NAT-PMP probe failed for gateway [{0}]: {1}' -f
                $Gateway,
                $_.Exception.Message)
            return $null
        }
        finally {
            if ($null -ne $udp) {
                $udp.Dispose()
            }
        }
    }

    return $null
}

function Test-PcpAnnounceSupport {
    param(
        [Parameter(Mandatory)]
        [string]$Gateway,

        [AllowNull()]
        [string]$LocalIPv4
    )

    if ([string]::IsNullOrWhiteSpace([string]$LocalIPv4)) {
        return $false
    }

    $gatewayIp = $null
    $localIp = $null

    if (-not [System.Net.IPAddress]::TryParse($Gateway, [ref]$gatewayIp) -or
        -not [System.Net.IPAddress]::TryParse($LocalIPv4, [ref]$localIp) -or
        $gatewayIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $localIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $udp = $null

    try {
        $udp = [System.Net.Sockets.UdpClient]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork
        )

        $udp.Client.Bind(
            [System.Net.IPEndPoint]::new($localIp, 0)
        )
        $udp.Client.ReceiveTimeout = 450
        $udp.Connect($gatewayIp, 5351)

        # PCP v2 ANNOUNCE: 24-byte common request header, lifetime 0,
        # IPv4 client encoded as an IPv4-mapped IPv6 address. ANNOUNCE has
        # no opcode-specific payload and does not create/modify a mapping.
        [byte[]]$request = New-Object byte[] 24
        $request[0] = 2
        $request[1] = 0

        $request[18] = 0xFF
        $request[19] = 0xFF

        [byte[]]$localBytes = $localIp.GetAddressBytes()
        [Array]::Copy($localBytes, 0, $request, 20, 4)

        [void]$udp.Send($request, $request.Length)

        $remote = [System.Net.IPEndPoint]::new(
            [System.Net.IPAddress]::Any,
            0
        )

        [byte[]]$response = $udp.Receive([ref]$remote)

        if ($remote.Address.ToString() -ne $gatewayIp.ToString() -or
            $response.Length -lt 24 -or
            $response[0] -ne 2 -or
            (($response[1] -band 0x80) -eq 0) -or
            (($response[1] -band 0x7F) -ne 0)) {
            return $false
        }

        Write-Verbose ('PCP ANNOUNCE support detected on gateway [{0}].' -f
            $Gateway)
        return $true
    }
    catch [System.Net.Sockets.SocketException] {
        return $false
    }
    catch {
        Write-Verbose ('PCP ANNOUNCE probe failed for gateway [{0}]: {1}' -f
            $Gateway,
            $_.Exception.Message)
        return $false
    }
    finally {
        if ($null -ne $udp) {
            $udp.Dispose()
        }
    }
}

function Get-UpnpIgdDiscovery {
    param(
        [AllowNull()]
        [string]$LocalIPv4
    )

    $locations = [System.Collections.Generic.List[string]]::new()

    foreach ($searchTarget in @(
        'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
        'urn:schemas-upnp-org:device:InternetGatewayDevice:1'
    )) {
        $udp = $null

        try {
            $udp = [System.Net.Sockets.UdpClient]::new(
                [System.Net.Sockets.AddressFamily]::InterNetwork
            )

            if (-not [string]::IsNullOrWhiteSpace([string]$LocalIPv4)) {
                $localIp = $null

                if ([System.Net.IPAddress]::TryParse($LocalIPv4, [ref]$localIp)) {
                    $udp.Client.Bind(
                        [System.Net.IPEndPoint]::new($localIp, 0)
                    )
                }
            }

            $udp.Client.ReceiveTimeout = 650

            $payload = @(
                'M-SEARCH * HTTP/1.1'
                'HOST: 239.255.255.250:1900'
                'MAN: "ssdp:discover"'
                'MX: 1'
                ('ST: {0}' -f $searchTarget)
                ''
                ''
            ) -join "`r`n"

            [byte[]]$bytes = [Text.Encoding]::ASCII.GetBytes($payload)
            $destination = [System.Net.IPEndPoint]::new(
                [System.Net.IPAddress]::Parse('239.255.255.250'),
                1900
            )

            [void]$udp.Send($bytes, $bytes.Length, $destination)

            while ($true) {
                try {
                    $remote = [System.Net.IPEndPoint]::new(
                        [System.Net.IPAddress]::Any,
                        0
                    )

                    [byte[]]$response = $udp.Receive([ref]$remote)
                    $responseText = [Text.Encoding]::ASCII.GetString($response)

                    $locationMatch = [regex]::Match(
                        $responseText,
                        '(?im)^LOCATION:\s*(\S+)\s*$'
                    )

                    if ($locationMatch.Success) {
                        $location = $locationMatch.Groups[1].Value.Trim()

                        if (-not $locations.Contains($location)) {
                            $locations.Add($location)
                        }
                    }
                }
                catch [System.Net.Sockets.SocketException] {
                    break
                }
            }
        }
        catch {
            Write-Verbose ('UPnP SSDP discovery failed for [{0}]: {1}' -f
                $searchTarget,
                $_.Exception.Message)
        }
        finally {
            if ($null -ne $udp) {
                $udp.Dispose()
            }
        }
    }

    $best = $null

    foreach ($location in @($locations)) {
        try {
            $request = @{
                Uri         = $location
                Method      = 'Get'
                TimeoutSec  = 3
                ErrorAction = 'Stop'
                Verbose     = $false
            }

            if ($PSVersionTable.PSVersion.Major -le 5) {
                $request.UseBasicParsing = $true
            }

            $descriptionResponse = Invoke-WebRequest @request
            $description = [string]$descriptionResponse.Content

            $friendlyName = $null
            $manufacturer = $null
            $modelName = $null
            $modelNumber = $null
            $modelDescription = $null
            $deviceType = $null
            $udn = $null

            try {
                [xml]$xml = $description

                $readNode = {
                    param([string]$LocalName)

                    $node = $xml.SelectSingleNode(
                        "//*[local-name()='$LocalName']"
                    )

                    if ($null -ne $node) {
                        return [Net.WebUtility]::HtmlDecode(
                            ([string]$node.InnerText).Trim()
                        )
                    }

                    return $null
                }

                $friendlyName = & $readNode 'friendlyName'
                $manufacturer = & $readNode 'manufacturer'
                $modelName = & $readNode 'modelName'
                $modelNumber = & $readNode 'modelNumber'
                $modelDescription = & $readNode 'modelDescription'
                $deviceType = & $readNode 'deviceType'
                $udn = & $readNode 'UDN'
            }
            catch {
                Write-Verbose ('UPnP description XML parse failed for [{0}]: {1}' -f
                    $location,
                    $_.Exception.Message)
            }

            $externalIp = $null

            $serviceMatches = [regex]::Matches(
                $description,
                '(?is)<service\b[^>]*>.*?<serviceType>\s*(urn:schemas-upnp-org:service:(?:WANIPConnection|WANPPPConnection):\d+)\s*</serviceType>.*?<controlURL>\s*([^<]+?)\s*</controlURL>.*?</service>'
            )

            foreach ($serviceMatch in $serviceMatches) {
                $serviceType = [Net.WebUtility]::HtmlDecode(
                    $serviceMatch.Groups[1].Value.Trim()
                )
                $controlUrlText = [Net.WebUtility]::HtmlDecode(
                    $serviceMatch.Groups[2].Value.Trim()
                )

                $descriptionUri = [Uri]$location
                $controlUri = [Uri]::new(
                    $descriptionUri,
                    $controlUrlText
                )

                $soapBody = @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetExternalIPAddress xmlns:u="$serviceType" />
  </s:Body>
</s:Envelope>
"@

                $headers = @{
                    SOAPAction = '"{0}#GetExternalIPAddress"' -f $serviceType
                }

                try {
                    $soapRequest = @{
                        Uri         = $controlUri.AbsoluteUri
                        Method      = 'Post'
                        Headers     = $headers
                        ContentType = 'text/xml; charset="utf-8"'
                        Body        = $soapBody
                        TimeoutSec  = 3
                        ErrorAction = 'Stop'
                        Verbose     = $false
                    }

                    if ($PSVersionTable.PSVersion.Major -le 5) {
                        $soapRequest.UseBasicParsing = $true
                    }

                    $soapResponse = Invoke-WebRequest @soapRequest

                    $ipMatch = [regex]::Match(
                        [string]$soapResponse.Content,
                        '(?is)<(?:\w+:)?NewExternalIPAddress>\s*([^<]+?)\s*</(?:\w+:)?NewExternalIPAddress>'
                    )

                    if ($ipMatch.Success) {
                        $candidateIp = $ipMatch.Groups[1].Value.Trim()
                        $parsed = $null

                        if ([System.Net.IPAddress]::TryParse($candidateIp, [ref]$parsed) -and
                            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {

                            $externalIp = $candidateIp
                            break
                        }
                    }
                }
                catch {
                    Write-Verbose ('UPnP GetExternalIPAddress failed for [{0}]: {1}' -f
                        $controlUri.AbsoluteUri,
                        $_.Exception.Message)
                }
            }

            $candidate = [pscustomobject]@{
                Location         = $location
                ExternalIPv4     = $externalIp
                FriendlyName     = $friendlyName
                Manufacturer     = $manufacturer
                ModelName        = $modelName
                ModelNumber      = $modelNumber
                ModelDescription = $modelDescription
                DeviceType       = $deviceType
                UDN              = $udn
            }

            if ($null -eq $best) {
                $best = $candidate
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$externalIp)) {
                $best = $candidate
                break
            }

            if (
                [string]::IsNullOrWhiteSpace([string]$best.Manufacturer) -and
                -not [string]::IsNullOrWhiteSpace([string]$candidate.Manufacturer)
            ) {
                $best = $candidate
            }
        }
        catch {
            Write-Verbose ('UPnP IGD description fetch failed for [{0}]: {1}' -f
                $location,
                $_.Exception.Message)
        }
    }

    if ($null -eq $best) {
        return [pscustomobject]@{
            Location         = $null
            ExternalIPv4     = $null
            FriendlyName     = $null
            Manufacturer     = $null
            ModelName        = $null
            ModelNumber      = $null
            ModelDescription = $null
            DeviceType       = $null
            UDN              = $null
        }
    }

    Write-Verbose ('UPnP IGD identity: friendlyName={0}; manufacturer={1}; model={2}; modelNumber={3}; externalIPv4={4}' -f
        $(if ([string]::IsNullOrWhiteSpace([string]$best.FriendlyName)) { '<none>' } else { $best.FriendlyName }),
        $(if ([string]::IsNullOrWhiteSpace([string]$best.Manufacturer)) { '<none>' } else { $best.Manufacturer }),
        $(if ([string]::IsNullOrWhiteSpace([string]$best.ModelName)) { '<none>' } else { $best.ModelName }),
        $(if ([string]::IsNullOrWhiteSpace([string]$best.ModelNumber)) { '<none>' } else { $best.ModelNumber }),
        $(if ([string]::IsNullOrWhiteSpace([string]$best.ExternalIPv4)) { '<none>' } else { $best.ExternalIPv4 }))

    return $best
}

function Get-GatewayLayer2Identity {
    param(
        [Parameter(Mandatory)]
        [string]$Gateway,

        [AllowNull()]
        [Nullable[int]]$InterfaceIndex
    )

    $mac = $null

    switch (Get-PlatformName) {
        'Windows' {
            try {
                if (Get-Command -Name Get-NetNeighbor -ErrorAction SilentlyContinue) {
                    $neighborParams = @{
                        AddressFamily = 'IPv4'
                        IPAddress     = $Gateway
                        ErrorAction   = 'SilentlyContinue'
                    }

                    if ($null -ne $InterfaceIndex) {
                        $neighborParams.InterfaceIndex = [int]$InterfaceIndex
                    }

                    $neighbor = Get-NetNeighbor @neighborParams |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace([string]$_.LinkLayerAddress) -and
                            $_.LinkLayerAddress -notmatch '^(?:00[:-]){5}00$'
                        } |
                        Select-Object -First 1

                    if ($null -ne $neighbor) {
                        $mac = Normalize-Bssid -Bssid ([string]$neighbor.LinkLayerAddress)
                    }
                }
            }
            catch {
                Write-Verbose ('Gateway neighbor lookup failed: {0}' -f $_.Exception.Message)
            }

            if ($null -eq $mac) {
                $arp = Get-CommandPath -Candidates @('arp.exe')

                if ($arp) {
                    try {
                        $capture = Invoke-NativeCapture `
                            -FilePath $arp `
                            -ArgumentList @('-a', $Gateway) `
                            -TimeoutSeconds 2

                        $match = [regex]::Match(
                            [string]$capture.StdOut,
                            '(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b'
                        )

                        if ($match.Success) {
                            $mac = Normalize-Bssid -Bssid $match.Value
                        }
                    }
                    catch { }
                }
            }
        }

        'Linux' {
            $ip = Get-CommandPath -Candidates @('ip')

            if ($ip) {
                try {
                    $capture = Invoke-NativeCapture `
                        -FilePath $ip `
                        -ArgumentList @('neigh', 'show', $Gateway) `
                        -TimeoutSeconds 2

                    $match = [regex]::Match(
                        [string]$capture.StdOut,
                        '(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b'
                    )

                    if ($match.Success) {
                        $mac = Normalize-Bssid -Bssid $match.Value
                    }
                }
                catch { }
            }
        }

        'macOS' {
            $arp = Get-CommandPath -Candidates @('/usr/sbin/arp', 'arp')

            if ($arp) {
                try {
                    $capture = Invoke-NativeCapture `
                        -FilePath $arp `
                        -ArgumentList @('-n', $Gateway) `
                        -TimeoutSeconds 2

                    $match = [regex]::Match(
                        [string]$capture.StdOut,
                        '(?i)\b(?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2}\b'
                    )

                    if ($match.Success) {
                        $parts = @($match.Value.Split(':') | ForEach-Object { $_.PadLeft(2, '0') })
                        $mac = Normalize-Bssid -Bssid ($parts -join ':')
                    }
                }
                catch { }
            }
        }
    }

    return $mac
}

function ConvertTo-RouterVendorName {
    param(
        [AllowNull()]
        [string]$Vendor
    )

    if ([string]::IsNullOrWhiteSpace([string]$Vendor)) {
        return $null
    }

    $value = $Vendor.Trim()

    if ($value -in @('*NO COMPANY*', '*PRIVATE*')) {
        return $(if ($value -eq '*PRIVATE*') { 'Private' } else { $null })
    }

    $value = @($value -split ',', 2)[0].Trim()
    $value = $value -replace '(?i)\s+Inc(?:orporated)?\.?\s*$', ''
    $value = $value.Trim().TrimEnd('.', ',', ';')

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Get-GatewayVendor {
    param(
        [AllowNull()]
        [string]$Mac
    )

    $normalized = Normalize-Bssid -Bssid $Mac

    if ($null -eq $normalized) {
        return $null
    }

    $firstOctet = [Convert]::ToInt32($normalized.Substring(0, 2), 16)

    if (($firstOctet -band 0x02) -ne 0) {
        return 'Private'
    }

    $oui = ($normalized -replace ':', '').Substring(0, 6)
    $basePath = Get-DeviceCoordsCacheBasePath
    $cachePath = if ($basePath) {
        Join-Path -Path $basePath -ChildPath 'oui-vendor-cache.json'
    }
    else {
        $null
    }

    $cache = @{}

    if ($cachePath -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        try {
            foreach ($entry in @(
                Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
            )) {
                $entryOui = ([string]$entry.Oui).ToUpperInvariant()

                if ($entryOui -match '^[0-9A-F]{6}$') {
                    $cache[$entryOui] = [pscustomobject]@{
                        Vendor     = ConvertTo-RouterVendorName -Vendor ([string]$entry.Vendor)
                        CheckedUtc = [string]$entry.CheckedUtc
                    }
                }
            }
        }
        catch {
            Write-Verbose ('Gateway OUI cache read failed: {0}' -f $_.Exception.Message)
        }
    }

    if ($cache.ContainsKey($oui)) {
        $entry = $cache[$oui]
        $fresh = $false

        try {
            $checked = [datetime]::Parse(
                [string]$entry.CheckedUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUniversalTime()

            $ttlDays = if ([string]::IsNullOrWhiteSpace([string]$entry.Vendor)) { 30 } else { 365 }
            $fresh = (((Get-Date).ToUniversalTime() - $checked).TotalDays -lt $ttlDays)
        }
        catch { }

        if ($fresh) {
            return [string]$entry.Vendor
        }
    }

    $vendor = $null

    try {
        $primary = Invoke-RestMethod `
            -Uri ('https://api.maclookup.app/v2/macs/{0}/company/name' -f $oui) `
            -Method Get `
            -TimeoutSec 3 `
            -ErrorAction Stop `
            -Verbose:$false

        $vendor = ConvertTo-RouterVendorName -Vendor ([string]$primary)
    }
    catch {
        Write-Verbose ('Gateway primary OUI lookup failed for [{0}]: {1}' -f
            $oui,
            $_.Exception.Message)
    }

    if ([string]::IsNullOrWhiteSpace([string]$vendor)) {
        try {
            $secondary = Invoke-RestMethod `
                -Uri ('https://www.macvendorlookup.com/api/v2/{0}' -f $oui) `
                -Method Get `
                -TimeoutSec 3 `
                -ErrorAction Stop `
                -Verbose:$false

            $first = @($secondary) | Select-Object -First 1

            if ($null -ne $first) {
                $vendor = ConvertTo-RouterVendorName -Vendor ([string]$first.company)
            }
        }
        catch {
            Write-Verbose ('Gateway secondary OUI lookup failed for [{0}]: {1}' -f
                $oui,
                $_.Exception.Message)
        }
    }

    $cache[$oui] = [pscustomobject]@{
        Vendor     = $vendor
        CheckedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    if ($cachePath) {
        try {
            $directory = Split-Path -Path $cachePath -Parent

            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
            }

            $entries = @(
                foreach ($key in @($cache.Keys | Sort-Object)) {
                    [pscustomobject][ordered]@{
                        Oui        = $key
                        Vendor     = [string]$cache[$key].Vendor
                        CheckedUtc = [string]$cache[$key].CheckedUtc
                    }
                }
            )

            $temp = '{0}.{1}.tmp' -f $cachePath, [Guid]::NewGuid().ToString('N')

            $entries |
                ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath $temp -Encoding UTF8 -Force -ErrorAction Stop

            Move-Item -LiteralPath $temp -Destination $cachePath -Force -ErrorAction Stop
        }
        catch {
            Write-Verbose ('Gateway OUI cache write failed: {0}' -f $_.Exception.Message)
        }
    }

    return $vendor
}

function Get-ActiveDhcpContext {
    param(
        [AllowNull()]
        [Nullable[int]]$InterfaceIndex,

        [AllowNull()]
        [string]$InterfaceAlias
    )

    $result = [ordered]@{
        DhcpServer = $null
        DnsSuffix  = $null
    }

    if ((Get-PlatformName) -ne 'Windows') {
        return [pscustomobject]$result
    }

    try {
        $configs = @(
            Get-CimInstance `
                -ClassName Win32_NetworkAdapterConfiguration `
                -Filter 'IPEnabled=True' `
                -ErrorAction Stop
        )

        $config = $null

        if ($null -ne $InterfaceIndex) {
            $config = $configs |
                Where-Object InterfaceIndex -eq ([int]$InterfaceIndex) |
                Select-Object -First 1
        }

        if ($null -eq $config -and
            -not [string]::IsNullOrWhiteSpace([string]$InterfaceAlias)) {

            $adapter = Get-WindowsNetAdapterSnapshot |
                Where-Object Name -eq $InterfaceAlias |
                Select-Object -First 1

            if ($null -ne $adapter) {
                $config = $configs |
                    Where-Object InterfaceIndex -eq ([int]$adapter.InterfaceIndex) |
                    Select-Object -First 1
            }
        }

        if ($null -ne $config) {
            $result.DhcpServer = [string]$config.DHCPServer
            $result.DnsSuffix = [string]$config.DNSDomain
        }
    }
    catch {
        Write-Verbose ('DHCP network-context lookup failed: {0}' -f $_.Exception.Message)
    }

    return [pscustomobject]$result
}

function Get-RouterWebFingerprint {
    param(
        [Parameter(Mandatory)]
        [string]$Gateway
    )

    $hints = [System.Collections.Generic.List[string]]::new()
    $tlsSubject = $null

    try {
        $request = [System.Net.HttpWebRequest]::Create(
            ('http://{0}/' -f $Gateway)
        )
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.Timeout = 1500
        $request.ReadWriteTimeout = 1500
        $request.UserAgent = 'Get-DeviceCoords/3.41'

        $response = $null

        try {
            $response = $request.GetResponse()
        }
        catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $response = $_.Exception.Response
            }
        }

        if ($null -ne $response) {
            try {
                $server = [string]$response.Headers['Server']
                $auth = [string]$response.Headers['WWW-Authenticate']
                $location = [string]$response.Headers['Location']

                if (-not [string]::IsNullOrWhiteSpace($server)) {
                    $hints.Add(('HTTP Server={0}' -f $server.Trim()))
                }

                if (-not [string]::IsNullOrWhiteSpace($auth)) {
                    $hints.Add(('Auth={0}' -f ($auth.Trim() -replace '\s+', ' ')))
                }

                if (-not [string]::IsNullOrWhiteSpace($location)) {
                    $hints.Add(('Redirect={0}' -f $location.Trim()))
                }

                $stream = $response.GetResponseStream()

                if ($null -ne $stream) {
                    $reader = [IO.StreamReader]::new($stream)

                    try {
                        $buffer = New-Object char[] 4096
                        $read = $reader.ReadBlock($buffer, 0, $buffer.Length)

                        if ($read -gt 0) {
                            $body = -join $buffer[0..($read - 1)]
                            $title = [regex]::Match(
                                $body,
                                '(?is)<title[^>]*>\s*(.*?)\s*</title>'
                            )

                            if ($title.Success) {
                                $titleText = [Net.WebUtility]::HtmlDecode(
                                    ($title.Groups[1].Value -replace '\s+', ' ').Trim()
                                )

                                if (-not [string]::IsNullOrWhiteSpace($titleText)) {
                                    $hints.Add(('Title={0}' -f $titleText))
                                }
                            }
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            finally {
                $response.Dispose()
            }
        }
    }
    catch {
        Write-Verbose ('Router HTTP fingerprint failed for [{0}]: {1}' -f
            $Gateway,
            $_.Exception.Message)
    }

    $client = $null
    $ssl = $null

    try {
        $client = [Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($Gateway, 443, $null, $null)

        if ($async.AsyncWaitHandle.WaitOne(1200)) {
            $client.EndConnect($async)
            $client.ReceiveTimeout = 1200
            $client.SendTimeout = 1200

            $ssl = [Net.Security.SslStream]::new(
                $client.GetStream(),
                $false,
                { param($sender, $certificate, $chain, $errors) return $true }
            )

            $ssl.ReadTimeout = 1200
            $ssl.WriteTimeout = 1200
            $ssl.AuthenticateAsClient($Gateway)

            if ($null -ne $ssl.RemoteCertificate) {
                $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                    $ssl.RemoteCertificate
                )

                $tlsSubject = [string]$cert.Subject

                if (-not [string]::IsNullOrWhiteSpace($tlsSubject)) {
                    $hints.Add(('TLS={0}' -f $tlsSubject))
                }
            }
        }
    }
    catch {
        Write-Verbose ('Router TLS fingerprint failed for [{0}]: {1}' -f
            $Gateway,
            $_.Exception.Message)
    }
    finally {
        if ($null -ne $ssl) {
            $ssl.Dispose()
        }

        if ($null -ne $client) {
            $client.Dispose()
        }
    }

    return [pscustomobject]@{
        Hint       = (@($hints | Select-Object -Unique) -join '; ')
        TlsSubject = $tlsSubject
    }
}

function Resolve-RouterIdentity {
    param(
        [AllowNull()]
        [string]$GatewayVendor,

        [AllowNull()]
        [string]$UpnpManufacturer,

        [AllowNull()]
        [string]$Model
    )

    $modelText = if ([string]::IsNullOrWhiteSpace([string]$Model)) {
        $null
    }
    else {
        $Model.Trim()
    }

    $vendorText = if ([string]::IsNullOrWhiteSpace([string]$GatewayVendor)) {
        $null
    }
    else {
        $GatewayVendor.Trim()
    }

    $rawManufacturer = if ([string]::IsNullOrWhiteSpace([string]$UpnpManufacturer)) {
        $null
    }
    else {
        $UpnpManufacturer.Trim()
    }

    $resolvedManufacturer = $null
    $platform = $null
    $confidence = 'Low'
    $basis = [System.Collections.Generic.List[string]]::new()

    # High-confidence model/platform mappings are intentionally small and
    # evidence-backed. Raw UPnP identity is always preserved separately.
    switch -Regex ($modelText) {
        '^(?i)CGM4331COM$' {
            $resolvedManufacturer = 'Vantiva (Technicolor)'
            $platform = 'XB7'
            $confidence = 'High'
            $basis.Add('Model CGM4331COM maps to the Vantiva/Technicolor XB7 platform.')
            break
        }

        '^(?i)CGM4981COM$' {
            $resolvedManufacturer = 'Vantiva (Technicolor)'
            $platform = 'XB8'
            $confidence = 'High'
            $basis.Add('Model CGM4981COM maps to the Vantiva/Technicolor XB8 platform.')
            break
        }

        '^(?i)CGM4140COM$' {
            $resolvedManufacturer = 'Vantiva (Technicolor)'
            $platform = 'XB6'
            $confidence = 'High'
            $basis.Add('Model CGM4140COM maps to the Technicolor/Vantiva XB6 platform.')
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$resolvedManufacturer)) {
        if ($vendorText -match '(?i)\bVantiva\b|\bTechnicolor\b') {
            $resolvedManufacturer = 'Vantiva (Technicolor)'
            $confidence = 'Medium'
            $basis.Add(('Gateway MAC OUI resolves to [{0}].' -f $vendorText))
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$vendorText) -and
                $vendorText -ne 'Private') {
            $resolvedManufacturer = $vendorText
            $confidence = 'Medium'
            $basis.Add(('Gateway MAC OUI resolves to [{0}].' -f $vendorText))
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$rawManufacturer)) {
            $resolvedManufacturer = $rawManufacturer
            $confidence = 'Low'
            $basis.Add(('Only raw UPnP manufacturer evidence was available [{0}].' -f $rawManufacturer))
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$vendorText)) {
        $basis.Add(('Gateway MAC OUI evidence: [{0}].' -f $vendorText))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$rawManufacturer) -and
        -not [string]::IsNullOrWhiteSpace([string]$resolvedManufacturer) -and
        $rawManufacturer -ne $resolvedManufacturer) {

        $basis.Add(
            ('Raw UPnP manufacturer [{0}] differs from normalized hardware identity [{1}]; raw value is preserved.' -f
                $rawManufacturer,
                $resolvedManufacturer)
        )
    }

    return [pscustomobject]@{
        ManufacturerRaw      = $rawManufacturer
        ManufacturerResolved = $resolvedManufacturer
        Platform             = $platform
        Confidence           = $confidence
        Basis                = ($basis -join ' ')
    }
}

function Get-RouterWanDiscovery {
    $gateway = Get-PhysicalDefaultGateway

    if ($null -eq $gateway -or
        [string]::IsNullOrWhiteSpace([string]$gateway.Gateway)) {
        return [pscustomobject]@{
            Gateway            = $null
            GatewayMac         = $null
            GatewayVendor      = $null
            InterfaceAlias     = $null
            InterfaceType      = 'Unknown'
            LocalIPv4          = $null
            DhcpServer         = $null
            DnsSuffix          = $null
            RouterFriendlyName          = $null
            RouterManufacturer          = $null
            RouterManufacturerRaw       = $null
            RouterManufacturerResolved  = $null
            RouterPlatform              = $null
            RouterIdentityConfidence    = 'None'
            RouterIdentityBasis         = $null
            RouterModel                 = $null
            RouterWebHint               = $null
            RouterTlsSubject   = $null
            WanIPv4            = $null
            WanSource          = 'Unavailable'
            WanScope           = 'Unknown'
            UpnpExternalIPv4   = $null
            NatPmpExternalIPv4 = $null
            PcpSupported       = $false
            Detail             = 'Physical/default LAN gateway could not be determined.'
        }
    }

    $gatewayMac = Get-GatewayLayer2Identity `
        -Gateway ([string]$gateway.Gateway) `
        -InterfaceIndex $gateway.InterfaceIndex

    $gatewayVendor = Get-GatewayVendor -Mac $gatewayMac

    $dhcpContext = Get-ActiveDhcpContext `
        -InterfaceIndex $gateway.InterfaceIndex `
        -InterfaceAlias ([string]$gateway.InterfaceAlias)

    $pcpSupported = Test-PcpAnnounceSupport `
        -Gateway ([string]$gateway.Gateway) `
        -LocalIPv4 ([string]$gateway.LocalIPv4)

    $upnp = Get-UpnpIgdDiscovery `
        -LocalIPv4 ([string]$gateway.LocalIPv4)

    $upnpExternal = [string]$upnp.ExternalIPv4

    $natPmpExternal = Get-NatPmpExternalIpv4 `
        -Gateway ([string]$gateway.Gateway) `
        -LocalIPv4 ([string]$gateway.LocalIPv4)

    $wanIp = $null
    $source = 'Unavailable'

    if (-not [string]::IsNullOrWhiteSpace([string]$upnpExternal)) {
        $wanIp = [string]$upnpExternal
        $source = 'UPnP IGD'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$natPmpExternal)) {
        $wanIp = [string]$natPmpExternal
        $source = 'NAT-PMP'
    }

    $routerModel = @(
        [string]$upnp.ModelName,
        [string]$upnp.ModelNumber
    ) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique

    $routerModel = @($routerModel) -join ' '

    $resolvedRouterIdentity = Resolve-RouterIdentity `
        -GatewayVendor $gatewayVendor `
        -UpnpManufacturer ([string]$upnp.Manufacturer) `
        -Model ([string]$routerModel)

    # Avoid an extra gateway HTTP/TLS probe when UPnP already identified the
    # router sufficiently. Otherwise perform a short, unauthenticated fingerprint.
    $webFingerprint = if (
        [string]::IsNullOrWhiteSpace([string]$upnp.Manufacturer) -or
        [string]::IsNullOrWhiteSpace([string]$routerModel)
    ) {
        Get-RouterWebFingerprint -Gateway ([string]$gateway.Gateway)
    }
    else {
        [pscustomobject]@{
            Hint       = $null
            TlsSubject = $null
        }
    }

    $detailParts = [System.Collections.Generic.List[string]]::new()
    $detailParts.Add(
        ('Gateway={0}; Interface={1}; LocalIPv4={2}' -f
            $gateway.Gateway,
            $gateway.InterfaceAlias,
            $(if ([string]::IsNullOrWhiteSpace([string]$gateway.LocalIPv4)) { '<none>' } else { $gateway.LocalIPv4 }))
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$gatewayMac)) {
        $detailParts.Add(('GatewayMAC={0}' -f $gatewayMac))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$gatewayVendor)) {
        $detailParts.Add(('GatewayVendor={0}' -f $gatewayVendor))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$upnp.Manufacturer)) {
        $detailParts.Add(('UPnPManufacturer={0}' -f $upnp.Manufacturer))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$routerModel)) {
        $detailParts.Add(('UPnPModel={0}' -f $routerModel))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$resolvedRouterIdentity.ManufacturerResolved)) {
        $detailParts.Add(('ResolvedManufacturer={0}' -f $resolvedRouterIdentity.ManufacturerResolved))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$resolvedRouterIdentity.Platform)) {
        $detailParts.Add(('RouterPlatform={0}' -f $resolvedRouterIdentity.Platform))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$upnpExternal)) {
        $detailParts.Add(('UPnP={0}' -f $upnpExternal))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$natPmpExternal)) {
        $detailParts.Add(('NAT-PMP={0}' -f $natPmpExternal))
    }

    $detailParts.Add(('PCP={0}' -f $(if ($pcpSupported) { 'Supported' } else { 'NoResponse' })))

    if (-not [string]::IsNullOrWhiteSpace([string]$upnpExternal) -and
        -not [string]::IsNullOrWhiteSpace([string]$natPmpExternal) -and
        $upnpExternal -ne $natPmpExternal) {
        $detailParts.Add('UPnP and NAT-PMP returned different external IPv4 addresses.')
    }

    return [pscustomobject]@{
        Gateway            = [string]$gateway.Gateway
        GatewayMac         = $gatewayMac
        GatewayVendor      = $gatewayVendor
        InterfaceAlias     = [string]$gateway.InterfaceAlias
        InterfaceType      = if ($gateway.PSObject.Properties.Name -contains 'InterfaceType') {
                                 [string]$gateway.InterfaceType
                             }
                             else {
                                 'Other'
                             }
        LocalIPv4          = [string]$gateway.LocalIPv4
        DhcpServer         = [string]$dhcpContext.DhcpServer
        DnsSuffix          = [string]$dhcpContext.DnsSuffix
        RouterFriendlyName          = [string]$upnp.FriendlyName
        RouterManufacturer          = [string]$upnp.Manufacturer
        RouterManufacturerRaw       = [string]$resolvedRouterIdentity.ManufacturerRaw
        RouterManufacturerResolved  = [string]$resolvedRouterIdentity.ManufacturerResolved
        RouterPlatform              = [string]$resolvedRouterIdentity.Platform
        RouterIdentityConfidence    = [string]$resolvedRouterIdentity.Confidence
        RouterIdentityBasis         = [string]$resolvedRouterIdentity.Basis
        RouterModel                 = [string]$routerModel
        RouterWebHint               = [string]$webFingerprint.Hint
        RouterTlsSubject   = [string]$webFingerprint.TlsSubject
        WanIPv4            = $wanIp
        WanSource          = $source
        WanScope           = Get-Ipv4AddressScope -IPAddress $wanIp
        UpnpExternalIPv4   = $upnpExternal
        NatPmpExternalIPv4 = $natPmpExternal
        PcpSupported       = $pcpSupported
        Detail             = ($detailParts -join '; ')
    }
}

function Test-LikelyTunnelEgressProviderName {
    param(
        [AllowNull()]
        [string]$Provider
    )

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        return $false
    }

    # Confidence signal only; never sufficient by itself.
    return ($Provider -match '(?i)\b(?:M247|DataCamp|Packethub|Mullvad|NordVPN|Proton(?:VPN)?|Surfshark|ExpressVPN|Private Internet Access|Windscribe|CyberGhost|IPVanish|Leaseweb|OVH|Hetzner|Vultr|DigitalOcean|Choopa|Quadranet|Psychz)\b')
}

function Get-ShortRouterPathTrace {
    param(
        [AllowNull()]
        [string]$Gateway,

        [int]$MaxHops = 8
    )

    $platform = Get-PlatformName
    $traceCommand = $null
    $arguments = @()

    switch ($platform) {
        'Windows' {
            $traceCommand = Get-CommandPath -Candidates @(
                $(if (-not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
                    Join-Path -Path $env:SystemRoot -ChildPath 'System32\tracert.exe'
                }),
                'tracert.exe'
            )
            $arguments = @('-4', '-d', '-h', [string]$MaxHops, '-w', '500', '1.1.1.1')
        }
        'Linux' {
            $traceCommand = Get-CommandPath -Candidates @('traceroute')
            $arguments = @('-4', '-n', '-m', [string]$MaxHops, '-w', '1', '1.1.1.1')
        }
        'macOS' {
            $traceCommand = Get-CommandPath -Candidates @('/usr/sbin/traceroute', 'traceroute')
            $arguments = @('-n', '-m', [string]$MaxHops, '-w', '1', '1.1.1.1')
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$traceCommand)) {
        return [pscustomobject]@{
            Hops              = @()
            PublicHops        = @()
            AdditionalPrivate = @()
            FirstPublicGeo    = @()
            TraceGeo          = @()
            PathText          = $null
        }
    }

    try {
        $capture = Invoke-NativeCapture `
            -FilePath $traceCommand `
            -ArgumentList $arguments `
            -TimeoutSeconds 14

        $hops = [System.Collections.Generic.List[object]]::new()

        foreach ($line in @([string]$capture.StdOut -split "`r?`n")) {
            $m = [regex]::Match(
                $line,
                '^\s*(?<Hop>\d+)\s+.*?(?<Ip>(?:\d{1,3}\.){3}\d{1,3})\s*$'
            )

            if (-not $m.Success) {
                continue
            }

            $ip = [string]$m.Groups['Ip'].Value

            $hops.Add([pscustomobject]@{
                Hop   = [int]$m.Groups['Hop'].Value
                IP    = $ip
                Scope = Get-Ipv4AddressScope -IPAddress $ip
            })
        }

        $publicHops = @(
            $hops |
                Where-Object {
                    $_.IP -ne '1.1.1.1' -and
                    $_.Scope -eq 'Public'
                } |
                Select-Object -First 3
        )

        $additionalPrivate = @(
            $hops |
                Where-Object {
                    $_.IP -ne $Gateway -and
                    $_.Scope -in @('RFC1918', 'CGNAT')
                }
        )

        # Geolocate every responding public transit hop. Private/CGNAT hops are
        # retained as topology evidence, but are never sent to the IP geolocation
        # service. The fixed 1.1.1.1 destination is shown as Destination because
        # anycast endpoint geolocation is not meaningful as a route-location signal.
        $traceGeo = [System.Collections.Generic.List[object]]::new()

        foreach ($hopEntry in @($hops)) {
            $hopIp = [string]$hopEntry.IP
            $hopScope = [string]$hopEntry.Scope

            if ($hopIp -eq '1.1.1.1') {
                $traceGeo.Add([pscustomobject]@{
                    Hop          = [int]$hopEntry.Hop
                    IP           = $hopIp
                    Scope        = 'Destination'
                    City         = '<anycast>'
                    Region       = $null
                    Country      = $null
                    ISP          = 'Cloudflare'
                    Organization = 'Cloudflare'
                    ASN          = '13335'
                    Latitude     = $null
                    Longitude    = $null
                })

                continue
            }

            if ($hopScope -eq 'Public') {
                $geo = Get-IpLocationByAddress -IPAddress $hopIp

                $traceGeo.Add([pscustomobject]@{
                    Hop          = [int]$hopEntry.Hop
                    IP           = $hopIp
                    Scope        = 'Public'
                    City         = if ($null -ne $geo) { [string]$geo.City } else { $null }
                    Region       = if ($null -ne $geo) { [string]$geo.Region } else { $null }
                    Country      = if ($null -ne $geo) { [string]$geo.Country } else { $null }
                    ISP          = if ($null -ne $geo) { [string]$geo.ISP } else { $null }
                    Organization = if ($null -ne $geo) { [string]$geo.Organization } else { $null }
                    ASN          = if ($null -ne $geo) { [string]$geo.ASN } else { $null }
                    Latitude     = if ($null -ne $geo) { $geo.Latitude } else { $null }
                    Longitude    = if ($null -ne $geo) { $geo.Longitude } else { $null }
                })

                continue
            }

            $traceGeo.Add([pscustomobject]@{
                Hop          = [int]$hopEntry.Hop
                IP           = $hopIp
                Scope        = $hopScope
                City         = '<private>'
                Region       = $null
                Country      = $null
                ISP          = $null
                Organization = $null
                ASN          = $null
                Latitude     = $null
                Longitude    = $null
            })
        }

        $firstPublicGeo = @(
            $traceGeo |
                Where-Object { $_.Scope -eq 'Public' } |
                Select-Object -First 2
        )

        $pathText = @(
            $hops |
                Select-Object -First 6 |
                ForEach-Object { '{0}:{1}' -f $_.Hop, $_.IP }
        ) -join ' > '

        Write-Verbose ('Router/upstream path trace: gateway={0}; path={1}; privateOverlay={2}; publicHops={3}' -f
            $(if ([string]::IsNullOrWhiteSpace([string]$Gateway)) { '<none>' } else { $Gateway }),
            $(if ([string]::IsNullOrWhiteSpace([string]$pathText)) { '<none>' } else { $pathText }),
            $(if ($additionalPrivate.Count -gt 0) { @($additionalPrivate.IP) -join ' > ' } else { '<none>' }),
            $(if ($publicHops.Count -gt 0) { @($publicHops.IP) -join ' > ' } else { '<none>' }))

        return [pscustomobject]@{
            Hops              = @($hops)
            PublicHops        = @($publicHops)
            AdditionalPrivate = @($additionalPrivate)
            FirstPublicGeo    = @($firstPublicGeo)
            TraceGeo          = @($traceGeo)
            PathText          = $pathText
        }
    }
    catch {
        Write-Verbose ('Router/upstream detailed trace failed: {0}' -f
            $_.Exception.Message)

        return [pscustomobject]@{
            Hops              = @()
            PublicHops        = @()
            AdditionalPrivate = @()
            FirstPublicGeo    = @()
            TraceGeo          = @()
            PathText          = $null
        }
    }
}

function Get-RouterVpnAssessment {
    param(
        [Parameter(Mandatory)]
        [object]$RouterWan,

        [AllowNull()]
        [object]$ObservedPublicIp,

        [bool]$EndpointVpnEstablished = $false
    )

    $evidence = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $RouterWan -or
        [string]::IsNullOrWhiteSpace([string]$RouterWan.WanIPv4)) {

        $gatewayText = if (
            $null -ne $RouterWan -and
            -not [string]::IsNullOrWhiteSpace([string]$RouterWan.Gateway)
        ) {
            [string]$RouterWan.Gateway
        }
        else {
            '<unknown>'
        }

        $localIpText = if (
            $null -ne $RouterWan -and
            -not [string]::IsNullOrWhiteSpace([string]$RouterWan.LocalIPv4)
        ) {
            [string]$RouterWan.LocalIPv4
        }
        else {
            '<unknown>'
        }

        $interfaceText = if (
            $null -ne $RouterWan -and
            -not [string]::IsNullOrWhiteSpace([string]$RouterWan.InterfaceAlias)
        ) {
            [string]$RouterWan.InterfaceAlias
        }
        else {
            '<unknown>'
        }

        $interfaceTypeText = if (
            $null -ne $RouterWan -and
            $RouterWan.PSObject.Properties.Name -contains 'InterfaceType'
        ) {
            [string]$RouterWan.InterfaceType
        }
        else {
            'Unknown'
        }

        $evidence.Add(
            ('Local path is {0} [{1}] with IPv4 [{2}] and default gateway [{3}]. The gateway did not expose a WAN IPv4 through UPnP IGD or NAT-PMP.' -f
                $interfaceTypeText,
                $interfaceText,
                $localIpText,
                $gatewayText)
        )

        if ($EndpointVpnEstablished) {
            $evidence.Add(
                'An endpoint VPN/tunnel is established, so the observed route cannot be attributed to a router tunnel.'
            )

            return [pscustomobject]@{
                Suspected  = 'Indeterminate'
                Confidence = 'Low'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @()
                TraceGeo   = @()
            }
        }

        if ($null -eq $ObservedPublicIp -or
            [string]::IsNullOrWhiteSpace([string]$ObservedPublicIp.IP)) {

            return [pscustomobject]@{
                Suspected  = 'Unknown'
                Confidence = 'None'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @()
                TraceGeo   = @()
            }
        }

        $trace = Get-ShortRouterPathTrace `
            -Gateway $gatewayText `
            -MaxHops 8

        $publicIps = @(
            $trace.PublicHops |
                Select-Object -ExpandProperty IP
        )

        if (-not [string]::IsNullOrWhiteSpace([string]$trace.PathText)) {
            $evidence.Add(('Short route path: {0}.' -f $trace.PathText))
        }

        $hasOverlay = (@($trace.AdditionalPrivate).Count -gt 0)
        $hasPublic = (@($trace.PublicHops).Count -gt 0)

        if ($hasOverlay) {
            $overlayText = @(
                $trace.AdditionalPrivate |
                    ForEach-Object { $_.IP }
            ) -join ' > '

            $evidence.Add(
                ('Additional private/CGNAT hop(s) after the local gateway: [{0}]. This is consistent with an upstream overlay/tunnel or carrier NAT layer.' -f
                    $overlayText)
            )
        }

        $providerText = @(
            [string]$ObservedPublicIp.ISP,
            [string]$ObservedPublicIp.Organization
        ) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }

        $providerText = @($providerText) -join ' / '
        $providerHint = Test-LikelyTunnelEgressProviderName -Provider $providerText
        $observedAsn = [string]$ObservedPublicIp.ASN

        $traceProviderMatch = $false
        $firstPublicMatchesObserved = $false
        $initialProviderMatchCount = 0

        $initialPublicGeo = @(
            $trace.TraceGeo |
                Where-Object Scope -eq 'Public' |
                Select-Object -First 3
        )

        foreach ($geo in @($initialPublicGeo)) {
            $sameAsn = (
                -not [string]::IsNullOrWhiteSpace($observedAsn) -and
                -not [string]::IsNullOrWhiteSpace([string]$geo.ASN) -and
                $observedAsn -eq [string]$geo.ASN
            )

            $sameIsp = (
                -not [string]::IsNullOrWhiteSpace([string]$ObservedPublicIp.ISP) -and
                -not [string]::IsNullOrWhiteSpace([string]$geo.ISP) -and
                [string]$ObservedPublicIp.ISP -eq [string]$geo.ISP
            )

            if ($sameAsn -or $sameIsp) {
                $initialProviderMatchCount++
            }
        }

        if ($initialPublicGeo.Count -gt 0) {
            $firstGeo = $initialPublicGeo[0]

            $firstPublicMatchesObserved = (
                (
                    -not [string]::IsNullOrWhiteSpace($observedAsn) -and
                    -not [string]::IsNullOrWhiteSpace([string]$firstGeo.ASN) -and
                    $observedAsn -eq [string]$firstGeo.ASN
                ) -or
                (
                    -not [string]::IsNullOrWhiteSpace([string]$ObservedPublicIp.ISP) -and
                    -not [string]::IsNullOrWhiteSpace([string]$firstGeo.ISP) -and
                    [string]$ObservedPublicIp.ISP -eq [string]$firstGeo.ISP
                )
            )
        }

        foreach ($geo in @($trace.FirstPublicGeo)) {
            $sameAsn = (
                -not [string]::IsNullOrWhiteSpace($observedAsn) -and
                -not [string]::IsNullOrWhiteSpace([string]$geo.ASN) -and
                $observedAsn -eq [string]$geo.ASN
            )

            $sameIsp = (
                -not [string]::IsNullOrWhiteSpace([string]$ObservedPublicIp.ISP) -and
                -not [string]::IsNullOrWhiteSpace([string]$geo.ISP) -and
                [string]$ObservedPublicIp.ISP -eq [string]$geo.ISP
            )

            if ($sameAsn -or $sameIsp) {
                $traceProviderMatch = $true
                break
            }
        }

        if (@($trace.FirstPublicGeo).Count -gt 0) {
            $publicGeoText = @(
                $trace.FirstPublicGeo |
                    ForEach-Object {
                        '{0} ({1}; ASN {2})' -f
                            $_.IP,
                            $(if ([string]::IsNullOrWhiteSpace([string]$_.ISP)) { '<unknown ISP>' } else { $_.ISP }),
                            $(if ([string]::IsNullOrWhiteSpace([string]$_.ASN)) { '<unknown>' } else { $_.ASN })
                    }
            ) -join ' > '

            $evidence.Add(('First public trace hop(s): {0}.' -f $publicGeoText))
        }

        $evidence.Add(
            ('Observed Internet egress is [{0}] via [{1}] (ASN {2}).' -f
                $ObservedPublicIp.IP,
                $(if ([string]::IsNullOrWhiteSpace($providerText)) { '<unknown provider>' } else { $providerText }),
                $(if ([string]::IsNullOrWhiteSpace($observedAsn)) { '<unknown>' } else { $observedAsn }))
        )

        if ($hasOverlay -and $hasPublic -and $providerHint) {
            $evidence.Add(
                'No endpoint VPN is established, the route enters an additional private overlay before public Internet space, and the observed egress provider matches a hosting/VPN-egress heuristic. This is strong evidence of a router/upstream-managed tunnel; router status/API access would still be required for absolute confirmation.'
            )

            return [pscustomobject]@{
                Suspected  = 'True'
                Confidence = 'High'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @($publicIps)
                TraceGeo   = @($trace.TraceGeo)
            }
        }

        if ($hasOverlay -and $hasPublic -and $traceProviderMatch) {
            $evidence.Add(
                'No endpoint VPN is established and the route transitions through an additional private overlay into the same public network as the observed egress. This is good evidence of a router/upstream-managed tunnel, though carrier NAT cannot be completely excluded.'
            )

            return [pscustomobject]@{
                Suspected  = 'True'
                Confidence = 'Medium'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @($publicIps)
                TraceGeo   = @($trace.TraceGeo)
            }
        }

        if ($hasOverlay -and $hasPublic) {
            $evidence.Add(
                'The private-overlay-to-public transition is consistent with an upstream tunnel, but can also occur with CGNAT or managed carrier routing.'
            )

            return [pscustomobject]@{
                Suspected  = 'Possible'
                Confidence = 'Medium'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @($publicIps)
                TraceGeo   = @($trace.TraceGeo)
            }
        }

        if (
            -not $hasOverlay -and
            $hasPublic -and
            $firstPublicMatchesObserved -and
            $initialProviderMatchCount -ge 2 -and
            -not $providerHint
        ) {
            $evidence.Add(
                ('No endpoint VPN is established, no additional private/CGNAT overlay was observed after the LAN gateway, and {0} initial public hop(s) remain in the same ISP/ASN as the observed egress. The tested default route is consistent with direct ISP routing rather than a router/upstream VPN.' -f
                    $initialProviderMatchCount)
            )

            return [pscustomobject]@{
                Suspected  = 'False'
                Confidence = 'High'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @($publicIps)
                TraceGeo   = @($trace.TraceGeo)
            }
        }

        if (
            -not $hasOverlay -and
            $hasPublic -and
            $firstPublicMatchesObserved -and
            -not $providerHint
        ) {
            $evidence.Add(
                'No endpoint VPN is established, the route enters the observed ISP directly from the LAN gateway, and no private tunnel-overlay hop was seen. No router/upstream VPN was detected on the tested default route.'
            )

            return [pscustomobject]@{
                Suspected  = 'False'
                Confidence = 'Medium'
                Evidence   = ($evidence -join ' ')
                TraceHops  = @($publicIps)
                TraceGeo   = @($trace.TraceGeo)
            }
        }

        return [pscustomobject]@{
            Suspected  = 'Unknown'
            Confidence = 'Low'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @($publicIps)
            TraceGeo   = @($trace.TraceGeo)
        }
    }

    $routerScope = Get-Ipv4AddressScope -IPAddress ([string]$RouterWan.WanIPv4)

    if ($routerScope -in @('RFC1918', 'CGNAT', 'LinkLocal', 'Special')) {
        $evidence.Add(
            ('Router-reported WAN IPv4 [{0}] is {1}; a different observed public IP can be normal upstream NAT/CGNAT and does not prove a router VPN.' -f
                $RouterWan.WanIPv4,
                $routerScope)
        )

        return [pscustomobject]@{
            Suspected  = 'Indeterminate'
            Confidence = 'Low'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @()
            TraceGeo   = @()
        }
    }

    if ($null -eq $ObservedPublicIp -or
        [string]::IsNullOrWhiteSpace([string]$ObservedPublicIp.IP)) {

        $evidence.Add(
            ('Router WAN IPv4 [{0}] was discovered, but no observed Internet public IP was available for comparison.' -f
                $RouterWan.WanIPv4)
        )

        return [pscustomobject]@{
            Suspected  = 'Unknown'
            Confidence = 'None'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @()
            TraceGeo   = @()
        }
    }

    $observedIp = [string]$ObservedPublicIp.IP

    if ($RouterWan.WanIPv4 -eq $observedIp) {
        $evidence.Add(
            ('Router WAN IPv4 [{0}] matches the observed Internet IPv4. No router/upstream VPN evidence was found from WAN-address comparison.' -f
                $RouterWan.WanIPv4)
        )

        return [pscustomobject]@{
            Suspected  = 'False'
            Confidence = 'High'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @()
            TraceGeo   = @()
        }
    }

    if ($EndpointVpnEstablished) {
        $evidence.Add(
            ('Router WAN IPv4 [{0}] differs from observed Internet IPv4 [{1}], but an endpoint VPN/tunnel is established and can explain the mismatch; router VPN state is indeterminate.' -f
                $RouterWan.WanIPv4,
                $observedIp)
        )

        return [pscustomobject]@{
            Suspected  = 'Indeterminate'
            Confidence = 'Low'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @()
            TraceGeo   = @()
        }
    }

    $routerGeo = if ((Get-Ipv4AddressScope -IPAddress $RouterWan.WanIPv4) -eq 'Public') {
        Get-IpLocationByAddress -IPAddress ([string]$RouterWan.WanIPv4)
    }
    else {
        $null
    }

    $routerAsn = if ($null -ne $routerGeo) { [string]$routerGeo.ASN } else { $null }
    $routerIsp = if ($null -ne $routerGeo) { [string]$routerGeo.ISP } else { $null }
    $observedAsn = [string]$ObservedPublicIp.ASN
    $observedIsp = [string]$ObservedPublicIp.ISP

    $differentAsn = (
        -not [string]::IsNullOrWhiteSpace($routerAsn) -and
        -not [string]::IsNullOrWhiteSpace($observedAsn) -and
        $routerAsn -ne $observedAsn
    )

    $differentIsp = (
        -not [string]::IsNullOrWhiteSpace($routerIsp) -and
        -not [string]::IsNullOrWhiteSpace($observedIsp) -and
        $routerIsp -ne $observedIsp
    )

    $routerPathTrace = Get-ShortRouterPathTrace -MaxHops 8

    $traceHops = @(
        $routerPathTrace.PublicHops |
            Select-Object -First 2 |
            Select-Object -ExpandProperty IP
    )

    $traceText = if ($traceHops.Count -gt 0) {
        $traceHops -join ' > '
    }
    else {
        '<none>'
    }

    $evidence.Add(
        ('Router WAN [{0}] ({1}; ASN {2}) differs from observed Internet IP [{3}] ({4}; ASN {5}).' -f
            $RouterWan.WanIPv4,
            $(if ([string]::IsNullOrWhiteSpace($routerIsp)) { '<unknown ISP>' } else { $routerIsp }),
            $(if ([string]::IsNullOrWhiteSpace($routerAsn)) { '<unknown>' } else { $routerAsn }),
            $observedIp,
            $(if ([string]::IsNullOrWhiteSpace($observedIsp)) { '<unknown ISP>' } else { $observedIsp }),
            $(if ([string]::IsNullOrWhiteSpace($observedAsn)) { '<unknown>' } else { $observedAsn }))
    )

    if ($traceHops.Count -gt 0) {
        $evidence.Add(('First public trace hops: {0}.' -f $traceText))
    }

    if ($differentAsn -or $differentIsp) {
        $evidence.Add(
            'The public-IP and provider/ASN mismatch is strong evidence of upstream NAT/proxy/VPN behavior above the endpoint; a router VPN is likely but cannot be cryptographically proven without router status/API access.'
        )

        return [pscustomobject]@{
            Suspected  = 'True'
            Confidence = 'High'
            Evidence   = ($evidence -join ' ')
            TraceHops  = @($traceHops)
            TraceGeo   = @($routerPathTrace.TraceGeo)
        }
    }

    $evidence.Add(
        'The WAN/public IP mismatch is real, but provider identity does not clearly change; upstream NAT, multi-WAN, ISP proxying, or a router VPN are all possible.'
    )

    return [pscustomobject]@{
        Suspected  = 'Possible'
        Confidence = 'Medium'
        Evidence   = ($evidence -join ' ')
        TraceHops  = @($traceHops)
        TraceGeo   = @($routerPathTrace.TraceGeo)
    }
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$platform = Get-PlatformName

if ($platform -eq 'Unknown') {
    throw 'Unable to identify the operating-system platform.'
}

# v3.20 comparison baseline: run the revised supplied OG script first. Snapshot/restore Location
# consent around that execution because the original script leaves its temporary Allow
# values in place (its Deny cleanup is commented out).
$ogDeviceCoords = [pscustomobject]@{
    Succeeded      = $false
    Latitude       = $null
    Longitude      = $null
    AccuracyMeters = $null
    MapUri         = $null
    Detail         = 'Revised OG Get-DeviceCoords script was not run.'
}

$ogConsentSnapshot = @()

if ($platform -eq 'Windows') {
    try {
        $ogConsentSnapshot = @(Enable-WindowsTemporaryLocationConsent)
        Write-Verbose 'Running revised OG Get-DeviceCoords script before the v3.62 workflow.'
        $ogDeviceCoords = Invoke-OgDeviceCoordsScript -Platform $platform
    }
    finally {
        if (@($ogConsentSnapshot).Count -gt 0) {
            Restore-WindowsLocationConsent -Snapshot $ogConsentSnapshot
        }
    }
}
else {
    $ogDeviceCoords = Invoke-OgDeviceCoordsScript -Platform $platform
}

Write-Verbose ('OG Get-DeviceCoords result: succeeded={0}; latitude={1}; longitude={2}; mapUri={3}; detail={4}' -f
    $ogDeviceCoords.Succeeded,
    $(if ($null -eq $ogDeviceCoords.Latitude) { '<none>' } else { $ogDeviceCoords.Latitude }),
    $(if ($null -eq $ogDeviceCoords.Longitude) { '<none>' } else { $ogDeviceCoords.Longitude }),
    $(if ([string]::IsNullOrWhiteSpace([string]$ogDeviceCoords.MapUri)) { '<none>' } else { $ogDeviceCoords.MapUri }),
    $ogDeviceCoords.Detail)

$googleApiKeySource = 'None'

if (-not [string]::IsNullOrWhiteSpace($GoogleGeolocationApiKey)) {
    $googleApiKeySource = 'Parameter'
}
elseif (-not [string]::IsNullOrWhiteSpace($env:GOOGLE_GEO_API_KEY)) {
    $GoogleGeolocationApiKey = $env:GOOGLE_GEO_API_KEY
    $googleApiKeySource = 'Environment'
}

$wigleCredentialSource = 'None'

if ([string]::IsNullOrWhiteSpace($WigleApiName) -and
    -not [string]::IsNullOrWhiteSpace([string]$env:WIGLE_API_NAME)) {

    $WigleApiName = [string]$env:WIGLE_API_NAME
}

if ([string]::IsNullOrWhiteSpace($WigleApiToken) -and
    -not [string]::IsNullOrWhiteSpace([string]$env:WIGLE_API_TOKEN)) {

    $WigleApiToken = [string]$env:WIGLE_API_TOKEN
}

if (-not [string]::IsNullOrWhiteSpace($WigleApiName) -and
    -not [string]::IsNullOrWhiteSpace($WigleApiToken)) {

    $wigleCredentialSource = if (
        $PSBoundParameters.ContainsKey('WigleApiName') -or
        $PSBoundParameters.ContainsKey('WigleApiToken')
    ) {
        'Parameter'
    }
    else {
        'Environment'
    }
}

# Final-output visibility follows effective configuration, not merely whether a
# parameter name was present. Environment-provided credentials therefore behave
# exactly like parameter-provided credentials.
$googleResolverOutputEnabled = -not [string]::IsNullOrWhiteSpace(
    [string]$GoogleGeolocationApiKey
)

$wigleResolverOutputEnabled = (
    -not [string]::IsNullOrWhiteSpace([string]$WigleApiName) -and
    -not [string]::IsNullOrWhiteSpace([string]$WigleApiToken)
)

$bluetoothOutputEnabled = $bluetoothResultsForced

$consentSnapshot = @()
$consentTemporarilyChanged = $false
$notes = [System.Collections.Generic.List[string]]::new()

$initialConsent = if ($platform -eq 'Windows') {
    Get-WindowsCurrentLocationConsentValue
}
else {
    $null
}

$locationServiceState = if ($platform -eq 'Windows') {
    Get-WindowsLocationServiceState
}
else {
    $null
}

$nativeProvider = Get-NativeLocationProviderName
$nativeLocationStatus = 'NotAttempted'

# Determine physical device class and WLAN capability before initiating any Wi-Fi scan.
$deviceProfile = Get-DeviceProfile

Write-Verbose ('Device profile: type={0}; wifiInterfacePresent={1}; wifiInterfaces={2}; detail={3}' -f
    $deviceProfile.DeviceType,
    $deviceProfile.WifiInterfacePresent,
    $(if (@($deviceProfile.WifiInterfaceDetail).Count -gt 0) {
        @($deviceProfile.WifiInterfaceDetail) -join '; '
    }
    else {
        '<none>'
    }),
    $(if ([string]::IsNullOrWhiteSpace([string]$deviceProfile.Detail)) {
        '<none>'
    }
    else {
        $deviceProfile.Detail
    }))

# Collect around the entire conditional so PowerShell cannot unwrap a single
# GPS/GNSS evidence object into a scalar under StrictMode.
$gpsHardware = @(
    if ($platform -eq 'Windows') {
        Get-WindowsGpsHardwareEvidence
    }
)

$gpsHardwareDetected = (@($gpsHardware).Count -gt 0)

$bluetoothScan = [pscustomobject]@{
    Status  = if ($SkipBluetooth) { 'SkippedByParameter' } else { 'NotAttempted' }
    Devices = @()
    Detail  = if ($SkipBluetooth) { 'Bluetooth scan skipped by parameter.' } else { $null }
}
$bluetoothDevices = @()
$bluetoothDeviceCount = 0
$bluetoothAnchorLocation = $null

if ($bluetoothOutputEnabled -and -not $SkipBluetooth) {
    $bluetoothScan = Get-BluetoothLeEvidence `
        -ScanSeconds $effectiveBluetoothScanSeconds
    $bluetoothDevices = @($bluetoothScan.Devices)
    $bluetoothDeviceCount = @($bluetoothDevices).Count

    if (-not [string]::IsNullOrWhiteSpace([string]$BluetoothMapPath) -and
        $bluetoothDevices.Count -gt 0) {

        $bluetoothAnchorLocation = Get-KnownBluetoothLocation `
            -Devices $bluetoothDevices `
            -Path $BluetoothMapPath
    }
}

$gpsProbe = [pscustomobject]@{
    Status               = if ($platform -eq 'Windows') { 'NotAttempted' } else { 'UnsupportedPlatform' }
    PositionSource       = $null
    Latitude             = $null
    Longitude            = $null
    AccuracyMeters       = $null
    AltitudeMeters       = $null
    HorizontalDop        = $null
    PositionDop          = $null
    Detail               = $null
}
$gpsLocation = $null

try {
    # Only front-load a high-accuracy satellite probe when Windows exposes explicit
    # GPS/GNSS hardware evidence. If this detector misses an integrated receiver,
    # the normal Windows native-location stage below still uses WinRT and can identify
    # PositionSource=Satellite later.
    if ($platform -eq 'Windows' -and $gpsHardwareDetected) {
        if ($initialConsent -ne 'Allow' -and
            -not $NoTemporaryLocationConsent) {

            $consentSnapshot = @(Enable-WindowsTemporaryLocationConsent)

            if (@($consentSnapshot).Count -gt 0) {
                $consentTemporarilyChanged = $true
                Start-Sleep -Milliseconds 300
            }
        }

        $gpsProbe = Get-WindowsWinRtHighAccuracyLocation -Timeout $TimeoutSeconds
        $gpsLocation = ConvertTo-WindowsGpsLocation -Probe $gpsProbe

        if ($null -eq $gpsLocation) {
            $notes.Add(
                ('GPS/GNSS hardware was detected, but Windows did not return a verified satellite fix. Status={0}; PositionSource={1}; Detail={2}' -f
                    $gpsProbe.Status,
                    $(if ([string]::IsNullOrWhiteSpace([string]$gpsProbe.PositionSource)) { '<none>' } else { $gpsProbe.PositionSource }),
                    $(if ([string]::IsNullOrWhiteSpace([string]$gpsProbe.Detail)) { '<none>' } else { $gpsProbe.Detail }))
            )
        }
    }

    # Only ask the WLAN stack to scan when a Wi-Fi interface is actually present.
    if ($deviceProfile.WifiInterfacePresent) {
        $wifiScan = Get-NearbyWifiAccessPoint
    }
    else {
        $wifiScan = New-SkippedWifiScanResult `
            -Status 'SkippedNoWifiInterface' `
            -Reason ('No Wi-Fi interface was detected on this {0} device.' -f $deviceProfile.DeviceType)

        $notes.Add(
            ('No Wi-Fi interface was detected on this {0} device; Wi-Fi discovery and Wi-Fi geolocation were skipped.' -f
                $deviceProfile.DeviceType)
        )
    }

    # Windows can expose BSSID data only after Location permission is available.
    # Never attempt registry privacy changes on Linux or macOS.
    if ($platform -eq 'Windows' -and
        $deviceProfile.WifiInterfacePresent -and
        @($wifiScan.AccessPoints).Count -eq 0 -and
        -not $consentTemporarilyChanged -and
        -not $NoTemporaryLocationConsent) {

        $consentSnapshot = @(Enable-WindowsTemporaryLocationConsent)

        if (@($consentSnapshot).Count -gt 0) {
            $consentTemporarilyChanged = $true
            Start-Sleep -Milliseconds 300
            $wifiScan = Get-NearbyWifiAccessPoint
        }
    }

    $wifiAccessPoints = @(
        $wifiScan.AccessPoints |
            Sort-Object -Property @{ Expression = { Get-WifiSortScore -AccessPoint $_ }; Descending = $true },
                                  @{ Expression = { [string]$_.BSSID }; Descending = $false }
    )

    $googleUsableWifiAccessPoints = @($wifiAccessPoints | Where-Object GoogleUsable)

    $currentAssociatedWifiAp = @(
        $wifiAccessPoints |
            Where-Object {
                [string]$_.Source -match '^WindowsNetshCurrentInterface'
            } |
            Sort-Object -Property @{
                Expression = {
                    Get-WifiSortScore -AccessPoint $_
                }
                Descending = $true
            }
    ) | Select-Object -First 1

    $strongestGoogleUsableAp = if ($wifiAccessPoints.Count -gt 0) {
        Get-StrongestGoogleUsableWifiAccessPoint -AccessPoints $wifiAccessPoints
    }
    else {
        $null
    }
    $detectedVpnEvidence = @(Get-DetectedVpnEvidence)
    $establishedVpnEvidence = @(Get-EstablishedVpnEvidence)

    $detectedVpnTunnelIdentities = @(
        Get-VpnTunnelIdentity -Evidence $detectedVpnEvidence
    )
    $establishedVpnTunnelIdentities = @(
        Get-VpnTunnelIdentity -Evidence $establishedVpnEvidence
    )

    $detectedVpnTunnel = if (@($detectedVpnTunnelIdentities).Count -gt 0) {
        $detectedVpnTunnelIdentities -join '; '
    }
    else {
        $null
    }

    $establishedVpnTunnel = if (@($establishedVpnTunnelIdentities).Count -gt 0) {
        $establishedVpnTunnelIdentities -join '; '
    }
    else {
        $null
    }

    $establishedVpnTunnelDetails = if (@($establishedVpnEvidence).Count -gt 0) {
        @(Get-EstablishedVpnTunnelDetails)
    }
    else {
        @()
    }

    $googleWifiResolverStatus = if ([string]::IsNullOrWhiteSpace($GoogleGeolocationApiKey)) {
        'SkippedNoApiKey'
    }
    elseif ($googleUsableWifiAccessPoints.Count -lt 2) {
        'SkippedInsufficientUsableBssids'
    }
    else {
        'Ready'
    }

    $wigleWifiResolverStatus = if (
        [string]::IsNullOrWhiteSpace($WigleApiName) -or
        [string]::IsNullOrWhiteSpace($WigleApiToken)
    ) {
        'SkippedNoCredentials'
    }
    elseif ($googleUsableWifiAccessPoints.Count -lt 1) {
        'SkippedNoUsableBssids'
    }
    else {
        'Ready'
    }

    # Keep resolver candidates independently so the selected location and every
    # other coordinate source can be surfaced separately in the final result.
    $physicalLocation        = $gpsLocation
    $knownWifiLocation       = $null
    $googleWifiLocation      = $null
    $wigleWifiLocation       = $null
    $nativeLocationCandidate = $null
    $ogLocationCandidate     = $null

    if ($null -eq $physicalLocation -and
        -not [string]::IsNullOrWhiteSpace($WifiMapPath) -and
        $wifiAccessPoints.Count -gt 0) {

        $knownWifiLocation = Get-KnownWifiLocation `
            -AccessPoints $wifiAccessPoints `
            -Path $WifiMapPath

        $physicalLocation = $knownWifiLocation
    }

    if ($null -eq $physicalLocation -and $null -ne $bluetoothAnchorLocation) {
        $physicalLocation = $bluetoothAnchorLocation
    }

    if ($null -eq $physicalLocation -and $googleWifiResolverStatus -eq 'Ready') {
        $googleWifiLocation = Get-GoogleWifiLocation `
            -AccessPoints $wifiAccessPoints `
            -ApiKey $GoogleGeolocationApiKey

        $physicalLocation = $googleWifiLocation

        if ($null -ne $physicalLocation -and $physicalLocation.Method -eq 'GoogleWiFi') {
            $googleWifiResolverStatus = 'Resolved'
        }
        elseif ($script:GoogleWifiLastHttpStatus -eq 404) {
            $googleWifiResolverStatus = 'NoWifiGeolocationMatch'
        }
        elseif ($script:GoogleWifiLastHttpStatus -eq 403) {
            $googleWifiResolverStatus = 'Forbidden'
        }
        elseif ($script:GoogleWifiLastHttpStatus -eq 400) {
            $googleWifiResolverStatus = 'BadRequest'
        }
        elseif ($null -ne $script:GoogleWifiLastHttpStatus) {
            $googleWifiResolverStatus = 'HttpError{0}' -f $script:GoogleWifiLastHttpStatus
        }
        else {
            $googleWifiResolverStatus = 'FailedOrNoFix'
        }
    }
    elseif ($null -ne $physicalLocation -and $googleWifiResolverStatus -eq 'Ready') {
        $googleWifiResolverStatus = 'SkippedHigherPriorityLocationResolved'
    }

    if ($null -eq $physicalLocation -and $wigleWifiResolverStatus -eq 'Ready') {
        $wigleWifiLocation = Get-WigleWifiLocation `
            -AccessPoints $wifiAccessPoints `
            -ApiName $WigleApiName `
            -ApiToken $WigleApiToken `
            -CurrentBssid $(if ($null -ne $currentAssociatedWifiAp) { [string]$currentAssociatedWifiAp.BSSID } else { $null }) `
            -MaxLiveLookups $MaxWigleLookupsPerRun

        $physicalLocation = $wigleWifiLocation

        if ($null -ne $physicalLocation -and $physicalLocation.Method -eq 'WiGLEWiFi') {
            $wigleWifiResolverStatus = 'Resolved'
        }
        elseif ($script:WigleRateLimited) {
            $wigleWifiResolverStatus = switch ([string]$script:WigleRateLimitBasis) {
                'Http429'          { 'RateLimitedHttp429' }
                'ApiMessage'       { 'RateLimitSignaledByApiMessage' }
                'HttpErrorMessage' { 'RateLimitSignaledByHttpErrorMessage' }
                'HttpErrorBody'    { 'RateLimitSignaledByHttpErrorBody' }
                default            { 'RateLimitSignaled' }
            }
        }
        elseif ($script:WigleLastHttpStatus -eq 401) {
            $wigleWifiResolverStatus = 'AuthenticationFailedHttp401'
        }
        elseif ($script:WigleLastHttpStatus -eq 403) {
            $wigleWifiResolverStatus = 'ForbiddenHttp403'
        }
        elseif ($script:WigleTerminalFailure) {
            $wigleWifiResolverStatus = 'TerminalFailure'
        }
        elseif ($script:WigleLiveQueriesUsed -ge $MaxWigleLookupsPerRun) {
            $wigleWifiResolverStatus = 'LookupBudgetExhausted'
        }
        else {
            $wigleWifiResolverStatus = 'NoMatch'
        }
    }
    elseif ($null -ne $physicalLocation -and $wigleWifiResolverStatus -eq 'Ready') {
        $wigleWifiResolverStatus = 'SkippedHigherPriorityLocationResolved'
    }

    if ($null -eq $physicalLocation) {
        $nativeLocationStatus = 'Attempted'
        $nativeLocationCandidate = Get-NativePhysicalLocation -Timeout $TimeoutSeconds
        $physicalLocation = $nativeLocationCandidate

        if ($null -ne $physicalLocation) {
            $nativeLocationStatus = 'Resolved'
        }
        else {
            $nativeLocationStatus = 'NoFix'
        }

        # One additional Windows attempt after temporary consent, if we did not already
        # change consent for the Wi-Fi scan.
        if ($platform -eq 'Windows' -and
            $null -eq $physicalLocation -and
            -not $consentTemporarilyChanged -and
            -not $NoTemporaryLocationConsent) {

            $consentSnapshot = @(Enable-WindowsTemporaryLocationConsent)

            if (@($consentSnapshot).Count -gt 0) {
                $consentTemporarilyChanged = $true
                Start-Sleep -Milliseconds 300
                $nativeLocationCandidate = Get-NativePhysicalLocation -Timeout $TimeoutSeconds
                $physicalLocation = $nativeLocationCandidate

                if ($null -ne $physicalLocation) {
                    $nativeLocationStatus = 'ResolvedAfterTemporaryConsent'
                }
            }
        }
    }
    else {
        $nativeLocationStatus = 'SkippedHigherPriorityLocationResolved'
    }

    # Explicit physical-location selection order:
    #   GPS / known anchors -> Google Wi-Fi -> WiGLE -> newer native OS location
    #   -> revised OG GeoCoordinateWatcher -> Public IP.
    #
    # The OG coordinate remains available as provenance even when it is not selected.
    # It is only selected after all higher-priority physical resolvers fail.
    if (
        $platform -eq 'Windows' -and
        $ogDeviceCoords.Succeeded -and
        $null -ne $ogDeviceCoords.Latitude -and
        $null -ne $ogDeviceCoords.Longitude
    ) {
        $ogLocationCandidate = [pscustomobject]@{
            Method         = 'WindowsLocationOG'
            Latitude       = [double]$ogDeviceCoords.Latitude
            Longitude      = [double]$ogDeviceCoords.Longitude
            AccuracyMeters = $ogDeviceCoords.AccuracyMeters
            Site           = $null
            VpnResistant   = $null
            Detail         = 'Revised OG Windows Location Services coordinate. Used only after GPS/known anchors, Google Wi-Fi, WiGLE, and newer native OS location fail.'
        }
    }

    $ogLocationFallbackEligible = (
        $platform -eq 'Windows' -and
        $null -eq $physicalLocation -and
        $null -eq $gpsLocation -and
        $null -ne $ogLocationCandidate
    )

    if ($ogLocationFallbackEligible) {
        $physicalLocation = $ogLocationCandidate

        $notes.Add(
            'Revised OG Windows Location Services produced coordinates and was selected only after Google Wi-Fi, WiGLE, and newer native OS location failed to produce a higher-priority physical fix.'
        )

        Write-Verbose ('OG Windows Location fallback selected: latitude={0}; longitude={1}' -f
            $physicalLocation.Latitude,
            $physicalLocation.Longitude)
    }

    $publicIpLocation = $null

    if (-not $SkipPublicIpLookup) {
        $publicIpLocation = Get-PublicIpLocation
    }

    # Router WAN discovery is independent of endpoint Wi-Fi/GPS and is intentionally
    # read-only. It targets the physical/default LAN gateway, not a VPN adapter.
    $routerWanDiscovery = Get-RouterWanDiscovery
    $routerWanGeo = if (
        $null -ne $routerWanDiscovery -and
        (Get-Ipv4AddressScope -IPAddress ([string]$routerWanDiscovery.WanIPv4)) -eq 'Public'
    ) {
        Get-IpLocationByAddress -IPAddress ([string]$routerWanDiscovery.WanIPv4)
    }
    else {
        $null
    }

    $selectedLocation = $physicalLocation

    if ($null -eq $selectedLocation -and $null -ne $publicIpLocation) {
        $selectedLocation = [pscustomobject]@{
            Method         = 'PublicIP'
            Latitude       = $publicIpLocation.Latitude
            Longitude      = $publicIpLocation.Longitude
            AccuracyMeters = $null
            Site           = $null
            VpnResistant   = $false
            Detail         = 'Fallback only; coordinates represent Internet egress and may be a VPN/proxy endpoint'
        }

        if ($wifiScan.Status -in @('CurrentAssociationFallback', 'CurrentAssociationOnly') -and
            $wifiAccessPoints.Count -gt 0) {

            $notes.Add(
                ('Nearby Wi-Fi enumeration was unavailable, but {0} currently associated Wi-Fi BSSID(s) were recovered from netsh wlan show interfaces. Associated-BSSID evidence alone did not produce coordinates.' -f
                    $wifiAccessPoints.Count)
            )
        }
        elseif ($wifiAccessPoints.Count -gt 0) {
            $notes.Add(('{0} nearby Wi-Fi BSSID(s) were detected, but no Wi-Fi resolver produced coordinates.' -f $wifiAccessPoints.Count))
        }
        elseif ($deviceProfile.WifiInterfacePresent) {
            if ($wifiScan.Status -eq 'BlockedByLocationPermission' -or
                (
                    $wifiScan.PSObject.Properties.Name -contains 'NativeScanStatus' -and
                    $wifiScan.NativeScanStatus -eq 'AccessDenied'
                )) {
                $notes.Add(
                    'Nearby Wi-Fi BSSID enumeration was unavailable because Windows denied WLAN scan/BSS access under the current Location Services policy.'
                )
            }
            else {
                $notes.Add('No nearby Wi-Fi BSSIDs were collected.')
            }
        }

        $notes.Add('No device-native physical location was available; selected coordinates are based on public IP only.')
    }

    if ($null -eq $selectedLocation) {
        throw ('Unable to obtain location on {0} from GPS/GNSS, known Wi-Fi, Google Wi-Fi, native OS location, OG Windows Location Services, or public IP.' -f $platform)
    }

    # A WinRT native-location attempt can discover PositionSource=Satellite even when
    # the PnP-name heuristic did not identify the receiver in advance.
    if ($selectedLocation.Method -eq 'WindowsGPS') {
        $gpsHardwareDetected = $true

        if ($gpsProbe.Status -ne 'SatelliteFix') {
            $gpsProbe = [pscustomobject]@{
                Status               = 'SatelliteFix'
                PositionSource       = 'Satellite'
                Latitude             = [double]$selectedLocation.Latitude
                Longitude            = [double]$selectedLocation.Longitude
                AccuracyMeters       = $selectedLocation.AccuracyMeters
                AltitudeMeters       = if ($selectedLocation.PSObject.Properties.Name -contains 'AltitudeMeters') {
                                           $selectedLocation.AltitudeMeters
                                       }
                                       else {
                                           $null
                                       }
                HorizontalDop        = if ($selectedLocation.PSObject.Properties.Name -contains 'HorizontalDop') {
                                           $selectedLocation.HorizontalDop
                                       }
                                       else {
                                           $null
                                       }
                PositionDop          = if ($selectedLocation.PSObject.Properties.Name -contains 'PositionDop') {
                                           $selectedLocation.PositionDop
                                       }
                                       else {
                                           $null
                                       }
                Detail               = 'Satellite source discovered by the Windows WinRT native-location stage.'
            }
        }
    }

    $distanceKm = $null

    if ($null -ne $physicalLocation -and $null -ne $publicIpLocation) {
        $distanceKm = Get-DistanceKm `
            -Latitude1 ([double]$physicalLocation.Latitude) `
            -Longitude1 ([double]$physicalLocation.Longitude) `
            -Latitude2 ([double]$publicIpLocation.Latitude) `
            -Longitude2 ([double]$publicIpLocation.Longitude)
    }

    $vpnAdapterDetected = (@($detectedVpnEvidence).Count -gt 0)
    $vpnTunnelEstablished = (@($establishedVpnEvidence).Count -gt 0)

    $routerVpnAssessment = Get-RouterVpnAssessment `
        -RouterWan $routerWanDiscovery `
        -ObservedPublicIp $publicIpLocation `
        -EndpointVpnEstablished $vpnTunnelEstablished

    $traceGeoRows = @(
        @($routerVpnAssessment.TraceGeo) |
            Sort-Object Hop |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Hop     = $_.Hop
                    IP      = $_.IP
                    Scope   = $_.Scope
                    City    = $_.City
                    Region  = $_.Region
                    Country = $_.Country
                    ISP     = $_.ISP
                    ASN     = $_.ASN
                }
            }
    )

    $traceGeoFlat = if ($traceGeoRows.Count -gt 0) {
        (
            $traceGeoRows |
                Format-Table -AutoSize |
                Out-String -Width 4096
        ).Trim()
    }
    else {
        'None'
    }

    if (
        $selectedLocation.Method -eq 'PublicIP' -and
        $routerVpnAssessment.Suspected -eq 'True' -and
        $routerVpnAssessment.Confidence -eq 'High'
    ) {
        $selectedLocation.Detail =
            'Public-IP location represents a high-confidence upstream VPN/tunnel egress, not a reliable physical endpoint location.'
    }

    if ($routerVpnAssessment.Suspected -in @('True', 'Possible')) {
        $notes.Add(
            ('Router/upstream VPN assessment: suspected={0}; confidence={1}. See RouterVpnEvidence for the supporting path evidence.' -f
                $routerVpnAssessment.Suspected,
                $routerVpnAssessment.Confidence)
        )
    }

    # Analyst-facing VPN values.
    $vpnAdapterDetectedOutput = if (
        -not [string]::IsNullOrWhiteSpace([string]$detectedVpnTunnel)
    ) {
        [string]$detectedVpnTunnel
    }
    elseif ($vpnAdapterDetected) {
        'VPN/Tunnel'
    }
    else {
        'None'
    }

    $establishedVpnTunnelOutput = if ($vpnTunnelEstablished) {
        Format-EstablishedVpnTunnel `
            -Details $establishedVpnTunnelDetails `
            -FallbackIdentity $establishedVpnTunnel
    }
    else {
        'None'
    }

    # This field intentionally combines two strong signals:
    #   1. a currently established VPN/tunnel, or
    #   2. a large physical-vs-public-IP geographic separation.
    $remoteEgressLikely = $vpnTunnelEstablished

    if ($null -ne $distanceKm -and $distanceKm -ge 100) {
        $remoteEgressLikely = $true
        $notes.Add(
            ('Physical and public-IP locations differ by {0:N2} km; remote/VPN egress is likely.' -f
                $distanceKm)
        )
    }
    elseif ($vpnTunnelEstablished) {
        if (-not [string]::IsNullOrWhiteSpace([string]$establishedVpnTunnel)) {
            $notes.Add(
                ('An active VPN/tunnel indicator was detected ({0}). Public-IP location should not be treated as physical location.' -f
                    $establishedVpnTunnel)
            )
        }
        else {
            $notes.Add(
                'An active VPN/tunnel indicator was detected. Public-IP location should not be treated as physical location.'
            )
        }
    }

    if ($selectedLocation.Method -in @('WindowsLocation', 'MacCoreLocation', 'LinuxGeoClue')) {
        if ($null -ne $selectedLocation.AccuracyMeters -and
            [double]$selectedLocation.AccuracyMeters -le 5000) {

            $selectedLocation.VpnResistant = $true
        }
        else {
            $selectedLocation.VpnResistant = $null
            $notes.Add('Native OS location returned coarse/unknown accuracy; its underlying location source cannot be proven from this result.')
        }
    }

    if ($wifiAccessPoints.Count -gt 0 -and $googleUsableWifiAccessPoints.Count -eq 0) {
        $rejectionSummary = @(
            $wifiAccessPoints |
                Group-Object -Property GoogleEligibility |
                ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
        ) -join ', '

        $notes.Add(
            ('Wi-Fi was detected, but none of the observed BSSIDs are Google-usable. Rejection summary: {0}.' -f $rejectionSummary)
        )
    }

    if ($googleResolverOutputEnabled -and $null -ne $strongestGoogleUsableAp) {
        $signalText = if ($null -ne $strongestGoogleUsableAp.SignalDbm) {
            '{0} dBm' -f $strongestGoogleUsableAp.SignalDbm
        }
        elseif ($null -ne $strongestGoogleUsableAp.SignalPercent) {
            '{0}%' -f $strongestGoogleUsableAp.SignalPercent
        }
        else {
            '<unknown>'
        }

        $ssidText = if ([string]::IsNullOrWhiteSpace([string]$strongestGoogleUsableAp.SSID)) {
            '<unknown SSID>'
        }
        else {
            [string]$strongestGoogleUsableAp.SSID
        }

        $notes.Add(
            ('Strongest Google-usable BSSID is [{0}] ({1}) at {2}.' -f
                $strongestGoogleUsableAp.BSSID,
                $ssidText,
                $signalText)
        )
    }

    if ($googleWifiResolverStatus -eq 'Forbidden') {
        $googleErrorSummary = if (-not [string]::IsNullOrWhiteSpace([string]$script:GoogleWifiLastErrorMessage)) {
            [string]$script:GoogleWifiLastErrorMessage
        }
        else {
            'Google Geolocation API returned HTTP 403 Forbidden.'
        }

        $notes.Add(
            ('Google Wi-Fi geolocation was denied by Google (HTTP 403): {0}' -f $googleErrorSummary)
        )
    }
    elseif ($googleWifiResolverStatus -eq 'NoWifiGeolocationMatch') {
        $notes.Add(
            'Google accepted the Wi-Fi geolocation request but returned no location for the supplied BSSIDs (HTTP 404 with considerIp=false).'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($GoogleGeolocationApiKey) -and
        $googleUsableWifiAccessPoints.Count -lt 2) {

        $notes.Add(
            ('Google Wi-Fi geolocation requires at least two usable universally administered BSSIDs; {0} were available.' -f
                $googleUsableWifiAccessPoints.Count)
        )
    }

    if ($script:WigleRateLimited) {
        $notes.Add(
            ('WiGLE returned a rate-limit signal; further WiGLE requests were stopped for this execution. Basis=[{0}]; HTTP=[{1}]; message=[{2}]; liveQueries={3}/{4}; remainingHeader=[{5}]; limitHeader=[{6}].' -f
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitBasis)) { 'Unknown' } else { $script:WigleRateLimitBasis }),
                $(if ($null -eq $script:WigleLastHttpStatus) { 'Unknown' } else { $script:WigleLastHttpStatus }),
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorMessage)) { 'NotReported' } else { $script:WigleLastErrorMessage }),
                $script:WigleLiveQueriesUsed,
                $MaxWigleLookupsPerRun,
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitRemaining)) { 'NotReported' } else { $script:WigleRateLimitRemaining }),
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitLimit)) { 'NotReported' } else { $script:WigleRateLimitLimit })
            )
        )
    }

    elseif ($script:WigleTerminalFailure) {
        $notes.Add(
            ('WiGLE returned a terminal HTTP/API condition; further BSSID requests were stopped after the first terminal response. Basis=[{0}]; HTTP=[{1}]; message=[{2}]; body=[{3}]; liveQueries={4}/{5}.' -f
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleTerminalFailureBasis)) { 'Unknown' } else { $script:WigleTerminalFailureBasis }),
                $(if ($null -eq $script:WigleLastHttpStatus) { 'Unknown' } else { $script:WigleLastHttpStatus }),
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorMessage)) { 'NotReported' } else { $script:WigleLastErrorMessage }),
                $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorBody)) { 'NotReported' } else { $script:WigleLastErrorBody }),
                $script:WigleLiveQueriesUsed,
                $MaxWigleLookupsPerRun
            )
        )
    }
    elseif ($wigleWifiResolverStatus -eq 'AuthenticationFailed') {
        $notes.Add(
            'WiGLE rejected the configured API credentials. Verify WIGLE_API_NAME and WIGLE_API_TOKEN.'
        )
    }
    elseif ($wigleWifiResolverStatus -eq 'LookupBudgetExhausted') {
        $notes.Add(
            ('WiGLE fallback stopped after reaching the configured per-run live lookup budget [{0}].' -f
                $MaxWigleLookupsPerRun)
        )
    }

    if ($bluetoothScan.Status -eq 'Failed') {
        $notes.Add(('Bluetooth LE scan failed or was unavailable: {0}' -f $bluetoothScan.Detail))
    }
    elseif ($bluetoothScan.Status -eq 'Success' -and $bluetoothDeviceCount -eq 0) {
        $notes.Add('Bluetooth LE scan completed but no advertisements were observed during the scan window.')
    }

    elseif ($bluetoothScan.Status -eq 'Success' -and $bluetoothDeviceCount -gt 0) {
        $notes.Add(
            ('Bluetooth LE scan observed {0} unique advertiser(s). BLE fingerprints are passive proximity hints built from address type, name, advertisement type, company identifiers, services, and OUI where eligible; no pairing, connection, or GATT interrogation was performed.' -f
                $bluetoothDeviceCount)
        )
    }

    if ($platform -eq 'Windows' -and
        $wifiScan.Status -eq 'CurrentAssociationFallback') {

        $notes.Add(
            'Windows denied nearby WLAN scan/BSS enumeration, but the current associated AP was recovered through netsh wlan show interfaces. This evidence is association-only and does not represent the surrounding RF environment.'
        )
    }

    if ($platform -eq 'Windows' -and
        $wifiScan.PSObject.Properties.Name -contains 'NativeScanStatus' -and
        $wifiScan.NativeScanStatus -ne 'Success') {

        $nativeErrorText = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanError' -and
                               -not [string]::IsNullOrWhiteSpace([string]$wifiScan.NativeScanError)) {
            ' Error: {0}' -f $wifiScan.NativeScanError
        }
        else {
            ''
        }

        $notes.Add(
            ('Native Windows WlanScan refresh status was [{0}]. The script continued with the WLAN cache/netsh fallback.{1}' -f
                $wifiScan.NativeScanStatus,
                $nativeErrorText)
        )
    }

    if ($platform -eq 'Windows' -and $locationServiceState -ne 'Running') {
        $notes.Add(
            ('Windows Geolocation Service (lfsvc) state is [{0}]. Windows Location may not resolve until the service is available.' -f
                $locationServiceState)
        )
    }

    if ($platform -eq 'Linux' -and $nativeProvider -eq 'GeoClueUnavailable') {
        $notes.Add('GeoClue where-am-i helper was not found. Linux native location was unavailable; Wi-Fi resolvers and public-IP fallback remain available.')
    }

    if ($platform -eq 'macOS' -and @($wifiScan.AccessPoints).Count -eq 0) {
        $notes.Add('macOS may restrict SSID/BSSID access until Location Services permission is granted to the process providing Wi-Fi information.')
    }

    $localCanadianCity = Resolve-CanadianMajorCityLocal `
        -Latitude ([double]$selectedLocation.Latitude) `
        -Longitude ([double]$selectedLocation.Longitude)

    $locality = $null

    if ($null -ne $localCanadianCity) {
        $locality = [pscustomobject]@{
            City             = [string]$localCanadianCity.City
            Region           = [string]$localCanadianCity.Province
            Country          = 'Canada'
            MatchType        = [string]$localCanadianCity.MatchType
            InsideRange      = [bool]$localCanadianCity.InsideRange
            CenterDistanceKm = [double]$localCanadianCity.DistanceFromCenterKm
            CenterLat        = [double]$localCanadianCity.CenterLat
            CenterLon        = [double]$localCanadianCity.CenterLon
            MinLat           = [double]$localCanadianCity.MinLat
            MaxLat           = [double]$localCanadianCity.MaxLat
            MinLon           = [double]$localCanadianCity.MinLon
            MaxLon           = [double]$localCanadianCity.MaxLon
            Source           = 'CanadianEmbeddedCityTable'
        }

        Write-Verbose ('Local Canadian city resolver: city={0}; province={1}; matchType={2}; insideRange={3}; centerDistanceKm={4}' -f
            $locality.City,
            $locality.Region,
            $locality.MatchType,
            $locality.InsideRange,
            $locality.CenterDistanceKm)
    }
    elseif ($selectedLocation.Method -eq 'PublicIP' -and
            $null -ne $publicIpLocation) {

        $locality = [pscustomobject]@{
            City             = if ([string]::IsNullOrWhiteSpace([string]$publicIpLocation.City)) { 'NotReported' } else { [string]$publicIpLocation.City }
            Region           = if ([string]::IsNullOrWhiteSpace([string]$publicIpLocation.Region)) { 'NotReported' } else { [string]$publicIpLocation.Region }
            Country          = if ([string]::IsNullOrWhiteSpace([string]$publicIpLocation.Country)) { 'NotReported' } else { [string]$publicIpLocation.Country }
            MatchType        = 'PublicIpGeo'
            InsideRange      = $false
            CenterDistanceKm = $null
            CenterLat        = $null
            CenterLon        = $null
            MinLat           = $null
            MaxLat           = $null
            MinLon           = $null
            MaxLon           = $null
            Source           = 'PublicIpGeo'
        }
    }

    function New-GoogleMapsSearchUri {
        param(
            [AllowNull()]
            [object]$Location
        )

        if ($null -eq $Location) {
            return $null
        }

        if (
            -not ($Location.PSObject.Properties.Name -contains 'Latitude') -or
            -not ($Location.PSObject.Properties.Name -contains 'Longitude') -or
            $null -eq $Location.Latitude -or
            $null -eq $Location.Longitude
        ) {
            return $null
        }

        $latText = ([double]$Location.Latitude).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
        $lonText = ([double]$Location.Longitude).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )

        return 'https://www.google.com/maps/search/?api=1&query={0},{1}' -f
            $latText,
            $lonText
    }

    $selectedMapUri        = New-GoogleMapsSearchUri -Location $selectedLocation
    $mapUri                = $selectedMapUri
    $gpsMapUri             = New-GoogleMapsSearchUri -Location $gpsLocation
    $knownWifiMapUri       = New-GoogleMapsSearchUri -Location $knownWifiLocation
    $bluetoothAnchorMapUri = New-GoogleMapsSearchUri -Location $bluetoothAnchorLocation
    $googleWifiMapUri      = New-GoogleMapsSearchUri -Location $googleWifiLocation
    $wigleMapUri           = New-GoogleMapsSearchUri -Location $wigleWifiLocation
    $nativeLocationMapUri  = New-GoogleMapsSearchUri -Location $nativeLocationCandidate
    $ogLocationMapUri      = New-GoogleMapsSearchUri -Location $ogLocationCandidate
    $publicIpMapUri        = New-GoogleMapsSearchUri -Location $publicIpLocation
    $routerWanMapUri       = New-GoogleMapsSearchUri -Location $routerWanGeo

    $latitudeText = ([double]$selectedLocation.Latitude).ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $longitudeText = ([double]$selectedLocation.Longitude).ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )

    $ogDevcoordscriptSays = $null
    $ogAndNewgGap = $null

    if ($ogDeviceCoords.Succeeded -and
        $null -ne $ogDeviceCoords.Latitude -and
        $null -ne $ogDeviceCoords.Longitude) {

        $ogLatitudeText = ([double]$ogDeviceCoords.Latitude).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
        $ogLongitudeText = ([double]$ogDeviceCoords.Longitude).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )

        # Preserve the exact map URI emitted by the revised OG script when available.
        $ogDevcoordscriptSays = if (
            -not [string]::IsNullOrWhiteSpace([string]$ogDeviceCoords.MapUri)
        ) {
            [string]$ogDeviceCoords.MapUri
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$ogLocationMapUri)) {
            [string]$ogLocationMapUri
        }
        else {
            $null
        }

        $ogAndNewgGap =
            'https://www.google.com/maps/dir/?api=1&origin={0},{1}&destination={2},{3}' -f
                $ogLatitudeText,
                $ogLongitudeText,
                $latitudeText,
                $longitudeText
    }
    else {
        $notes.Add(
            ('Revised OG Get-DeviceCoords comparison coordinate was unavailable. {0}' -f
                $ogDeviceCoords.Detail)
        )
    }

    function Get-OuiFromBssid {
        param(
            [AllowNull()]
            [string]$Bssid
        )

        if ([string]::IsNullOrWhiteSpace($Bssid)) {
            return $null
        }

        $hex = ($Bssid -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()

        if ($hex.Length -lt 6) {
            return $null
        }

        return $hex.Substring(0, 6)
    }

    function ConvertTo-CompactOuiVendor {
        param(
            [AllowNull()]
            [string]$Vendor
        )

        if ([string]::IsNullOrWhiteSpace($Vendor)) {
            return 'Unknown'
        }

        $value = $Vendor.Trim()

        if ($value -in @('*NO COMPANY*', '*PRIVATE*')) {
            return $(if ($value -eq '*PRIVATE*') { 'Private' } else { 'Unknown' })
        }

        # Analyst-facing vendor label:
        #   1. Keep only the portion before the first comma.
        #   2. Remove trailing Inc / Inc. / Incorporated.
        #   3. Remove punctuation left behind by the legal suffix.
        #
        # Examples:
        #   "TP-LINK TECHNOLOGIES CO., LTD." -> "TP-LINK TECHNOLOGIES CO"
        #   "Alpha Networks Inc."            -> "Alpha Networks"
        #   "Hitron Technologies. Inc"       -> "Hitron Technologies"
        $value = @($value -split ',', 2)[0].Trim()

        $value = $value -replace '(?i)\s+Inc(?:orporated)?\.?\s*$', ''
        $value = $value.Trim().TrimEnd('.', ',', ';')

        if ([string]::IsNullOrWhiteSpace($value)) {
            return 'Unknown'
        }

        return $value
    }

    function Get-OuiVendorCachePath {
        $basePath = $null

        switch (Get-PlatformName) {
            'Windows' {
                if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
                    $basePath = [string]$env:LOCALAPPDATA
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
                    $basePath = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Local'
                }
            }

            'Linux' {
                if (-not [string]::IsNullOrWhiteSpace([string]$env:XDG_CACHE_HOME)) {
                    $basePath = [string]$env:XDG_CACHE_HOME
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$HOME)) {
                    $basePath = Join-Path -Path $HOME -ChildPath '.cache'
                }
            }

            'macOS' {
                if (-not [string]::IsNullOrWhiteSpace([string]$HOME)) {
                    $basePath = Join-Path -Path $HOME -ChildPath 'Library/Caches'
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$basePath)) {
            return $null
        }

        return Join-Path `
            -Path (Join-Path -Path $basePath -ChildPath 'Get-DeviceCoords') `
            -ChildPath 'oui-vendor-cache.json'
    }

    function Read-OuiVendorCache {
        param(
            [AllowNull()]
            [string]$Path
        )

        $cache = @{}

        if ([string]::IsNullOrWhiteSpace([string]$Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $cache
        }

        try {
            $raw = Get-Content `
                -LiteralPath $Path `
                -Raw `
                -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace([string]$raw)) {
                return $cache
            }

            $entries = @($raw | ConvertFrom-Json -ErrorAction Stop)

            foreach ($entry in $entries) {
                $oui = ([string]$entry.Oui).ToUpperInvariant()

                if ($oui -notmatch '^[0-9A-F]{6}$') {
                    continue
                }

                $vendor = ConvertTo-CompactOuiVendor -Vendor ([string]$entry.Vendor)

                $cache[$oui] = [pscustomobject]@{
                    Vendor     = $vendor
                    CheckedUtc = [string]$entry.CheckedUtc
                }
            }
        }
        catch {
            Write-Verbose ('OUI vendor cache read failed [{0}]: {1}' -f
                $Path,
                $_.Exception.Message)
        }

        return $cache
    }

    function Test-OuiVendorCacheEntryFresh {
        param(
            [AllowNull()]
            [object]$Entry
        )

        if ($null -eq $Entry -or
            [string]::IsNullOrWhiteSpace([string]$Entry.CheckedUtc)) {
            return $false
        }

        try {
            $checkedUtc = [datetime]::Parse(
                [string]$Entry.CheckedUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUniversalTime()
        }
        catch {
            return $false
        }

        $vendor = ConvertTo-CompactOuiVendor -Vendor ([string]$Entry.Vendor)

        # Positive/Private OUI assignments change infrequently.
        # Unknown entries receive a shorter TTL so newly published assignments
        # can eventually be retried.
        $ttlDays = if ($vendor -eq 'Unknown') { 30 } else { 365 }

        return (((Get-Date).ToUniversalTime() - $checkedUtc).TotalDays -lt $ttlDays)
    }

    function Write-OuiVendorCache {
        param(
            [AllowNull()]
            [string]$Path,

            [Parameter(Mandatory)]
            [hashtable]$Cache
        )

        if ([string]::IsNullOrWhiteSpace([string]$Path)) {
            return
        }

        try {
            $directory = Split-Path -Path $Path -Parent

            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                [void](New-Item `
                    -ItemType Directory `
                    -Path $directory `
                    -Force `
                    -ErrorAction Stop)
            }

            $entries = @(
                foreach ($oui in @($Cache.Keys | Sort-Object)) {
                    $entry = $Cache[$oui]

                    [pscustomobject][ordered]@{
                        Oui        = [string]$oui
                        Vendor     = ConvertTo-CompactOuiVendor -Vendor ([string]$entry.Vendor)
                        CheckedUtc = [string]$entry.CheckedUtc
                    }
                }
            )

            $json = $entries | ConvertTo-Json -Depth 4

            # Atomic-ish replacement keeps a partial write from corrupting the
            # persistent cache if a process is interrupted during serialization.
            $tempPath = '{0}.{1}.tmp' -f $Path, [Guid]::NewGuid().ToString('N')

            Set-Content `
                -LiteralPath $tempPath `
                -Value $json `
                -Encoding UTF8 `
                -Force `
                -ErrorAction Stop

            Move-Item `
                -LiteralPath $tempPath `
                -Destination $Path `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Write-Verbose ('OUI vendor cache write failed [{0}]: {1}' -f
                $Path,
                $_.Exception.Message)
        }
    }

    function Resolve-OuiVendor {
        param(
            [Parameter(Mandatory)]
            [ValidatePattern('^[0-9A-Fa-f]{6}$')]
            [string]$Oui
        )

        $normalizedOui = $Oui.ToUpperInvariant()

        # Primary: MACLookup company-name endpoint. Only the 24-bit OUI is sent,
        # never the complete BSSID.
        try {
            $primaryUri = 'https://api.maclookup.app/v2/macs/{0}/company/name' -f
                $normalizedOui

            $primary = Invoke-RestMethod `
                -Uri $primaryUri `
                -Method Get `
                -TimeoutSec 3 `
                -ErrorAction Stop

            $vendor = ConvertTo-CompactOuiVendor -Vendor ([string]$primary)

            if ($vendor -notin @('Unknown', 'Private')) {
                return $vendor
            }

            if ($vendor -eq 'Private') {
                return $vendor
            }
        }
        catch {
            Write-Verbose ('Primary OUI lookup failed for [{0}]: {1}' -f
                $normalizedOui,
                $_.Exception.Message)
        }

        # Secondary: MACVendorLookup. Again, send only the OUI rather than the
        # full BSSID so RF evidence is not unnecessarily disclosed.
        try {
            $secondaryUri = 'https://www.macvendorlookup.com/api/v2/{0}' -f
                $normalizedOui

            $secondary = Invoke-RestMethod `
                -Uri $secondaryUri `
                -Method Get `
                -TimeoutSec 3 `
                -ErrorAction Stop

            $first = @($secondary) | Select-Object -First 1

            if ($null -ne $first -and
                -not [string]::IsNullOrWhiteSpace([string]$first.company)) {
                return ConvertTo-CompactOuiVendor -Vendor ([string]$first.company)
            }
        }
        catch {
            Write-Verbose ('Secondary OUI lookup failed for [{0}]: {1}' -f
                $normalizedOui,
                $_.Exception.Message)
        }

        return 'Unknown'
    }

    function Get-OuiVendorMap {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [object[]]$AccessPoints
        )

        $map = @{}

        # Resolve only unique OUIs from APs that already survived the useful
        # WifiEvidence filter. This prevents irrelevant/rejected APs from
        # generating any vendor API traffic.
        $ouis = @(
            $AccessPoints |
                Where-Object {
                    $_.GoogleUsable -eq $true
                } |
                ForEach-Object {
                    Get-OuiFromBssid -Bssid ([string]$_.BSSID)
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Sort-Object -Unique
        )

        $cachePath = Get-OuiVendorCachePath
        $persistentCache = Read-OuiVendorCache -Path $cachePath

        $cacheHits = 0
        $liveLookups = 0
        $cacheChanged = $false

        foreach ($oui in $ouis) {
            # Per-run cache: never query/resolve an OUI more than once during
            # this execution regardless of how many BSSIDs share that OUI.
            if ($map.ContainsKey($oui)) {
                continue
            }

            if ($persistentCache.ContainsKey($oui) -and
                (Test-OuiVendorCacheEntryFresh -Entry $persistentCache[$oui])) {

                $map[$oui] = ConvertTo-CompactOuiVendor `
                    -Vendor ([string]$persistentCache[$oui].Vendor)

                $cacheHits++
                continue
            }

            $vendor = Resolve-OuiVendor -Oui $oui
            $vendor = ConvertTo-CompactOuiVendor -Vendor $vendor

            $map[$oui] = $vendor

            $persistentCache[$oui] = [pscustomobject]@{
                Vendor     = $vendor
                CheckedUtc = (Get-Date).ToUniversalTime().ToString('o')
            }

            $liveLookups++
            $cacheChanged = $true

            # Anonymous MACLookup allows multiple requests/sec, but vendor data
            # is not latency-sensitive. Stay deliberately conservative.
            Start-Sleep -Milliseconds 125
        }

        if ($cacheChanged) {
            Write-OuiVendorCache `
                -Path $cachePath `
                -Cache $persistentCache
        }

        Write-Verbose ('Wi-Fi OUI vendor enrichment: candidateOuis={0}; cacheHits={1}; liveLookups={2}; resolved={3}; unknown={4}; cache={5}' -f
            $ouis.Count,
            $cacheHits,
            $liveLookups,
            @($map.GetEnumerator() | Where-Object Value -notin @('Unknown')).Count,
            @($map.GetEnumerator() | Where-Object Value -eq 'Unknown').Count,
            $(if ([string]::IsNullOrWhiteSpace([string]$cachePath)) { '<unavailable>' } else { $cachePath }))

        return $map
    }

    # Keep WifiEvidence analyst-facing and compact while preserving the evidence
    # needed to identify/compare nearby access points. The resolver still receives
    # the full internal Wi-Fi objects; this only changes final presentation.
    #
    # Useful evidence:
    #   - Google-usable / universally administered nearby BSSID, OR
    #   - the currently associated BSSID recovered from netsh wlan show interfaces
    #   - non-empty BSSID
    #   - at least one signal measurement
    #   - one strongest row per BSSID
    #
    # A current associated BSSID may be locally administered. It remains useful
    # analyst evidence but is NEVER promoted into the Google-usable collection.
    $usefulWifiEvidence = @(
        $wifiAccessPoints |
            Where-Object {
                $null -ne $_ -and
                (
                    $_.GoogleUsable -eq $true -or
                    [string]$_.Source -match '^WindowsNetshCurrentInterface'
                ) -and
                -not [string]::IsNullOrWhiteSpace([string]$_.BSSID) -and
                ($null -ne $_.SignalPercent -or $null -ne $_.SignalDbm)
            } |
            Sort-Object @{
                Expression = {
                    Get-WifiSortScore -AccessPoint $_
                }
                Descending = $true
            } |
            Group-Object BSSID |
            ForEach-Object {
                $_.Group | Select-Object -First 1
            } |
            Sort-Object @{
                Expression = {
                    Get-WifiSortScore -AccessPoint $_
                }
                Descending = $true
            }
    )

    $ouiVendorMap = Get-OuiVendorMap -AccessPoints $usefulWifiEvidence

    $wifiEvidenceRows = @(
        $usefulWifiEvidence |
            ForEach-Object {
                $oui = Get-OuiFromBssid -Bssid ([string]$_.BSSID)
                $ouiVendor = if (
                    $_.GoogleEligibility -eq 'LocallyAdministered'
                ) {
                    'Private'
                }
                elseif (
                    -not [string]::IsNullOrWhiteSpace([string]$oui) -and
                    $ouiVendorMap.ContainsKey($oui)
                ) {
                    [string]$ouiVendorMap[$oui]
                }
                else {
                    'Unknown'
                }

                [pscustomobject][ordered]@{
                    OUIVend = $ouiVendor
                    BSSID   = [string]$_.BSSID
                    SSID    = if ([string]::IsNullOrWhiteSpace([string]$_.SSID)) {
                                 '<hidden>'
                             }
                             else {
                                 [string]$_.SSID
                             }
                    'Sig%'  = if ($null -ne $_.SignalPercent) {
                                 [int]$_.SignalPercent
                             }
                             else {
                                 $null
                             }
                    SignDb  = if ($null -ne $_.SignalDbm) {
                                 [int]$_.SignalDbm
                             }
                             else {
                                 $null
                             }
                    Ch      = if ($null -ne $_.Channel) {
                                 [int]$_.Channel
                             }
                             else {
                                 $null
                             }
                }
            }
    )

    $strongestBluetooth = @($bluetoothDevices | Sort-Object -Property @{ Expression = { [int]$_.Rssi }; Descending = $true }) | Select-Object -First 1
    $bluetoothAnchorCount = if ($null -ne $bluetoothAnchorLocation -and $bluetoothAnchorLocation.PSObject.Properties.Name -contains 'AnchorCount') { [int]$bluetoothAnchorLocation.AnchorCount } else { 0 }
    $bluetoothLocationDistanceKm = if ($null -ne $bluetoothAnchorLocation -and $null -ne $selectedLocation) {
        Get-DistanceKm `
            -Latitude1 ([double]$bluetoothAnchorLocation.Latitude) `
            -Longitude1 ([double]$bluetoothAnchorLocation.Longitude) `
            -Latitude2 ([double]$selectedLocation.Latitude) `
            -Longitude2 ([double]$selectedLocation.Longitude)
    }
    else {
        $null
    }

    $bluetoothEvidenceFlat = $null

    if ($bluetoothOutputEnabled) {
        $bluetoothEvidenceFlat = Get-BluetoothEvidenceFlat `
            -Devices $bluetoothDevices `
            -AnchorLocation $bluetoothAnchorLocation `
            -Status ([string]$bluetoothScan.Status) `
            -Detail ([string]$bluetoothScan.Detail) `
            -ScanSeconds $effectiveBluetoothScanSeconds `
            -ForceStatusOutput:$bluetoothResultsForced
    }

    if ($null -ne $bluetoothAnchorLocation) {
        $notes.Add(
            ('Bluetooth anchor [{0}] corroborated physical location with {1} matched anchor(s).' -f
                $bluetoothAnchorLocation.AnchorName,
                $bluetoothAnchorLocation.AnchorCount)
        )
    }

    $wifiScanStatusOutput = if (
        $platform -eq 'Windows' -and
        (
            $wifiScan.Status -eq 'BlockedByLocationPermission' -or
            $wifiScan.Status -eq 'CurrentAssociationFallback' -or
            (
                $wifiScan.PSObject.Properties.Name -contains 'NativeScanStatus' -and
                $wifiScan.NativeScanStatus -eq 'AccessDenied'
            )
        )
    ) {
        'AccessDenied'
    }
    elseif ($wifiScan.Status -eq 'Success') {
        'Success'
    }
    elseif ($wifiScan.Status -eq 'CurrentAssociationOnly') {
        'CurrentAssociationOnly'
    }
    elseif ($wifiScan.Status -eq 'NoBssidsParsed') {
        'NoBssids'
    }
    elseif ($wifiScan.Status -eq 'CollectorUnavailable') {
        'Unavailable'
    }
    elseif ($wifiScan.Status -eq 'CollectorError') {
        'CollectorError'
    }
    else {
        [string]$wifiScan.Status
    }

    $wifiEvidenceFlat = if ($wifiEvidenceRows.Count -gt 0) {
        (
            $wifiEvidenceRows |
                Format-Table -AutoSize |
                Out-String -Width 4096
        ).Trim()
    }
    elseif ($wifiScanStatusOutput -eq 'AccessDenied') {
        'Unavailable - Windows location policy denied BSSID enumeration'
    }
    else {
        'None'
    }

    $notesFlat = (
        @($notes) |
            Out-String -Width 4096
    ).Trim()

    # Keep operational/test diagnostics out of the primary result object.
    # They remain available whenever the caller uses -Verbose.
    $verboseRefreshMethod = if ($wifiScan.PSObject.Properties.Name -contains 'RefreshMethod') {
        $wifiScan.RefreshMethod
    }
    else {
        $null
    }

    $verboseNativeScanStatus = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanStatus') {
        $wifiScan.NativeScanStatus
    }
    else {
        $null
    }

    $verboseNativeScanInterfaceCount = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanInterfaceCount') {
        $wifiScan.NativeScanInterfaceCount
    }
    else {
        $null
    }

    $verboseNativeScanSuccessfulCount = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanSuccessfulCount') {
        $wifiScan.NativeScanSuccessfulCount
    }
    else {
        $null
    }

    $verboseNativeScanInterfaces = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanInterfaces') {
        (@($wifiScan.NativeScanInterfaces) -join '; ')
    }
    else {
        $null
    }

    $verboseNativeScanResults = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanResults') {
        (@($wifiScan.NativeScanResults) -join '; ')
    }
    else {
        $null
    }

    $verboseNativeScanError = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanError') {
        $wifiScan.NativeScanError
    }
    else {
        $null
    }

    $verboseNativeScanWaitMilliseconds = if ($wifiScan.PSObject.Properties.Name -contains 'NativeScanWaitMilliseconds') {
        $wifiScan.NativeScanWaitMilliseconds
    }
    else {
        $null
    }

    $verboseScanAttempts = if ($wifiScan.PSObject.Properties.Name -contains 'ScanAttempts') {
        $wifiScan.ScanAttempts
    }
    else {
        1
    }

    $verboseRawBssidCount = if ($wifiScan.PSObject.Properties.Name -contains 'RawBssidCount') {
        $wifiScan.RawBssidCount
    }
    else {
        $wifiAccessPoints.Count
    }

    $verboseGoogleWifiAccessPointsUsed = if (
        $selectedLocation.Method -eq 'GoogleWiFi' -and
        $selectedLocation.PSObject.Properties.Name -contains 'GoogleAccessPointsUsed'
    ) {
        $selectedLocation.GoogleAccessPointsUsed
    }
    else {
        0
    }

    $frameworkDescription = try {
        [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    }
    catch {
        [System.Environment]::Version.ToString()
    }

    Write-Verbose ('Platform: {0}; PowerShell: {1}; Runtime: {2}' -f
        $platform,
        [string]$PSVersionTable.PSVersion,
        $frameworkDescription)

    Write-Verbose ('Wi-Fi collector: {0}; status: {1}; exitCode: {2}; error: {3}' -f
        $wifiScan.Collector,
        $wifiScan.Status,
        $wifiScan.ExitCode,
        $(if ([string]::IsNullOrWhiteSpace([string]$wifiScan.ErrorText)) { '<none>' } else { $wifiScan.ErrorText }))

    Write-Verbose ('Wi-Fi refresh: method={0}; nativeStatus={1}; interfaces={2}; successfulScans={3}; results={4}; waitMs={5}; error={6}' -f
        $(if ([string]::IsNullOrWhiteSpace([string]$verboseRefreshMethod)) { '<none>' } else { $verboseRefreshMethod }),
        $(if ([string]::IsNullOrWhiteSpace([string]$verboseNativeScanStatus)) { '<none>' } else { $verboseNativeScanStatus }),
        $(if ([string]::IsNullOrWhiteSpace([string]$verboseNativeScanInterfaces)) { $verboseNativeScanInterfaceCount } else { $verboseNativeScanInterfaces }),
        $verboseNativeScanSuccessfulCount,
        $(if ([string]::IsNullOrWhiteSpace([string]$verboseNativeScanResults)) { '<none>' } else { $verboseNativeScanResults }),
        $verboseNativeScanWaitMilliseconds,
        $(if ([string]::IsNullOrWhiteSpace([string]$verboseNativeScanError)) { '<none>' } else { $verboseNativeScanError }))

    Write-Verbose ('Bluetooth output: explicitControls={0}; scanSeconds={1}; mapSupplied={2}; skip={3}' -f
        $bluetoothResultsForced,
        $effectiveBluetoothScanSeconds,
        (-not [string]::IsNullOrWhiteSpace([string]$BluetoothMapPath)),
        [bool]$SkipBluetooth)

    Write-Verbose ('Bluetooth: status={0}; devices={1}; anchorCount={2}; strongest={3}/{4}' -f
        $bluetoothScan.Status,
        $bluetoothDeviceCount,
        $bluetoothAnchorCount,
        $(if ($null -eq $strongestBluetooth) { '<none>' } else { $strongestBluetooth.Name }),
        $(if ($null -eq $strongestBluetooth) { '<none>' } else { $strongestBluetooth.Rssi }))

    Write-Verbose ('Wi-Fi resolvers: googleStatus={0}; wigleStatus={1}; wigleCredentialSource={2}; wigleLiveQueries={3}/{4}; wigleCacheHits={5}; wigleRateLimited={6}; rateBasis={7}; lastHttp={8}; candidates={9}; currentFirst={10}; terminal={11}; terminalBasis={12}' -f
        $googleWifiResolverStatus,
        $wigleWifiResolverStatus,
        $wigleCredentialSource,
        $script:WigleLiveQueriesUsed,
        $MaxWigleLookupsPerRun,
        $script:WigleCacheHits,
        $script:WigleRateLimited,
        $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitBasis)) { '<none>' } else { $script:WigleRateLimitBasis }),
        $(if ($null -eq $script:WigleLastHttpStatus) { '<unknown>' } else { $script:WigleLastHttpStatus }),
        $script:WigleCandidateCount,
        $script:WigleCurrentBssidPrioritized,
        $script:WigleTerminalFailure,
        $(if ([string]::IsNullOrWhiteSpace([string]$script:WigleTerminalFailureBasis)) { '<none>' } else { $script:WigleTerminalFailureBasis }))

    Write-Verbose ('Wi-Fi evidence: attempts={0}; rawBssids={1}; nearbyBssids={2}; googleUsable={3}' -f
        $verboseScanAttempts,
        $verboseRawBssidCount,
        $wifiAccessPoints.Count,
        $googleUsableWifiAccessPoints.Count)

    Write-Verbose ('GPS/GNSS: hardwareDetected={0}; devices={1}; status={2}; positionSource={3}; latitude={4}; longitude={5}; accuracyMeters={6}; altitudeMeters={7}; HDOP={8}; PDOP={9}' -f
        $gpsHardwareDetected,
        $(if (@($gpsHardware).Count -gt 0) {
            @($gpsHardware | ForEach-Object { $_.Name }) -join '; '
        }
        else {
            '<none>'
        }),
        $gpsProbe.Status,
        $(if ([string]::IsNullOrWhiteSpace([string]$gpsProbe.PositionSource)) { '<none>' } else { $gpsProbe.PositionSource }),
        $(if ($null -eq $gpsProbe.Latitude) { '<none>' } else { $gpsProbe.Latitude }),
        $(if ($null -eq $gpsProbe.Longitude) { '<none>' } else { $gpsProbe.Longitude }),
        $(if ($null -eq $gpsProbe.AccuracyMeters) { '<none>' } else { $gpsProbe.AccuracyMeters }),
        $(if ($null -eq $gpsProbe.AltitudeMeters) { '<none>' } else { $gpsProbe.AltitudeMeters }),
        $(if ($null -eq $gpsProbe.HorizontalDop) { '<none>' } else { $gpsProbe.HorizontalDop }),
        $(if ($null -eq $gpsProbe.PositionDop) { '<none>' } else { $gpsProbe.PositionDop }))

    Write-Verbose ('Native location: provider={0}; status={1}' -f
        $nativeProvider,
        $nativeLocationStatus)

    if ($platform -eq 'Windows') {
        $locationConsentTargets = @(Get-WindowsLocationConsentTargets)

        Write-Verbose ('Windows Location consent targets: {0}' -f
            $(if ($locationConsentTargets.Count -gt 0) {
                $locationConsentTargets -join '; '
            }
            else {
                '<none>'
            }))

        Write-Verbose ('Windows location: service={0}; initialConsent={1}; temporaryConsentUsed={2}' -f
            $locationServiceState,
            $(if ([string]::IsNullOrWhiteSpace([string]$initialConsent)) { '<unset>' } else { $initialConsent }),
            $consentTemporarilyChanged)
    }

    Write-Verbose ('Google Wi-Fi resolver: configured={0}; status={1}; keySource={2}; accessPointsUsed={3}; httpStatus={4}; reason={5}; error={6}' -f
        (-not [string]::IsNullOrWhiteSpace($GoogleGeolocationApiKey)),
        $googleWifiResolverStatus,
        $googleApiKeySource,
        $verboseGoogleWifiAccessPointsUsed,
        $(if ($null -eq $script:GoogleWifiLastHttpStatus) { '<none>' } else { $script:GoogleWifiLastHttpStatus }),
        $(if ([string]::IsNullOrWhiteSpace([string]$script:GoogleWifiLastErrorReason)) { '<none>' } else { $script:GoogleWifiLastErrorReason }),
        $(if ([string]::IsNullOrWhiteSpace([string]$script:GoogleWifiLastErrorMessage)) { '<none>' } else { $script:GoogleWifiLastErrorMessage }))

    Write-Verbose ('VPN/tunnel detection: detected={0}; identity={1}; evidenceCount={2}' -f
        $vpnAdapterDetected,
        $vpnAdapterDetectedOutput,
        @($detectedVpnEvidence).Count)

    Write-Verbose ('VPN/tunnel established: established={0}; identity={1}; evidenceCount={2}; detailCount={3}' -f
        $vpnTunnelEstablished,
        $establishedVpnTunnelOutput,
        @($establishedVpnEvidence).Count,
        @($establishedVpnTunnelDetails).Count)

    Write-Verbose ('Local network: interface={0}; type={1}; localIPv4={2}; defaultGateway={3}' -f
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.InterfaceAlias)) { '<none>' } else { $routerWanDiscovery.InterfaceAlias }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.InterfaceType)) { '<none>' } else { $routerWanDiscovery.InterfaceType }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.LocalIPv4)) { '<none>' } else { $routerWanDiscovery.LocalIPv4 }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.Gateway)) { '<none>' } else { $routerWanDiscovery.Gateway }))

    Write-Verbose ('Router identity: gatewayMac={0}; gatewayVendor={1}; friendlyName={2}; manufacturerRaw={3}; manufacturerResolved={4}; model={5}; platform={6}; identityConfidence={7}; webHint={8}; dhcpServer={9}; dnsSuffix={10}' -f
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.GatewayMac)) { '<none>' } else { $routerWanDiscovery.GatewayMac }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.GatewayVendor)) { '<none>' } else { $routerWanDiscovery.GatewayVendor }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterFriendlyName)) { '<none>' } else { $routerWanDiscovery.RouterFriendlyName }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterManufacturerRaw)) { '<none>' } else { $routerWanDiscovery.RouterManufacturerRaw }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterManufacturerResolved)) { '<none>' } else { $routerWanDiscovery.RouterManufacturerResolved }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterModel)) { '<none>' } else { $routerWanDiscovery.RouterModel }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterPlatform)) { '<none>' } else { $routerWanDiscovery.RouterPlatform }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterIdentityConfidence)) { '<none>' } else { $routerWanDiscovery.RouterIdentityConfidence }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterWebHint)) { '<none>' } else { $routerWanDiscovery.RouterWebHint }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.DhcpServer)) { '<none>' } else { $routerWanDiscovery.DhcpServer }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.DnsSuffix)) { '<none>' } else { $routerWanDiscovery.DnsSuffix }))

    Write-Verbose ('Router WAN: gateway={0}; interface={1}; localIPv4={2}; wanIPv4={3}; source={4}; scope={5}; pcpSupported={6}' -f
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.Gateway)) { '<none>' } else { $routerWanDiscovery.Gateway }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.InterfaceAlias)) { '<none>' } else { $routerWanDiscovery.InterfaceAlias }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.LocalIPv4)) { '<none>' } else { $routerWanDiscovery.LocalIPv4 }),
        $(if ($null -eq $routerWanDiscovery -or [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.WanIPv4)) { '<none>' } else { $routerWanDiscovery.WanIPv4 }),
        $(if ($null -eq $routerWanDiscovery) { '<none>' } else { $routerWanDiscovery.WanSource }),
        $(if ($null -eq $routerWanDiscovery) { '<none>' } else { $routerWanDiscovery.WanScope }),
        $(if ($null -eq $routerWanDiscovery) { $false } else { $routerWanDiscovery.PcpSupported }))

    Write-Verbose ('Traceroute geolocation rows: {0}' -f @($routerVpnAssessment.TraceGeo).Count)

    Write-Verbose ('Router VPN assessment: suspected={0}; confidence={1}; traceHops={2}; evidence={3}' -f
        $routerVpnAssessment.Suspected,
        $routerVpnAssessment.Confidence,
        $(if (@($routerVpnAssessment.TraceHops).Count -gt 0) { @($routerVpnAssessment.TraceHops) -join ' > ' } else { '<none>' }),
        $routerVpnAssessment.Evidence)

    Write-Verbose ('Known Wi-Fi map configured: {0}' -f
        (-not [string]::IsNullOrWhiteSpace($WifiMapPath)))

    $routerWanGeoText = if ($null -ne $routerWanGeo) {
        $routerGeoParts = @(
            [string]$routerWanGeo.City,
            [string]$routerWanGeo.Region,
            [string]$routerWanGeo.Country
        ) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }

        @($routerGeoParts) -join ', '
    }
    elseif ($null -ne $routerWanDiscovery -and
            -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.WanIPv4)) {
        [string]$routerWanDiscovery.WanScope
    }
    else {
        $null
    }

    $result = [ordered]@{
        ComputerName                   = [Environment]::MachineName
        DeviceType                     = $deviceProfile.DeviceType
        TimestampUtc                   = [DateTime]::UtcNow
        Method                         = $selectedLocation.Method
        Confidence                     = Get-LocationConfidence -Location $selectedLocation
        Latitude                       = [double]$selectedLocation.Latitude
        Longitude                      = [double]$selectedLocation.Longitude
        AccuracyMeters                 = if ($null -ne $selectedLocation.AccuracyMeters) {
                                             $selectedLocation.AccuracyMeters
                                         }
                                         else {
                                             'NotReported'
                                         }
        Site                           = if (
                                             $selectedLocation.PSObject.Properties.Name -contains 'Site' -and
                                             -not [string]::IsNullOrWhiteSpace([string]$selectedLocation.Site)
                                         ) {
                                             [string]$selectedLocation.Site
                                         }
                                         else {
                                             'NotReported'
                                         }
        VpnResistant                   = if ($null -ne $selectedLocation.VpnResistant) {
                                             $selectedLocation.VpnResistant
                                         }
                                         else {
                                             'Unknown'
                                         }

        LocalCity                      = if ($null -ne $locality) { $locality.City } else { 'NotResolved' }
        LocalProvince                  = if ($null -ne $locality) { $locality.Region } else { 'NotResolved' }
        LocalCountry                   = if ($null -ne $locality) { $locality.Country } else { 'NotResolved' }
        LocalCityMatchType             = if ($null -ne $locality) { $locality.MatchType } else { 'NoLocalityMatch' }
        LocalCitySource                = if ($null -ne $locality) { $locality.Source } else { 'None' }
        LocalCityInsideRange           = if ($null -ne $locality) { $locality.InsideRange } else { $false }
        LocalCityCenterDistanceKm      = if ($null -ne $locality -and $null -ne $locality.CenterDistanceKm) {
                                             $locality.CenterDistanceKm
                                         }
                                         else {
                                             'NotApplicable'
                                         }
        LocalCityCenter                = if ($null -ne $locality -and $null -ne $locality.CenterLat -and $null -ne $locality.CenterLon) {
                                             '{0},{1}' -f
                                                ([double]$locality.CenterLat).ToString([Globalization.CultureInfo]::InvariantCulture),
                                                ([double]$locality.CenterLon).ToString([Globalization.CultureInfo]::InvariantCulture)
                                         }
                                         else {
                                             'NotApplicable'
                                         }
        LocalCityLatRange              = if ($null -ne $locality -and $null -ne $locality.MinLat -and $null -ne $locality.MaxLat) {
                                             '{0}..{1}' -f
                                                ([double]$locality.MinLat).ToString([Globalization.CultureInfo]::InvariantCulture),
                                                ([double]$locality.MaxLat).ToString([Globalization.CultureInfo]::InvariantCulture)
                                         }
                                         else {
                                             'NotApplicable'
                                         }
        LocalCityLongRange             = if ($null -ne $locality -and $null -ne $locality.MinLon -and $null -ne $locality.MaxLon) {
                                             '{0}..{1}' -f
                                                ([double]$locality.MinLon).ToString([Globalization.CultureInfo]::InvariantCulture),
                                                ([double]$locality.MaxLon).ToString([Globalization.CultureInfo]::InvariantCulture)
                                         }
                                         else {
                                             'NotApplicable'
                                         }

        StrongestGoogleUsableBssid     = if ($null -ne $strongestGoogleUsableAp) { $strongestGoogleUsableAp.BSSID } else { $null }
        StrongestGoogleUsableSsid      = if ($null -ne $strongestGoogleUsableAp) { $strongestGoogleUsableAp.SSID } else { $null }
        StrongestGoogleUsableSignalPct = if ($null -ne $strongestGoogleUsableAp) { $strongestGoogleUsableAp.SignalPercent } else { $null }
        StrongestGoogleUsableSignalDbm = if ($null -ne $strongestGoogleUsableAp) { $strongestGoogleUsableAp.SignalDbm } else { $null }
        StrongestGoogleUsableChannel   = if ($null -ne $strongestGoogleUsableAp) { $strongestGoogleUsableAp.Channel } else { $null }

        GoogleWifiResolverStatus       = $googleWifiResolverStatus
        WigleWifiResolverStatus        = $wigleWifiResolverStatus
        WigleCredentialSource          = $wigleCredentialSource
        WigleLiveQueriesUsed           = $script:WigleLiveQueriesUsed
        WigleLookupBudget              = $MaxWigleLookupsPerRun
        WigleCacheHits                 = $script:WigleCacheHits
        WigleCandidateCount            = $script:WigleCandidateCount
        WigleCacheCandidatesChecked    = $script:WigleCacheCandidatesChecked
        WigleLiveCandidatesEligible    = $script:WigleLiveCandidatesEligible
        WigleCurrentBssidPrioritized   = $script:WigleCurrentBssidPrioritized
        WigleCurrentBssid              = if ([string]::IsNullOrWhiteSpace([string]$script:WigleCurrentBssid)) { 'NotAvailable' } else { $script:WigleCurrentBssid }
        WigleCurrentBssidEligibility   = $script:WigleCurrentBssidEligibility
        WigleLastHttpStatus            = if ($null -ne $script:WigleLastHttpStatus) { $script:WigleLastHttpStatus } else { 'NotReported' }
        WigleLastErrorMessage          = if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorMessage)) { 'NotReported' } else { $script:WigleLastErrorMessage }
        WigleLastErrorBody             = if ([string]::IsNullOrWhiteSpace([string]$script:WigleLastErrorBody)) { 'NotReported' } else { $script:WigleLastErrorBody }
        WigleTerminalFailure           = $script:WigleTerminalFailure
        WigleTerminalFailureBasis      = if ([string]::IsNullOrWhiteSpace([string]$script:WigleTerminalFailureBasis)) { 'None' } else { $script:WigleTerminalFailureBasis }
        WigleRateLimitBasis            = if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitBasis)) { 'None' } else { $script:WigleRateLimitBasis }
        WigleRateLimitRemaining        = if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitRemaining)) { 'NotReported' } else { $script:WigleRateLimitRemaining }
        WigleRateLimitLimit            = if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitLimit)) { 'NotReported' } else { $script:WigleRateLimitLimit }
        WigleRateLimitReset            = if ([string]::IsNullOrWhiteSpace([string]$script:WigleRateLimitReset)) { 'NotReported' } else { $script:WigleRateLimitReset }
        WigleCandidateOrder            = if (@($script:WigleCandidateOrder).Count -gt 0) { $script:WigleCandidateOrder -join ' > ' } else { 'None' }

        BluetoothScanStatus            = $bluetoothScan.Status
        BluetoothScanEngine            = if (
                                             $bluetoothScan.PSObject.Properties.Name -contains 'Engine' -and
                                             -not [string]::IsNullOrWhiteSpace([string]$bluetoothScan.Engine)
                                         ) {
                                             [string]$bluetoothScan.Engine
                                         }
                                         elseif ($SkipBluetooth) {
                                             'NotApplicable'
                                         }
                                         else {
                                             'Unknown'
                                         }
        BluetoothScanDetail            = if (
                                             $bluetoothScan.PSObject.Properties.Name -contains 'Detail' -and
                                             -not [string]::IsNullOrWhiteSpace([string]$bluetoothScan.Detail)
                                         ) {
                                             [string]$bluetoothScan.Detail
                                         }
                                         elseif ($SkipBluetooth) {
                                             'Bluetooth scan skipped by parameter.'
                                         }
                                         else {
                                             'NotReported'
                                         }
        BluetoothDeviceCount           = $bluetoothDeviceCount
        BluetoothAnchorCount           = $bluetoothAnchorCount
        StrongestBluetoothName         = if ($null -ne $strongestBluetooth) { $strongestBluetooth.Name } else { $null }
        StrongestBluetoothAddress      = if ($null -ne $strongestBluetooth) { $strongestBluetooth.Address } else { $null }
        StrongestBluetoothRssi         = if ($null -ne $strongestBluetooth) { $strongestBluetooth.Rssi } else { $null }
        BluetoothLocationMatch         = if ($null -ne $bluetoothAnchorLocation) {
                                             $bluetoothAnchorLocation.AnchorName
                                         }
                                         elseif ([string]::IsNullOrWhiteSpace([string]$BluetoothMapPath)) {
                                             'NotConfigured'
                                         }
                                         else {
                                             'NoMatch'
                                         }
        BluetoothLocationDistanceKm    = if ($null -ne $bluetoothLocationDistanceKm) {
                                             $bluetoothLocationDistanceKm
                                         }
                                         else {
                                             'NotApplicable'
                                         }

        WifiScanStatus                 = $wifiScanStatusOutput

        CurrentWifiSsid                = if ($null -ne $currentAssociatedWifiAp) { $currentAssociatedWifiAp.SSID } else { $null }
        CurrentWifiBssid               = if ($null -ne $currentAssociatedWifiAp) { $currentAssociatedWifiAp.BSSID } else { $null }
        CurrentWifiSignalPct           = if ($null -ne $currentAssociatedWifiAp) { $currentAssociatedWifiAp.SignalPercent } else { $null }
        CurrentWifiChannel             = if ($null -ne $currentAssociatedWifiAp) { $currentAssociatedWifiAp.Channel } else { $null }

        ActiveInterface                = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.InterfaceAlias } else { $null }
        ActiveInterfaceType            = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.InterfaceType } else { 'Unknown' }
        LocalIPv4                      = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.LocalIPv4 } else { $null }
        DefaultGateway                 = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.Gateway } else { $null }
        GatewayMac                     = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.GatewayMac } else { $null }
        GatewayVendor                  = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.GatewayVendor } else { $null }
        DhcpServer                     = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.DhcpServer } else { $null }
        ConnectionDnsSuffix            = if (
                                             $null -ne $routerWanDiscovery -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.DnsSuffix)
                                         ) {
                                             [string]$routerWanDiscovery.DnsSuffix
                                         }
                                         else {
                                             'NotReported'
                                         }

        PublicIp                       = if ($null -ne $publicIpLocation) { $publicIpLocation.IP } else { $null }
        PublicIpCity                   = if ($null -ne $publicIpLocation) { $publicIpLocation.City } else { $null }
        PublicIpRegion                 = if ($null -ne $publicIpLocation) { $publicIpLocation.Region } else { $null }
        PublicIpCountry                = if ($null -ne $publicIpLocation) { $publicIpLocation.Country } else { $null }
        PublicIpIsp                    = if ($null -ne $publicIpLocation) { $publicIpLocation.ISP } else { $null }

        RouterFriendlyName             = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterFriendlyName } else { $null }
        RouterManufacturer             = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterManufacturer } else { $null }
        RouterManufacturerRaw          = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterManufacturerRaw } else { $null }
        RouterManufacturerResolved     = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterManufacturerResolved } else { $null }
        RouterPlatform                 = if (
                                             $null -ne $routerWanDiscovery -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterPlatform)
                                         ) {
                                             $routerWanDiscovery.RouterPlatform
                                         }
                                         else {
                                             'Unknown'
                                         }
        RouterIdentityConfidence       = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterIdentityConfidence } else { $null }
        RouterIdentityBasis            = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterIdentityBasis } else { $null }
        RouterModel                    = if ($null -ne $routerWanDiscovery) { $routerWanDiscovery.RouterModel } else { $null }
        RouterWebHint                  = if (
                                             $null -ne $routerWanDiscovery -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterWebHint)
                                         ) {
                                             $routerWanDiscovery.RouterWebHint
                                         }
                                         else {
                                             'NotObserved'
                                         }
        RouterTlsSubject               = if (
                                             $null -ne $routerWanDiscovery -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.RouterTlsSubject)
                                         ) {
                                             $routerWanDiscovery.RouterTlsSubject
                                         }
                                         else {
                                             'NotObserved'
                                         }
        RouterWanIp                    = if (
                                             $null -ne $routerWanDiscovery -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanDiscovery.WanIPv4)
                                         ) {
                                             [string]$routerWanDiscovery.WanIPv4
                                         }
                                         else {
                                             'NotExposed'
                                         }
        RouterWanIsp                   = if (
                                             $null -ne $routerWanGeo -and
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanGeo.ISP)
                                         ) {
                                             [string]$routerWanGeo.ISP
                                         }
                                         else {
                                             'NotAvailable'
                                         }
        RouterWanGeo                   = if (
                                             -not [string]::IsNullOrWhiteSpace([string]$routerWanGeoText)
                                         ) {
                                             $routerWanGeoText
                                         }
                                         else {
                                             'NotAvailable'
                                         }
        RouterVpnSuspected             = $routerVpnAssessment.Suspected
        RouterVpnConfidence            = $routerVpnAssessment.Confidence
        RouterVpnEvidence              = $routerVpnAssessment.Evidence
        TraceGeo                       = $traceGeoFlat

        PhysicalVsPublicIpDistanceKm   = $distanceKm
        VpnAdapterDetected             = $vpnAdapterDetectedOutput
        EstablishedVpnTunnel           = $establishedVpnTunnelOutput

        Detail                         = $selectedLocation.Detail

        # MapUri remains backward compatible, but it now explicitly means the
        # currently selected/final location only.
        MapUri                         = $selectedMapUri
        SelectedMapUri                 = $selectedMapUri
        GpsMapUri                      = if ([string]::IsNullOrWhiteSpace([string]$gpsMapUri)) { 'NotAvailable' } else { $gpsMapUri }
        KnownWifiMapUri                = if ([string]::IsNullOrWhiteSpace([string]$knownWifiMapUri)) { 'NotAvailable' } else { $knownWifiMapUri }
        BluetoothAnchorMapUri          = if ([string]::IsNullOrWhiteSpace([string]$bluetoothAnchorMapUri)) { 'NotAvailable' } else { $bluetoothAnchorMapUri }
        GoogleWifiMapUri               = if ([string]::IsNullOrWhiteSpace([string]$googleWifiMapUri)) { 'NotAvailable' } else { $googleWifiMapUri }
        WigleMapUri                    = if ([string]::IsNullOrWhiteSpace([string]$wigleMapUri)) { 'NotAvailable' } else { $wigleMapUri }
        NativeLocationMapUri           = if ([string]::IsNullOrWhiteSpace([string]$nativeLocationMapUri)) { 'NotAvailable' } else { $nativeLocationMapUri }
        OgLocationMapUri               = if ([string]::IsNullOrWhiteSpace([string]$ogLocationMapUri)) { 'NotAvailable' } else { $ogLocationMapUri }
        PublicIpMapUri                 = if ([string]::IsNullOrWhiteSpace([string]$publicIpMapUri)) { 'NotAvailable' } else { $publicIpMapUri }
        RouterWanMapUri                = if ([string]::IsNullOrWhiteSpace([string]$routerWanMapUri)) { 'NotAvailable' } else { $routerWanMapUri }

        og_devcoordscript_says         = if ([string]::IsNullOrWhiteSpace([string]$ogDevcoordscriptSays)) { 'NotAvailable' } else { $ogDevcoordscriptSays }
        OG_and_NewG_gap                = if ([string]::IsNullOrWhiteSpace([string]$ogAndNewgGap)) { 'NotAvailable' } else { $ogAndNewgGap }
        Notes                          = $notesFlat

    }

    # Remove optional resolver sections that were not actually configured/run.
    #
    # StrongestGoogleUsable* is also hidden with the Google section. The raw Wi-Fi
    # observations remain available in WifiEvidence regardless of resolver setup.
    if (-not $googleResolverOutputEnabled) {
        foreach ($propertyName in @(
            'StrongestGoogleUsableBssid',
            'StrongestGoogleUsableSsid',
            'StrongestGoogleUsableSignalPct',
            'StrongestGoogleUsableSignalDbm',
            'StrongestGoogleUsableChannel',
            'GoogleWifiResolverStatus',
            'GoogleWifiMapUri'
        )) {
            [void]$result.Remove($propertyName)
        }
    }

    if (-not $wigleResolverOutputEnabled) {
        foreach ($propertyName in @(
            'WigleWifiResolverStatus',
            'WigleCredentialSource',
            'WigleLiveQueriesUsed',
            'WigleLookupBudget',
            'WigleCacheHits',
            'WigleCandidateCount',
            'WigleCacheCandidatesChecked',
            'WigleLiveCandidatesEligible',
            'WigleCurrentBssidPrioritized',
            'WigleCurrentBssid',
            'WigleCurrentBssidEligibility',
            'WigleLastHttpStatus',
            'WigleLastErrorMessage',
            'WigleLastErrorBody',
            'WigleTerminalFailure',
            'WigleTerminalFailureBasis',
            'WigleRateLimitBasis',
            'WigleRateLimitRemaining',
            'WigleRateLimitLimit',
            'WigleRateLimitReset',
            'WigleCandidateOrder',
            'WigleMapUri'
        )) {
            [void]$result.Remove($propertyName)
        }
    }

    if (-not $bluetoothOutputEnabled) {
        foreach ($propertyName in @(
            'BluetoothScanStatus',
            'BluetoothScanEngine',
            'BluetoothScanDetail',
            'BluetoothDeviceCount',
            'BluetoothAnchorCount',
            'StrongestBluetoothName',
            'StrongestBluetoothAddress',
            'StrongestBluetoothRssi',
            'BluetoothLocationMatch',
            'BluetoothLocationDistanceKm',
            'BluetoothAnchorMapUri'
        )) {
            [void]$result.Remove($propertyName)
        }
    }

    # Keep the normal result compact. GPS/GNSS properties are only emitted when the
    # hardware detector found a matching present device on this endpoint.
    if ($gpsHardwareDetected) {
        $result.GpsHardwareDetected = $true
        $result.GpsHardware = if (@($gpsHardware).Count -gt 0) {
            (@(
                $gpsHardware |
                    ForEach-Object {
                        '{0} [{1}]' -f $_.Name, $_.Class
                    }
            ) | Out-String -Width 4096).Trim()
        }
        else {
            $null
        }

        $result.GpsFixStatus       = $gpsProbe.Status
        $result.GpsPositionSource  = $gpsProbe.PositionSource
        $result.GpsLatitude        = $gpsProbe.Latitude
        $result.GpsLongitude       = $gpsProbe.Longitude
        $result.GpsAccuracyMeters  = $gpsProbe.AccuracyMeters
        $result.GpsAltitudeMeters  = $gpsProbe.AltitudeMeters
        $result.GpsHorizontalDop   = $gpsProbe.HorizontalDop
        $result.GpsPositionDop     = $gpsProbe.PositionDop
    }

    if ($bluetoothOutputEnabled) {
        $result.BluetoothEvidence = $bluetoothEvidenceFlat
    }

    # Always present and always the final property, even when optional resolver,
    # Bluetooth, and GPS/GNSS sections are omitted.
    $result.WifiEvidence = $wifiEvidenceFlat

    [pscustomobject]$result
}
finally {
    if ($platform -eq 'Windows' -and @($consentSnapshot).Count -gt 0) {
        Restore-WindowsLocationConsent -Snapshot $consentSnapshot
    }
}
