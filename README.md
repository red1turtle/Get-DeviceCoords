# Get-DeviceCoords v3.62

PowerShell endpoint geolocation that combines multiple signals instead of treating a public IP as physical truth.

## Quick start

```powershell
./Get-DeviceCoords.ps1 | Format-List *
```

PowerShell 7 is recommended. Windows PowerShell 5.1 compatibility is retained.

## Signals

The script can use, when available:

- Windows satellite/GNSS and native OS location
- Known Wi-Fi BSSID mappings
- Google Geolocation API using nearby Wi-Fi BSSIDs
- WiGLE exact-BSSID lookups with caching/rate-limit handling
- Passive Bluetooth LE proximity evidence on Windows
- Router/gateway and route-path evidence
- Public-IP geolocation as a fallback only

Windows, Linux, and macOS are supported, with platform-specific Wi-Fi/location collection.

## Optional API credentials

Google Wi-Fi geolocation:

```powershell
$env:GOOGLE_GEO_API_KEY = '<key>'
./Get-DeviceCoords.ps1
```

WiGLE:

```powershell
$env:WIGLE_API_NAME  = '<api-name>'
$env:WIGLE_API_TOKEN = '<api-token>'
./Get-DeviceCoords.ps1
```

Bluetooth LE scan:

```powershell
./Get-DeviceCoords.ps1 -BluetoothScanSeconds 10
```

Optional Wi-Fi site map CSV format:

```text
BSSID,Latitude,Longitude,Site,AccuracyMeters
```

## Privacy / API behavior

- Public IP is treated as egress context, not authoritative physical location.
- BLE collection is passive: no pairing, connection, or GATT interrogation.
- WiGLE is query-only; the script does not upload observations.
- Missing API keys simply disable the associated resolver.

## Repository contents

```text
Get-DeviceCoords.ps1
README.md
LICENSE
```

That is intentionally the whole package.

## License

Beerware-style. See [LICENSE](LICENSE).
