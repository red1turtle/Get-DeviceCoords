# Get-DeviceCoords

Endpoint geolocation scripts. The current PowerShell script and Bash companion combine multiple signals and treat public-IP coordinates as Internet egress context.

## Scripts

| Script | Platforms | Purpose |
| --- | --- | --- |
| `Get-DeviceCoords-v3.65.1.ps1` | Windows, Linux, macOS | Current PowerShell workflow with multiple location resolvers and network evidence. PowerShell 7 is recommended; Windows PowerShell 5.1 compatibility is retained. |
| `get-device-coords-v2.6.sh` | Linux, macOS | Standalone Bash 3.2+ companion aligned with the v3.62 feature contract. It does not require PowerShell, Python, or jq. |
| `Get-DeviceCoords-v1.0.ps1` | Windows only | Legacy Windows registry and `GeoCoordinateWatcher` workflow. Requires Windows PowerShell 5.1 with the .NET Framework `System.Device` assembly. |

## Quick start

From the repository directory, run the current PowerShell script:

```powershell
./Get-DeviceCoords-v3.65.1.ps1 | Format-List *
```

Or use the Bash companion on Linux/macOS:

```bash
bash ./get-device-coords-v2.6.sh
bash ./get-device-coords-v2.6.sh --help
```

The Bash script prints named fields; the current PowerShell script returns an object. Both fail explicitly if no resolver can obtain a location. On a cloud host without location hardware, public-IP fallback needs HTTPS access to `api.ipify.org` and `ipwho.is`. Its coordinates describe Internet egress and may represent a proxy or VPN endpoint.

## Signals

The current PowerShell script and Bash companion can use, when available:

- Windows satellite/GNSS and native OS location
- Known Wi-Fi BSSID mappings
- Google Geolocation API using nearby Wi-Fi BSSIDs
- WiGLE exact-BSSID lookups with caching/rate-limit handling
- Bluetooth LE proximity evidence when requested and supported by the platform collector
- Router/gateway and route-path evidence
- Public-IP geolocation as a fallback only

Collectors depend on the operating system, available tools, permissions, and hardware. Linux Wi-Fi collection uses NetworkManager `nmcli` or, for the Bash companion, an `iw` fallback; Linux BLE uses BlueZ `bluetoothctl`. Native Linux location uses a GeoClue helper when available. Installing these tools alone does not provide location hardware or a running desktop service.

## Optional API credentials

Google Wi-Fi geolocation:

```powershell
$env:GOOGLE_GEO_API_KEY = '<key>'
./Get-DeviceCoords-v3.65.1.ps1
```

WiGLE:

```powershell
$env:WIGLE_API_NAME  = '<api-name>'
$env:WIGLE_API_TOKEN = '<api-token>'
./Get-DeviceCoords-v3.65.1.ps1
```

Bluetooth LE scan:

```powershell
./Get-DeviceCoords-v3.65.1.ps1 -BluetoothScanSeconds 10
```

The current PowerShell script caps normal output at 20 Wi-Fi evidence rows and 15 Bluetooth evidence rows. Use `-FullEvidence` to show all rows, or `-Verbose` for diagnostics; resolvers still use the complete collected evidence set.

Bash Bluetooth scan:

```bash
bash ./get-device-coords-v2.6.sh --bluetooth-scan-seconds 10
```

Both current workflows read `GOOGLE_GEO_API_KEY`, `WIGLE_API_NAME`, and `WIGLE_API_TOKEN` when set. Google and WiGLE are optional; missing keys disable those resolvers. They require access to `www.googleapis.com` and `api.wigle.net`, respectively.

Optional Wi-Fi site map CSV format:

```text
BSSID,Latitude,Longitude,Site,AccuracyMeters
```

Use `-WifiMapPath ./sites.csv` with PowerShell or `--wifi-map ./sites.csv` with Bash.

## Legacy v1.0

Run the replacement v1.0 script from **Windows PowerShell 5.1 on Windows**:

```powershell
.\Get-DeviceCoords-v1.0.ps1
```

It attempts to enable system location consent when running as administrator and enables location consent for matching user registry hives. It does not restore the previous consent values. It then uses `System.Device.Location.GeoCoordinateWatcher`, waits for a fix, and prints latitude, longitude, and a map URL when successful.

This script has no public-IP fallback or Google/WiGLE resolver. It cannot run on Linux/macOS or with the Linux PowerShell 7 runtime. Parsing it on Linux does not validate its Windows registry or location-service behavior.

## Privacy / API behavior

- The current PowerShell script and Bash companion treat public IP as egress context, not authoritative physical location.
- BLE collection is opt-in, with no pairing, connection, or GATT interrogation. On Linux, an already-discoverable controller may issue active scan requests.
- WiGLE is query-only; the scripts do not upload observations.
- The legacy v1.0 consent behavior is described above.

## Validation

There is no checked-in automated test suite. Check Bash syntax with:

```bash
bash -n ./get-device-coords-v2.6.sh
```

Parse both PowerShell scripts without executing their location or registry logic:

```powershell
foreach ($file in Get-ChildItem *.ps1) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    "Parsed $($file.Name)"
}
```

Use the quick-start commands for live validation. `-SkipPublicIpLookup -SkipBluetooth` (PowerShell) or `--skip-public-ip --skip-bluetooth` (Bash) disables those sources; failure is expected if the host has no remaining location source. Live hardware checks require the corresponding OS, devices, services, and permissions. Test v1.0 on Windows separately, and inspect its errors and coordinate output: the legacy script can exit with status 0 despite runtime errors.

## Repository contents

```text
Get-DeviceCoords-v3.65.1.ps1
Get-DeviceCoords-v1.0.ps1
get-device-coords-v2.6.sh
README.md
LICENSE
```

## License

Beerware-style. See [LICENSE](LICENSE).
