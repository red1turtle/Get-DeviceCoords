#!/usr/bin/env bash
#
# get-device-coords-v2.0.sh
#
# Standalone macOS/Linux companion aligned to the Windows
# Get-DeviceCoords-v3.62.ps1 production feature contract.
#
# Applicable resolver order on macOS/Linux:
#   1. Known Wi-Fi BSSID map (optional)
#   2. Google Geolocation API from nearby usable BSSIDs (optional)
#   3. WiGLE exact-BSSID fallback with rate-aware persistent cache (optional)
#   4. Native OS location provider
#        macOS: CoreWLAN for Wi-Fi + Core Location for position
#        Linux: NetworkManager nmcli (preferred), iw fallback, GeoClue helper
#   5. Public-IP geolocation fallback
#
# Additional evidence includes device profile, current Wi-Fi association,
# physical default route/gateway identity, OUI enrichment, UPnP/NAT-PMP/PCP
# router discovery when available, route/ASN evidence, router-VPN inference,
# locality classification, separate detected/established VPN evidence, and
# source-specific map provenance.
#
# No PowerShell, Python, jq, Homebrew, or package installation is required
# by the script itself. Optional OS tooling is detected at runtime.
#
# Bash 3.2+ compatible for the Bash shipped with macOS.
#

set -o pipefail
umask 077

SCRIPT_VERSION="2.0"
WINDOWS_REFERENCE_VERSION="3.62"
VERBOSE=1
TIMEOUT_SECONDS=8
GOOGLE_API_KEY="${GOOGLE_GEO_API_KEY:-}"
GOOGLE_API_KEY_SOURCE="None"
WIFI_MAP_PATH="${DEVICE_COORDS_WIFI_MAP:-}"
WIGLE_API_NAME="${WIGLE_API_NAME:-}"
WIGLE_API_TOKEN="${WIGLE_API_TOKEN:-}"
WIGLE_CREDENTIAL_SOURCE="None"
MAX_WIGLE_LOOKUPS=8
BLUETOOTH_MAP_PATH=""
BLUETOOTH_SCAN_SECONDS=""
BLUETOOTH_EXPLICIT=0
SKIP_BLUETOOTH=0
SKIP_PUBLIC_IP=0

if [ -n "${GOOGLE_API_KEY}" ]; then
    GOOGLE_API_KEY_SOURCE="Environment"
fi

if [ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ]; then
    WIGLE_CREDENTIAL_SOURCE="Environment"
fi

usage() {
    cat <<'EOF'
Usage:
  get-device-coords-v2.0.sh [options]

Options:
  --google-api-key KEY      Optional Google Geolocation API key.
                            If omitted, GOOGLE_GEO_API_KEY is used when set.
  --wigle-api-name NAME     Optional WiGLE API name.
                            If omitted, WIGLE_API_NAME is used when set.
  --wigle-api-token TOKEN   Optional WiGLE API token.
                            If omitted, WIGLE_API_TOKEN is used when set.
  --max-wigle-lookups N     Maximum live WiGLE lookups per run. Default: 8.
                            Valid range: 1-20.
  --wifi-map PATH           Optional CSV:
                            BSSID,Latitude,Longitude,Site,AccuracyMeters
  --bluetooth-map PATH      Accepted for v3.62 contract compatibility.
                            BLE scanning remains Windows-only in v3.62.
  --bluetooth-scan-seconds N
                            Explicit BLE request (1-30). On macOS/Linux the
                            result is reported as UnsupportedPlatform.
  --skip-bluetooth          Explicitly disable BLE evidence.
  --timeout SECONDS         Native-location timeout. Default: 8.
  --skip-public-ip          Do not perform public-IP geolocation.
  --skip-public-ip-lookup   Alias for --skip-public-ip.
  --quiet                   Suppress default verbose diagnostics.
  --verbose                 Enable verbose diagnostics (default).
  --help                    Show this help.

Examples:
  ./get-device-coords-v2.0.sh

  GOOGLE_GEO_API_KEY='...' ./get-device-coords-v2.0.sh

  WIGLE_API_NAME='...' WIGLE_API_TOKEN='...' ./get-device-coords-v2.0.sh

  ./get-device-coords-v2.0.sh --wifi-map ./Corporate-WifiLocations.csv

Notes:
  * Google is never contacted unless a key is configured.
  * Google Wi-Fi requests use considerIp=false.
  * WiGLE is never contacted unless both WiGLE credentials are configured.
  * WiGLE live lookup budget defaults to 8 and is bounded to 1-20.
  * BLE scan parity follows Get-DeviceCoords-v3.62.ps1: Windows-only.
  * WifiEvidence is always the final output property.
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --google-api-key)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --google-api-key requires a value." >&2
                exit 2
            fi
            GOOGLE_API_KEY="$1"
            GOOGLE_API_KEY_SOURCE="Argument"
            ;;
        --wigle-api-name)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --wigle-api-name requires a value." >&2
                exit 2
            fi
            WIGLE_API_NAME="$1"
            WIGLE_CREDENTIAL_SOURCE="Argument"
            ;;
        --wigle-api-token)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --wigle-api-token requires a value." >&2
                exit 2
            fi
            WIGLE_API_TOKEN="$1"
            WIGLE_CREDENTIAL_SOURCE="Argument"
            ;;
        --max-wigle-lookups)
            shift
            if [ "$#" -eq 0 ] || ! printf '%s' "$1" | grep -Eq '^[0-9]+$' ||
               [ "$1" -lt 1 ] || [ "$1" -gt 20 ]; then
                echo "ERROR: --max-wigle-lookups requires an integer from 1 through 20." >&2
                exit 2
            fi
            MAX_WIGLE_LOOKUPS="$1"
            ;;
        --wifi-map)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --wifi-map requires a path." >&2
                exit 2
            fi
            WIFI_MAP_PATH="$1"
            ;;
        --bluetooth-map)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --bluetooth-map requires a path." >&2
                exit 2
            fi
            BLUETOOTH_MAP_PATH="$1"
            BLUETOOTH_EXPLICIT=1
            ;;
        --bluetooth-scan-seconds)
            shift
            if [ "$#" -eq 0 ] || ! printf '%s' "$1" | grep -Eq '^[0-9]+$' ||
               [ "$1" -lt 1 ] || [ "$1" -gt 30 ]; then
                echo "ERROR: --bluetooth-scan-seconds requires an integer from 1 through 30." >&2
                exit 2
            fi
            BLUETOOTH_SCAN_SECONDS="$1"
            BLUETOOTH_EXPLICIT=1
            ;;
        --skip-bluetooth)
            SKIP_BLUETOOTH=1
            BLUETOOTH_EXPLICIT=1
            ;;
        --timeout)
            shift
            if [ "$#" -eq 0 ] || ! printf '%s' "$1" | grep -Eq '^[0-9]+$'; then
                echo "ERROR: --timeout requires an integer number of seconds." >&2
                exit 2
            fi
            TIMEOUT_SECONDS="$1"
            ;;
        --skip-public-ip|--skip-public-ip-lookup)
            SKIP_PUBLIC_IP=1
            ;;
        --quiet)
            VERBOSE=0
            ;;
        --verbose)
            VERBOSE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument [$1]." >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ] &&
   [ "$WIGLE_CREDENTIAL_SOURCE" = "None" ]; then
    WIGLE_CREDENTIAL_SOURCE="Environment"
fi

if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
    echo "ERROR: Bash 3.2 or newer is required." >&2
    exit 2
fi

OS_NAME="$(uname -s 2>/dev/null || printf 'Unknown')"
case "$OS_NAME" in
    Darwin) PLATFORM="macOS" ;;
    Linux)  PLATFORM="Linux" ;;
    *)
        echo "ERROR: Unsupported platform [$OS_NAME]. This script supports macOS and Linux." >&2
        exit 2
        ;;
esac

TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_ROOT%/}/get-device-coords.XXXXXX")" || exit 1
WIFI_RAW_FILE="$WORK_DIR/wifi-raw.tsv"
WIFI_FILE="$WORK_DIR/wifi.tsv"
NOTES_FILE="$WORK_DIR/notes.txt"
VPN_FILE="$WORK_DIR/vpn.txt"
: > "$WIFI_RAW_FILE"
: > "$WIFI_FILE"
: > "$NOTES_FILE"
: > "$VPN_FILE"

cleanup() {
    rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf 'VERBOSE: %s\n' "$*" >&2
    fi
}

add_note() {
    printf '%s\n' "$*" >> "$NOTES_FILE"
}

sanitize_field() {
    printf '%s' "$1" | tr '\011\015\012|' '    '
}

normalize_bssid() {
    printf '%s' "$1" |
        tr '[:lower:]' '[:upper:]' |
        tr '-' ':' |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

GOOGLE_ELIGIBILITY_REASON=""

is_google_usable_bssid() {
    local bssid first_hex first_octet

    bssid="$(normalize_bssid "$1")"
    GOOGLE_ELIGIBILITY_REASON="InvalidFormat"

    if ! printf '%s\n' "$bssid" |
        grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'; then
        return 1
    fi

    if [ "$bssid" = "FF:FF:FF:FF:FF:FF" ]; then
        GOOGLE_ELIGIBILITY_REASON="Broadcast"
        return 1
    fi

    case "$bssid" in
        00:00:5E:*)
            GOOGLE_ELIGIBILITY_REASON="ReservedIanaRange"
            return 1
            ;;
    esac

    first_hex="${bssid%%:*}"
    first_octet="$(printf '%d' "0x$first_hex" 2>/dev/null || printf '0')"

    if [ $((first_octet & 1)) -ne 0 ]; then
        GOOGLE_ELIGIBILITY_REASON="MulticastOrGroup"
        return 1
    fi

    if [ $((first_octet & 2)) -ne 0 ]; then
        GOOGLE_ELIGIBILITY_REASON="LocallyAdministered"
        return 1
    fi

    GOOGLE_ELIGIBILITY_REASON="UniversallyAdministered"
    return 0
}

append_wifi_record() {
    local bssid ssid signal_pct signal_dbm channel source usable reason

    bssid="$(normalize_bssid "$1")"
    ssid="$(sanitize_field "${2:-}")"
    signal_pct="$(sanitize_field "${3:-}")"
    signal_dbm="$(sanitize_field "${4:-}")"
    channel="$(sanitize_field "${5:-}")"
    source="$(sanitize_field "${6:-Unknown}")"

    if ! printf '%s\n' "$bssid" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'; then
        return
    fi

    if is_google_usable_bssid "$bssid"; then
        usable="true"
    else
        usable="false"
    fi
    reason="$GOOGLE_ELIGIBILITY_REASON"

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$bssid" "$ssid" "$signal_pct" "$signal_dbm" "$channel" \
        "$source" "$usable" "$reason" >> "$WIFI_RAW_FILE"
}

dedupe_wifi_records() {
    if [ ! -s "$WIFI_RAW_FILE" ]; then
        : > "$WIFI_FILE"
        return
    fi

    awk -F '|' '
        BEGIN { OFS="|" }
        {
            key=toupper($1)
            if ($4 != "") {
                score=1000 + ($4 + 0)
            } else if ($3 != "") {
                score=$3 + 0
            } else {
                score=-10000
            }

            if (!(key in bestScore) || score > bestScore[key]) {
                bestScore[key]=score
                bestLine[key]=$0
            }
        }
        END {
            for (key in bestLine) {
                print bestScore[key] "\t" bestLine[key]
            }
        }
    ' "$WIFI_RAW_FILE" |
        sort -t "$(printf '\t')" -k1,1nr |
        cut -f2- > "$WIFI_FILE"
}

freq_to_channel() {
    local freq="$1"

    if ! printf '%s\n' "$freq" | grep -Eq '^[0-9]+$'; then
        printf ''
        return
    fi

    if [ "$freq" -eq 2484 ]; then
        printf '14'
    elif [ "$freq" -ge 2412 ] && [ "$freq" -le 2472 ]; then
        printf '%s' $(((freq - 2407) / 5))
    elif [ "$freq" -ge 5000 ] && [ "$freq" -lt 5950 ]; then
        printf '%s' $(((freq - 5000) / 5))
    elif [ "$freq" -ge 5955 ] && [ "$freq" -le 7115 ]; then
        printf '%s' $(((freq - 5950) / 5))
    else
        printf ''
    fi
}

collect_linux_wifi_nmcli() {
    local out line bssid rest signal channel ssid

    command -v nmcli >/dev/null 2>&1 || return 1

    out="$WORK_DIR/nmcli.txt"
    verbose "Linux Wi-Fi collector: NetworkManager nmcli; forcing rescan=yes."

    if ! LC_ALL=C LANG=C nmcli -t --escape no \
        -f BSSID,SIGNAL,CHAN,SSID \
        device wifi list --rescan yes >"$out" 2>"$WORK_DIR/nmcli.err"; then

        verbose "nmcli Wi-Fi scan failed: $(tr '\n' ' ' < "$WORK_DIR/nmcli.err")"
        return 1
    fi

    while IFS= read -r line; do
        [ "${#line}" -ge 19 ] || continue

        bssid="${line:0:17}"
        if ! printf '%s\n' "$bssid" | grep -Eqi '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
            continue
        fi

        rest="${line:18}"
        signal="${rest%%:*}"
        rest="${rest#*:}"
        channel="${rest%%:*}"
        ssid="${rest#*:}"

        append_wifi_record "$bssid" "$ssid" "$signal" "" "$channel" "LinuxNetworkManager"
    done < "$out"

    return 0
}

collect_linux_wifi_iw() {
    local iface raw parsed bssid ssid dbm freq channel found
    found=0

    command -v iw >/dev/null 2>&1 || return 1

    while IFS= read -r iface; do
        [ -n "$iface" ] || continue

        raw="$WORK_DIR/iw-${iface}.txt"
        parsed="$WORK_DIR/iw-${iface}.tsv"

        verbose "Linux Wi-Fi fallback collector: iw dev $iface scan."

        if ! LC_ALL=C LANG=C iw dev "$iface" scan >"$raw" 2>"$WORK_DIR/iw-${iface}.err"; then
            verbose "iw scan failed on [$iface]: $(tr '\n' ' ' < "$WORK_DIR/iw-${iface}.err")"
            continue
        fi

        awk '
            function trim(v) {
                sub(/^[ \t]+/, "", v)
                sub(/[ \t]+$/, "", v)
                return v
            }
            function emit() {
                if (bssid != "") {
                    gsub(/\t|\r|\n/, " ", ssid)
                    printf "%s\t%s\t%s\t%s\n", bssid, ssid, signal, freq
                }
            }
            /^BSS[ \t]+/ {
                emit()
                bssid=$2
                sub(/\(.*/, "", bssid)
                ssid=""
                signal=""
                freq=""
                next
            }
            /^[ \t]+signal:/ {
                signal=$2
                next
            }
            /^[ \t]+freq:/ {
                freq=$2
                next
            }
            /^[ \t]+SSID:/ {
                value=$0
                sub(/^[ \t]+SSID:[ \t]*/, "", value)
                ssid=trim(value)
                next
            }
            END { emit() }
        ' "$raw" > "$parsed"

        while IFS="$(printf '\t')" read -r bssid ssid dbm freq; do
            [ -n "$bssid" ] || continue
            channel="$(freq_to_channel "$freq")"
            append_wifi_record "$bssid" "$ssid" "" "$dbm" "$channel" "LinuxIw"
            found=1
        done < "$parsed"
    done <<EOF
$(iw dev 2>/dev/null | awk '/^[ \t]*Interface[ \t]+/ {print $2}')
EOF

    [ "$found" -eq 1 ]
}

collect_linux_wifi() {
    if collect_linux_wifi_nmcli; then
        WIFI_COLLECTOR="LinuxNetworkManager"
    elif collect_linux_wifi_iw; then
        WIFI_COLLECTOR="LinuxIw"
    else
        WIFI_COLLECTOR="Unavailable"
        add_note "No usable Linux Wi-Fi scanner was available. NetworkManager nmcli is preferred; iw is supported as a fallback."
    fi
}

collect_macos_wifi_corewlan() {
    local js out err line bssid ssid dbm channel

    command -v osascript >/dev/null 2>&1 || return 1

    js="$WORK_DIR/corewlan.js"
    out="$WORK_DIR/corewlan.tsv"
    err="$WORK_DIR/corewlan.err"

    cat > "$js" <<'JXA'
ObjC.import('CoreWLAN');

function unwrapString(value) {
    try {
        if (!value) return "";
        var s = ObjC.unwrap(value);
        if (s === undefined || s === null) return "";
        return String(s);
    } catch (e) {
        return "";
    }
}

function clean(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\t\r\n]/g, " ");
}

var client = $.CWWiFiClient.sharedWiFiClient;
var iface = client.interface;
var lines = [];

if (iface) {
    var err = Ref();
    var set = iface.scanForNetworksWithNameError(null, err);

    if (set) {
        var array = set.allObjects;
        var count = Number(array.count);

        for (var i = 0; i < count; i++) {
            var network = array.objectAtIndex(i);
            var channel = network.wlanChannel;

            var bssid = unwrapString(network.bssid);
            if (!bssid || bssid === "<redacted>") {
                continue;
            }

            lines.push([
                clean(bssid),
                clean(unwrapString(network.ssid)),
                clean(Number(network.rssiValue)),
                clean(channel ? Number(channel.channelNumber) : "")
            ].join("\t"));
        }
    }
}

lines.join("\n");
JXA

    verbose "macOS Wi-Fi collector: CoreWLAN broadcast scan."

    if ! osascript -l JavaScript "$js" >"$out" 2>"$err"; then
        verbose "CoreWLAN scan failed: $(tr '\n' ' ' < "$err")"
        return 1
    fi

    while IFS="$(printf '\t')" read -r bssid ssid dbm channel; do
        [ -n "$bssid" ] || continue
        append_wifi_record "$bssid" "$ssid" "" "$dbm" "$channel" "MacCoreWLAN"
    done < "$out"

    [ -s "$WIFI_RAW_FILE" ]
}

collect_macos_wifi_airport() {
    local airport out line bssid ssid remainder dbm channel

    airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    [ -x "$airport" ] || return 1

    out="$WORK_DIR/airport.txt"
    verbose "macOS Wi-Fi fallback collector: legacy airport utility."

    if ! "$airport" -s >"$out" 2>"$WORK_DIR/airport.err"; then
        return 1
    fi

    while IFS= read -r line; do
        bssid="$(printf '%s\n' "$line" |
            grep -Eo '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' |
            head -n 1)"
        [ -n "$bssid" ] || continue

        ssid="${line%%$bssid*}"
        ssid="$(printf '%s' "$ssid" | sed 's/[[:space:]]*$//')"
        remainder="${line#*$bssid}"
        dbm="$(printf '%s\n' "$remainder" | awk '{print $1}')"
        channel="$(printf '%s\n' "$remainder" | awk '{print $2}' | sed 's/[^0-9].*$//')"

        append_wifi_record "$bssid" "$ssid" "" "$dbm" "$channel" "MacAirportLegacy"
    done < "$out"

    [ -s "$WIFI_RAW_FILE" ]
}

collect_macos_wifi() {
    if collect_macos_wifi_corewlan; then
        WIFI_COLLECTOR="MacCoreWLAN"
    elif collect_macos_wifi_airport; then
        WIFI_COLLECTOR="MacAirportLegacy"
    else
        WIFI_COLLECTOR="Unavailable"
        add_note "macOS Wi-Fi BSSID enumeration was unavailable. Location Services permission can affect access to Wi-Fi identifiers."
    fi
}

collect_wifi() {
    if [ "$PLATFORM" = "Linux" ]; then
        collect_linux_wifi
    else
        collect_macos_wifi
    fi

    dedupe_wifi_records
}

wifi_count() {
    awk 'END {print NR+0}' "$WIFI_FILE"
}

google_usable_count() {
    awk -F '|' '$7=="true" {count++} END {print count+0}' "$WIFI_FILE"
}

get_strongest_usable_line() {
    awk -F '|' '
        $7=="true" {
            if ($4 != "") score=1000 + ($4 + 0)
            else if ($3 != "") score=$3 + 0
            else score=-10000
            print score "\t" $0
        }
    ' "$WIFI_FILE" |
        sort -t "$(printf '\t')" -k1,1nr |
        head -n 1 |
        cut -f2-
}

flatten_wifi_evidence() {
    awk -F '|' '
        BEGIN {
            printf "%-17s %-28s %9s %9s %7s %-22s\n",
                   "BSSID","SSID","SignalPct","SignalDbm","Channel","Source"
            printed=0
        }
        $7=="true" {
            printf "%-17s %-28.28s %9s %9s %7s %-22s\n",
                   $1,$2,$3,$4,$5,$6
            printed=1
        }
        END {
            if (!printed) {
                # Remove the header when there are no usable records.
                # The caller detects the sentinel and emits an empty value.
            }
        }
    ' "$WIFI_FILE"
}

wifi_evidence_flat() {
    local count
    count="$(google_usable_count)"
    if [ "$count" -eq 0 ]; then
        printf ''
        return
    fi
    flatten_wifi_evidence
}

csv_unquote() {
    printf '%s' "$1" |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/""/"/g'
}

PHYSICAL_METHOD=""
PHYSICAL_LAT=""
PHYSICAL_LON=""
PHYSICAL_ACCURACY=""
PHYSICAL_SITE=""
PHYSICAL_VPN_RESISTANT=""
PHYSICAL_DETAIL=""

resolve_known_wifi() {
    local matches line bssid lat lon site accuracy wifi_line ssid pct dbm channel score
    local winner_site best

    [ -n "$WIFI_MAP_PATH" ] || return 1
    [ -f "$WIFI_MAP_PATH" ] || {
        add_note "Known Wi-Fi map [$WIFI_MAP_PATH] does not exist."
        return 1
    }

    matches="$WORK_DIR/known-matches.tsv"
    : > "$matches"

    while IFS=, read -r bssid lat lon site accuracy rest; do
        bssid="$(csv_unquote "$bssid")"

        case "$bssid" in
            BSSID|bssid|"") continue ;;
        esac

        bssid="$(normalize_bssid "$bssid")"
        lat="$(csv_unquote "$lat")"
        lon="$(csv_unquote "$lon")"
        site="$(sanitize_field "$(csv_unquote "$site")")"
        accuracy="$(csv_unquote "$accuracy")"

        wifi_line="$(awk -F '|' -v b="$bssid" 'toupper($1)==toupper(b) {print; exit}' "$WIFI_FILE")"
        [ -n "$wifi_line" ] || continue

        IFS='|' read -r _ ssid pct dbm channel _ _ _ <<EOF
$wifi_line
EOF

        if [ -n "$dbm" ]; then
            score=$((1000 + ${dbm%.*}))
        elif [ -n "$pct" ]; then
            score="${pct%.*}"
        else
            score=-10000
        fi

        [ -n "$accuracy" ] || accuracy="50"

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$site" "$lat" "$lon" "$accuracy" "$bssid" "$ssid" \
            "$pct" "$dbm" "$channel" "$score" >> "$matches"
    done < "$WIFI_MAP_PATH"

    [ -s "$matches" ] || return 1

    winner_site="$(awk -F '|' '{c[$1]++} END {for (s in c) print c[s] "\t" s}' "$matches" |
        sort -t "$(printf '\t')" -k1,1nr |
        head -n 1 |
        cut -f2-)"

    best="$(awk -F '|' -v site="$winner_site" '$1==site {print $10 "\t" $0}' "$matches" |
        sort -t "$(printf '\t')" -k1,1nr |
        head -n 1 |
        cut -f2-)"

    [ -n "$best" ] || return 1

    IFS='|' read -r site lat lon accuracy bssid ssid pct dbm channel score <<EOF
$best
EOF

    if ! printf '%s\n' "$lat" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; then
        return 1
    fi

    if ! printf '%s\n' "$lon" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; then
        return 1
    fi

    PHYSICAL_METHOD="KnownWiFi"
    PHYSICAL_LAT="$lat"
    PHYSICAL_LON="$lon"
    PHYSICAL_ACCURACY="$accuracy"
    PHYSICAL_SITE="$site"
    PHYSICAL_VPN_RESISTANT="true"
    PHYSICAL_DETAIL="Matched known Wi-Fi site [$site]; strongest mapped anchor [$bssid]."
    return 0
}

json_number() {
    local key="$1" file="$2"
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\([-+0-9.eE]*\\).*/\\1/p" "$file" |
        head -n 1
}

json_string() {
    local key="$1" file="$2"
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" |
        head -n 1 |
        sed 's/\\"/"/g;s/\\\\/\\/g'
}

GOOGLE_WIFI_RESOLVER_STATUS="SkippedNoApiKey"
GOOGLE_WIFI_APS_USED=0

resolve_google_wifi() {
    local usable body response config count first line bssid ssid pct dbm channel source usable reason
    local lat lon accuracy key_safe http

    [ -n "$GOOGLE_API_KEY" ] || {
        GOOGLE_WIFI_RESOLVER_STATUS="SkippedNoApiKey"
        return 1
    }

    usable="$(google_usable_count)"
    if [ "$usable" -lt 2 ]; then
        GOOGLE_WIFI_RESOLVER_STATUS="SkippedInsufficientUsableBssids"
        return 1
    fi

    command -v curl >/dev/null 2>&1 || {
        GOOGLE_WIFI_RESOLVER_STATUS="SkippedCurlUnavailable"
        add_note "Google Wi-Fi geolocation was configured but curl is unavailable."
        return 1
    }

    if ! printf '%s\n' "$GOOGLE_API_KEY" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        GOOGLE_WIFI_RESOLVER_STATUS="SkippedUnsafeApiKeyCharacters"
        add_note "Google API key contains characters that are unsafe for the temporary curl configuration file."
        return 1
    fi

    body="$WORK_DIR/google-request.json"
    response="$WORK_DIR/google-response.json"
    config="$WORK_DIR/google-curl.conf"

    printf '{"considerIp":false,"wifiAccessPoints":[' > "$body"
    first=1
    count=0

    while IFS='|' read -r bssid ssid pct dbm channel source usable reason; do
        [ "$usable" = "true" ] || continue
        [ "$count" -lt 30 ] || break

        if [ "$first" -eq 0 ]; then
            printf ',' >> "$body"
        fi
        first=0

        printf '{"macAddress":"%s"' "$(printf '%s' "$bssid" | tr '[:upper:]' '[:lower:]')" >> "$body"

        if [ -n "$dbm" ] && printf '%s\n' "$dbm" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; then
            printf ',"signalStrength":%s' "$dbm" >> "$body"
        fi

        if [ -n "$channel" ] && printf '%s\n' "$channel" | grep -Eq '^[0-9]+$'; then
            printf ',"channel":%s' "$channel" >> "$body"
        fi

        printf '}' >> "$body"
        count=$((count + 1))
    done < "$WIFI_FILE"

    printf ']}' >> "$body"

    # Keep the API key out of the process command line.
    key_safe="$GOOGLE_API_KEY"
    printf 'url = "https://www.googleapis.com/geolocation/v1/geolocate?key=%s"\n' "$key_safe" > "$config"
    chmod 600 "$config" "$body"

    verbose "Google Wi-Fi resolver: submitting $count usable BSSID(s); considerIp=false."

    if ! http="$(curl -sS --max-time 8 \
        --config "$config" \
        -H 'Content-Type: application/json' \
        --data-binary @"$body" \
        -o "$response" \
        -w '%{http_code}')"; then

        GOOGLE_WIFI_RESOLVER_STATUS="FailedRequest"
        return 1
    fi

    case "$http" in
        200) ;;
        400)
            GOOGLE_WIFI_RESOLVER_STATUS="BadRequest"
            return 1
            ;;
        403)
            GOOGLE_WIFI_RESOLVER_STATUS="Forbidden"
            return 1
            ;;
        404)
            GOOGLE_WIFI_RESOLVER_STATUS="NoWifiGeolocationMatch"
            return 1
            ;;
        *)
            GOOGLE_WIFI_RESOLVER_STATUS="HttpError${http}"
            return 1
            ;;
    esac

    lat="$(json_number lat "$response")"
    lon="$(json_number lng "$response")"
    accuracy="$(json_number accuracy "$response")"

    if [ -z "$lat" ] || [ -z "$lon" ]; then
        GOOGLE_WIFI_RESOLVER_STATUS="FailedOrNoFix"
        return 1
    fi

    PHYSICAL_METHOD="GoogleWiFi"
    PHYSICAL_LAT="$lat"
    PHYSICAL_LON="$lon"
    PHYSICAL_ACCURACY="$accuracy"
    PHYSICAL_SITE=""
    PHYSICAL_VPN_RESISTANT="true"
    PHYSICAL_DETAIL="Geolocated from $count nearby universally administered Wi-Fi BSSID(s); IP fallback disabled."
    GOOGLE_WIFI_RESOLVER_STATUS="Resolved"
    GOOGLE_WIFI_APS_USED="$count"
    return 0
}

MAC_NATIVE_LOCATION_STATUS="NotAttempted"

resolve_macos_native_location() {
    local js out err lat lon accuracy

    command -v osascript >/dev/null 2>&1 || {
        MAC_NATIVE_LOCATION_STATUS="Unavailable"
        return 1
    }

    js="$WORK_DIR/corelocation.js"
    out="$WORK_DIR/corelocation.out"
    err="$WORK_DIR/corelocation.err"

    cat > "$js" <<JXA
ObjC.import('CoreLocation');

var app = Application.currentApplication();
app.includeStandardAdditions = true;

var manager = \$.CLLocationManager.alloc.init;
manager.desiredAccuracy = \$.kCLLocationAccuracyBest;
manager.startUpdatingLocation;

var end = Date.now() + (${TIMEOUT_SECONDS} * 1000);
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
    "NOFIX";
} else {
    [
        Number(location.coordinate.latitude),
        Number(location.coordinate.longitude),
        Number(location.horizontalAccuracy)
    ].join("\\t");
}
JXA

    MAC_NATIVE_LOCATION_STATUS="Attempted"
    verbose "macOS native location: Core Location."

    if ! osascript -l JavaScript "$js" >"$out" 2>"$err"; then
        MAC_NATIVE_LOCATION_STATUS="NoFix"
        verbose "Core Location failed: $(tr '\n' ' ' < "$err")"
        return 1
    fi

    if grep -q '^NOFIX' "$out"; then
        MAC_NATIVE_LOCATION_STATUS="NoFix"
        return 1
    fi

    IFS="$(printf '\t')" read -r lat lon accuracy < "$out"
    [ -n "$lat" ] && [ -n "$lon" ] || {
        MAC_NATIVE_LOCATION_STATUS="NoFix"
        return 1
    }

    PHYSICAL_METHOD="MacCoreLocation"
    PHYSICAL_LAT="$lat"
    PHYSICAL_LON="$lon"
    PHYSICAL_ACCURACY="$accuracy"
    PHYSICAL_SITE=""
    PHYSICAL_DETAIL="macOS Core Location provider."
    MAC_NATIVE_LOCATION_STATUS="Resolved"
    return 0
}

run_with_timeout() {
    local seconds outfile errfile
    seconds="$1"
    outfile="$2"
    errfile="$3"
    shift 3

    if command -v timeout >/dev/null 2>&1; then
        timeout "${seconds}s" "$@" >"$outfile" 2>"$errfile"
        return $?
    fi

    "$@" >"$outfile" 2>"$errfile" &
    local pid=$!
    local elapsed=0

    while kill -0 "$pid" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$seconds" ]; then
            kill "$pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$pid"
}

LINUX_NATIVE_PROVIDER="GeoClueUnavailable"
LINUX_NATIVE_LOCATION_STATUS="NotAttempted"

find_geoclue_helper() {
    local candidate

    for candidate in \
        "$(command -v where-am-i 2>/dev/null || true)" \
        "$(command -v geoclue-where-am-i 2>/dev/null || true)" \
        /usr/libexec/geoclue-2.0/demos/where-am-i \
        /usr/lib/geoclue-2.0/demos/where-am-i; do

        [ -n "$candidate" ] || continue
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_linux_native_location() {
    local helper out err text lat lon accuracy

    helper="$(find_geoclue_helper || true)"
    [ -n "$helper" ] || return 1

    LINUX_NATIVE_PROVIDER="GeoClue"
    LINUX_NATIVE_LOCATION_STATUS="Attempted"
    out="$WORK_DIR/geoclue.out"
    err="$WORK_DIR/geoclue.err"

    verbose "Linux native location: GeoClue helper [$helper]."

    if ! run_with_timeout "$TIMEOUT_SECONDS" "$out" "$err" "$helper"; then
        LINUX_NATIVE_LOCATION_STATUS="NoFix"
        return 1
    fi

    text="$WORK_DIR/geoclue-combined.txt"
    cat "$out" "$err" > "$text"

    lat="$(sed -n 's/^[[:space:]]*Latitude[[:space:]]*:[[:space:]]*\([-+0-9.]*\).*/\1/p' "$text" | head -n 1)"
    lon="$(sed -n 's/^[[:space:]]*Longitude[[:space:]]*:[[:space:]]*\([-+0-9.]*\).*/\1/p' "$text" | head -n 1)"
    accuracy="$(sed -n 's/^[[:space:]]*Accuracy[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' "$text" | head -n 1)"

    [ -n "$lat" ] && [ -n "$lon" ] || {
        LINUX_NATIVE_LOCATION_STATUS="NoFix"
        return 1
    }

    PHYSICAL_METHOD="LinuxGeoClue"
    PHYSICAL_LAT="$lat"
    PHYSICAL_LON="$lon"
    PHYSICAL_ACCURACY="$accuracy"
    PHYSICAL_SITE=""
    PHYSICAL_DETAIL="Linux GeoClue provider."
    LINUX_NATIVE_LOCATION_STATUS="Resolved"
    return 0
}

resolve_native_location() {
    if [ "$PLATFORM" = "macOS" ]; then
        resolve_macos_native_location
    else
        resolve_linux_native_location
    fi
}

PUBLIC_IP=""
PUBLIC_IP_LAT=""
PUBLIC_IP_LON=""
PUBLIC_IP_CITY=""
PUBLIC_IP_REGION=""
PUBLIC_IP_COUNTRY=""
PUBLIC_IP_ISP=""

fetch_url() {
    local url="$1" output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 6 "$url" -o "$output"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -T 6 -O "$output" "$url"
        return $?
    fi

    return 127
}

resolve_public_ip() {
    local response

    [ "$SKIP_PUBLIC_IP" -eq 0 ] || return 1

    response="$WORK_DIR/public-ip.json"
    verbose "Public-IP resolver: ipwho.is fallback."

    if ! fetch_url "https://ipwho.is/" "$response"; then
        add_note "Public-IP geolocation failed because no supported HTTP client was available or the request failed."
        return 1
    fi

    if grep -Eq '"success"[[:space:]]*:[[:space:]]*false' "$response"; then
        return 1
    fi

    PUBLIC_IP="$(json_string ip "$response")"
    PUBLIC_IP_LAT="$(json_number latitude "$response")"
    PUBLIC_IP_LON="$(json_number longitude "$response")"
    PUBLIC_IP_CITY="$(json_string city "$response")"
    PUBLIC_IP_REGION="$(json_string region "$response")"
    PUBLIC_IP_COUNTRY="$(json_string country "$response")"
    PUBLIC_IP_ISP="$(json_string isp "$response")"

    [ -n "$PUBLIC_IP_LAT" ] && [ -n "$PUBLIC_IP_LON" ]
}

collect_linux_vpn_evidence() {
    local line

    if command -v ip >/dev/null 2>&1; then
        ip -o link show up 2>/dev/null |
            grep -Ei '\b(tun[0-9]*|tap[0-9]*|wg[0-9]*|nordlynx|tailscale[0-9]*|zt[a-z0-9]+|vpn)\b|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler' |
            while IFS= read -r line; do
                printf 'Interface: %s\n' "$line"
            done >> "$VPN_FILE"
    fi

    if command -v nmcli >/dev/null 2>&1; then
        LC_ALL=C LANG=C nmcli -t --escape no \
            -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
            grep -Ei ':vpn:|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler|nord|tailscale|zerotier' |
            while IFS= read -r line; do
                printf 'NetworkManager: %s\n' "$line"
            done >> "$VPN_FILE"
    fi
}

collect_macos_vpn_evidence() {
    local line

    if [ -x /sbin/ifconfig ]; then
        /sbin/ifconfig 2>/dev/null |
            grep -E '^(utun[0-9]+|ppp[0-9]+|tun[0-9]+|tap[0-9]+|wg[0-9]+):' |
            while IFS= read -r line; do
                printf 'Interface: %s\n' "${line%%:*}"
            done >> "$VPN_FILE"
    fi

    if [ -x /usr/sbin/scutil ]; then
        /usr/sbin/scutil --nc list 2>/dev/null |
            grep -Ei '\(Connected\)|Connected' |
            while IFS= read -r line; do
                printf 'Network service: %s\n' "$line"
            done >> "$VPN_FILE"
    fi
}

collect_vpn_evidence() {
    if [ "$PLATFORM" = "Linux" ]; then
        collect_linux_vpn_evidence
    else
        collect_macos_vpn_evidence
    fi

    if [ -s "$VPN_FILE" ]; then
        sort -u "$VPN_FILE" -o "$VPN_FILE"
    fi
}

distance_km() {
    awk -v lat1="$1" -v lon1="$2" -v lat2="$3" -v lon2="$4" '
        BEGIN {
            pi=atan2(0,-1)
            r=6371.0088
            p1=lat1*pi/180
            p2=lat2*pi/180
            dp=(lat2-lat1)*pi/180
            dl=(lon2-lon1)*pi/180
            a=(sin(dp/2)^2) + cos(p1)*cos(p2)*(sin(dl/2)^2)
            c=2*atan2(sqrt(a),sqrt(1-a))
            printf "%.2f", r*c
        }
    '
}

number_le() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'
}

number_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

location_confidence() {
    local method="$1" accuracy="$2"

    if [ "$method" = "PublicIP" ]; then
        printf 'Low'
    elif [ "$method" = "KnownWiFi" ]; then
        printf 'High'
    elif [ -z "$accuracy" ]; then
        printf 'Medium'
    elif number_le "$accuracy" "250"; then
        printf 'High'
    elif number_le "$accuracy" "5000"; then
        printf 'Medium'
    else
        printf 'Low'
    fi
}

print_field() {
    local key="$1" value="${2:-}" first=1 line

    if [ -z "$value" ]; then
        printf '%-34s :\n' "$key"
        return
    fi

    printf '%s\n' "$value" |
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$first" -eq 1 ]; then
                printf '%-34s : %s\n' "$key" "$line"
                first=0
            else
                printf '%-34s   %s\n' "" "$line"
            fi
        done
}


# ---------------------------------------------------------------------------
# v2.0 / Windows v3.62 parity helpers
# ---------------------------------------------------------------------------

CACHE_ROOT=""
OUI_CACHE_FILE=""
WIGLE_CACHE_FILE=""

init_persistent_cache() {
    if [ "$PLATFORM" = "macOS" ]; then
        CACHE_ROOT="${HOME:-$WORK_DIR}/Library/Caches/Get-DeviceCoords"
    else
        if [ -n "${XDG_CACHE_HOME:-}" ]; then
            CACHE_ROOT="${XDG_CACHE_HOME%/}/Get-DeviceCoords"
        else
            CACHE_ROOT="${HOME:-$WORK_DIR}/.cache/Get-DeviceCoords"
        fi
    fi

    if ! mkdir -p "$CACHE_ROOT" >/dev/null 2>&1; then
        CACHE_ROOT="$WORK_DIR/cache"
        mkdir -p "$CACHE_ROOT" >/dev/null 2>&1 || true
        add_note "Persistent cache directory was unavailable; using an ephemeral per-run cache."
    fi

    OUI_CACHE_FILE="$CACHE_ROOT/oui-vendor-cache.tsv"
    WIGLE_CACHE_FILE="$CACHE_ROOT/wigle-bssid-cache.tsv"
    touch "$OUI_CACHE_FILE" "$WIGLE_CACHE_FILE" 2>/dev/null || true
    chmod 600 "$OUI_CACHE_FILE" "$WIGLE_CACHE_FILE" 2>/dev/null || true
}

epoch_now() {
    date '+%s'
}

DEVICE_TYPE="Unknown"
DEVICE_MODEL=""
DEVICE_MANUFACTURER=""
DEVICE_HAS_BATTERY="false"
DEVICE_WIFI_INTERFACE=""

get_device_profile_linux() {
    local chassis vendor product wifiif
    chassis=""
    vendor=""
    product=""
    wifiif=""

    [ -r /sys/class/dmi/id/chassis_type ] && chassis="$(tr -d '\r\n' < /sys/class/dmi/id/chassis_type)"
    [ -r /sys/class/dmi/id/sys_vendor ] && vendor="$(tr -d '\r\n' < /sys/class/dmi/id/sys_vendor)"
    [ -r /sys/class/dmi/id/product_name ] && product="$(tr -d '\r\n' < /sys/class/dmi/id/product_name)"

    if find /sys/class/power_supply -maxdepth 1 -type l -name 'BAT*' 2>/dev/null | grep -q .; then
        DEVICE_HAS_BATTERY="true"
    fi

    for wifiif in /sys/class/net/*/wireless; do
        [ -d "$wifiif" ] || continue
        DEVICE_WIFI_INTERFACE="$(basename "$(dirname "$wifiif")")"
        break
    done

    DEVICE_MANUFACTURER="$vendor"
    DEVICE_MODEL="$product"

    case "$chassis" in
        8|9|10|11|12|14|18|21|30|31|32)
            DEVICE_TYPE="Portable"
            ;;
        23|28)
            DEVICE_TYPE="Server"
            ;;
        3|4|5|6|7|13|15|16|17|24|35|36)
            DEVICE_TYPE="Desktop"
            ;;
        *)
            if [ "$DEVICE_HAS_BATTERY" = "true" ]; then
                DEVICE_TYPE="Portable"
            elif printf '%s %s' "$vendor" "$product" | grep -Eqi 'virtual|vmware|virtualbox|kvm|qemu|hyper-v|xen'; then
                DEVICE_TYPE="Virtual"
            elif [ -n "$product" ]; then
                DEVICE_TYPE="Desktop"
            fi
            ;;
    esac
}

get_device_profile_macos() {
    local model battery portline hwline
    model="$(sysctl -n hw.model 2>/dev/null || true)"
    battery="false"

    if command -v ioreg >/dev/null 2>&1 &&
       ioreg -r -c AppleSmartBattery -d 1 2>/dev/null | grep -q 'AppleSmartBattery'; then
        battery="true"
    fi

    DEVICE_MODEL="$model"
    DEVICE_MANUFACTURER="Apple"
    DEVICE_HAS_BATTERY="$battery"

    if [ "$battery" = "true" ] || printf '%s' "$model" | grep -qi 'MacBook'; then
        DEVICE_TYPE="Portable"
    elif [ -n "$model" ]; then
        DEVICE_TYPE="Desktop"
    fi

    if [ -x /usr/sbin/networksetup ]; then
        DEVICE_WIFI_INTERFACE="$(
            /usr/sbin/networksetup -listallhardwareports 2>/dev/null |
            awk '
                /^Hardware Port: (Wi-Fi|AirPort)$/ {wifi=1; next}
                wifi && /^Device:/ {print $2; exit}
            '
        )"
    fi
}

get_device_profile() {
    if [ "$PLATFORM" = "Linux" ]; then
        get_device_profile_linux
    else
        get_device_profile_macos
    fi
}

CURRENT_WIFI_STATUS="NotAttempted"
CURRENT_WIFI_SSID=""
CURRENT_WIFI_BSSID=""
CURRENT_WIFI_SIGNAL_PCT=""
CURRENT_WIFI_SIGNAL_DBM=""
CURRENT_WIFI_CHANNEL=""
CURRENT_WIFI_SOURCE=""

collect_current_wifi_linux() {
    local line rest
    command -v nmcli >/dev/null 2>&1 || {
        CURRENT_WIFI_STATUS="Unavailable"
        return 1
    }

    line="$(
        LC_ALL=C LANG=C nmcli -t --escape no \
            -f IN-USE,BSSID,SIGNAL,CHAN,SSID \
            device wifi list --rescan no 2>/dev/null |
        awk '/^\*:/ {print; exit}'
    )"

    [ -n "$line" ] || {
        CURRENT_WIFI_STATUS="NotAssociated"
        return 1
    }

    line="${line#*:}"
    [ "${#line}" -ge 19 ] || {
        CURRENT_WIFI_STATUS="ParseFailed"
        return 1
    }

    CURRENT_WIFI_BSSID="$(normalize_bssid "${line:0:17}")"
    rest="${line:18}"
    CURRENT_WIFI_SIGNAL_PCT="${rest%%:*}"
    rest="${rest#*:}"
    CURRENT_WIFI_CHANNEL="${rest%%:*}"
    CURRENT_WIFI_SSID="${rest#*:}"
    CURRENT_WIFI_SOURCE="LinuxNetworkManagerCurrent"

    if printf '%s\n' "$CURRENT_WIFI_BSSID" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'; then
        CURRENT_WIFI_STATUS="Associated"
        return 0
    fi

    CURRENT_WIFI_STATUS="ParseFailed"
    return 1
}

collect_current_wifi_macos() {
    local js out err
    command -v osascript >/dev/null 2>&1 || {
        CURRENT_WIFI_STATUS="Unavailable"
        return 1
    }

    js="$WORK_DIR/corewlan-current.js"
    out="$WORK_DIR/corewlan-current.tsv"
    err="$WORK_DIR/corewlan-current.err"

    cat > "$js" <<'JXA'
ObjC.import('CoreWLAN');

function unwrapString(value) {
    try {
        if (!value) return "";
        var s = ObjC.unwrap(value);
        if (s === undefined || s === null) return "";
        return String(s);
    } catch (e) {
        return "";
    }
}
function clean(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\t\r\n]/g, " ");
}

var iface = $.CWWiFiClient.sharedWiFiClient.interface;
if (!iface) {
    "";
} else {
    var channel = iface.wlanChannel;
    [
        clean(unwrapString(iface.bssid)),
        clean(unwrapString(iface.ssid)),
        clean(Number(iface.rssiValue)),
        clean(channel ? Number(channel.channelNumber) : "")
    ].join("\t");
}
JXA

    if ! osascript -l JavaScript "$js" >"$out" 2>"$err"; then
        CURRENT_WIFI_STATUS="Unavailable"
        return 1
    fi

    IFS="$(printf '\t')" read -r \
        CURRENT_WIFI_BSSID CURRENT_WIFI_SSID \
        CURRENT_WIFI_SIGNAL_DBM CURRENT_WIFI_CHANNEL < "$out"

    CURRENT_WIFI_BSSID="$(normalize_bssid "$CURRENT_WIFI_BSSID")"
    CURRENT_WIFI_SOURCE="MacCoreWLANCurrent"

    if printf '%s\n' "$CURRENT_WIFI_BSSID" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'; then
        CURRENT_WIFI_STATUS="Associated"
        return 0
    fi

    if [ -n "$CURRENT_WIFI_SSID" ]; then
        CURRENT_WIFI_STATUS="AssociatedIdentifiersRedacted"
    else
        CURRENT_WIFI_STATUS="NotAssociated"
    fi
    CURRENT_WIFI_BSSID=""
    return 1
}

collect_current_wifi() {
    if [ "$PLATFORM" = "Linux" ]; then
        collect_current_wifi_linux || true
    else
        collect_current_wifi_macos || true
    fi

    if [ -n "$CURRENT_WIFI_BSSID" ]; then
        append_wifi_record \
            "$CURRENT_WIFI_BSSID" \
            "$CURRENT_WIFI_SSID" \
            "$CURRENT_WIFI_SIGNAL_PCT" \
            "$CURRENT_WIFI_SIGNAL_DBM" \
            "$CURRENT_WIFI_CHANNEL" \
            "$CURRENT_WIFI_SOURCE"
        dedupe_wifi_records
    fi
}

normalize_oui() {
    normalize_bssid "$1" | awk -F: '{print $1 $2 $3}'
}

cache_line_fresh() {
    local checked="$1" ttl="$2" now
    now="$(epoch_now)"
    [ -n "$checked" ] || return 1
    printf '%s\n' "$checked" | grep -Eq '^[0-9]+$' || return 1
    [ $((now - checked)) -le "$ttl" ]
}

get_gateway_vendor_by_mac() {
    local mac oui line vendor checked response tmp now
    mac="$(normalize_bssid "$1")"
    [ -n "$mac" ] || return 1

    if ! is_google_usable_bssid "$mac"; then
        if [ "$GOOGLE_ELIGIBILITY_REASON" = "LocallyAdministered" ]; then
            printf 'Private'
            return 0
        fi
    fi

    oui="$(normalize_oui "$mac")"
    printf '%s\n' "$oui" | grep -Eq '^[0-9A-F]{6}$' || return 1

    line="$(awk -F '|' -v o="$oui" '$1==o {print; exit}' "$OUI_CACHE_FILE" 2>/dev/null || true)"
    if [ -n "$line" ]; then
        IFS='|' read -r _ vendor checked <<EOF
$line
EOF
        if [ "$vendor" = "<none>" ]; then
            cache_line_fresh "$checked" 2592000 && return 1
        else
            if cache_line_fresh "$checked" 31536000; then
                printf '%s' "$vendor"
                return 0
            fi
        fi
    fi

    command -v curl >/dev/null 2>&1 || return 1
    response="$WORK_DIR/oui-${oui}.txt"
    vendor=""

    if curl -fsS --max-time 4 \
        "https://api.maclookup.app/v2/macs/${oui}/company/name" \
        -o "$response" 2>/dev/null; then
        vendor="$(head -c 256 "$response" | tr '\r\n|' '   ' | sed 's/^"//;s/"$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$vendor" in
            ""|"*error*"|"null"|"Not Found") vendor="" ;;
        esac
    fi

    if [ -z "$vendor" ]; then
        if curl -fsS --max-time 4 \
            "https://www.macvendorlookup.com/api/v2/${oui}" \
            -o "$response" 2>/dev/null; then
            vendor="$(json_string company "$response")"
        fi
    fi

    now="$(epoch_now)"
    tmp="$WORK_DIR/oui-cache.tmp"
    awk -F '|' -v o="$oui" '$1!=o' "$OUI_CACHE_FILE" 2>/dev/null > "$tmp" || true

    if [ -n "$vendor" ]; then
        vendor="$(sanitize_field "$vendor")"
        printf '%s|%s|%s\n' "$oui" "$vendor" "$now" >> "$tmp"
        mv "$tmp" "$OUI_CACHE_FILE" 2>/dev/null || true
        chmod 600 "$OUI_CACHE_FILE" 2>/dev/null || true
        printf '%s' "$vendor"
        return 0
    fi

    printf '%s|<none>|%s\n' "$oui" "$now" >> "$tmp"
    mv "$tmp" "$OUI_CACHE_FILE" 2>/dev/null || true
    chmod 600 "$OUI_CACHE_FILE" 2>/dev/null || true
    return 1
}

wifi_vendor_for_bssid() {
    local bssid="$1" vendor
    if is_google_usable_bssid "$bssid"; then
        vendor="$(get_gateway_vendor_by_mac "$bssid" 2>/dev/null || true)"
        [ -n "$vendor" ] && printf '%s' "$vendor" || printf 'Unknown'
        return
    fi
    if [ "$GOOGLE_ELIGIBILITY_REASON" = "LocallyAdministered" ]; then
        printf 'Private'
    else
        printf 'Unknown'
    fi
}

wifi_evidence_flat() {
    local count line bssid ssid pct dbm channel source usable reason vendor
    count="$(awk 'END {print NR+0}' "$WIFI_FILE")"
    [ "$count" -gt 0 ] || {
        printf 'None'
        return
    }

    printf "%-16s %-17s %-28s %6s %7s %4s %-22s\n" \
        "OUIVend" "BSSID" "SSID" "Sig%" "SignDb" "Ch" "Source"

    while IFS='|' read -r bssid ssid pct dbm channel source usable reason; do
        [ -n "$bssid" ] || continue

        # Match v3.62 evidence intent: usable anchors plus the current association.
        if [ "$usable" != "true" ] &&
           [ "$(printf '%s' "$bssid" | tr '[:lower:]' '[:upper:]')" != "$(printf '%s' "$CURRENT_WIFI_BSSID" | tr '[:lower:]' '[:upper:]')" ]; then
            continue
        fi

        vendor="$(wifi_vendor_for_bssid "$bssid")"
        [ -n "$ssid" ] || ssid="<hidden>"
        printf "%-16.16s %-17s %-28.28s %6s %7s %4s %-22.22s\n" \
            "$vendor" "$bssid" "$ssid" "$pct" "$dbm" "$channel" "$source"
    done < "$WIFI_FILE"
}

WIGLE_WIFI_RESOLVER_STATUS="SkippedNoCredentials"
WIGLE_LIVE_QUERIES_USED=0
WIGLE_CACHE_HITS=0
WIGLE_CANDIDATE_COUNT=0
WIGLE_CACHE_CANDIDATES_CHECKED=0
WIGLE_LIVE_CANDIDATES_ELIGIBLE=0
WIGLE_CURRENT_BSSID_PRIORITIZED="false"
WIGLE_CURRENT_BSSID=""
WIGLE_CURRENT_BSSID_ELIGIBILITY=""
WIGLE_LAST_HTTP_STATUS=""
WIGLE_LAST_ERROR_MESSAGE=""
WIGLE_LAST_ERROR_BODY=""
WIGLE_TERMINAL_FAILURE="false"
WIGLE_TERMINAL_FAILURE_BASIS=""
WIGLE_RATE_LIMIT_BASIS=""
WIGLE_RATE_LIMIT_REMAINING=""
WIGLE_RATE_LIMIT_LIMIT=""
WIGLE_RATE_LIMIT_RESET=""
WIGLE_CANDIDATE_ORDER=""

base64_compact() {
    if command -v base64 >/dev/null 2>&1; then
        base64 | tr -d '\r\n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl base64 -A
    else
        return 1
    fi
}

wigle_cache_get_fresh() {
    local bssid="$1" line found lat lon ssid last checked ttl
    line="$(awk -F '|' -v b="$bssid" 'toupper($1)==toupper(b) {print; exit}' "$WIGLE_CACHE_FILE" 2>/dev/null || true)"
    [ -n "$line" ] || return 1

    IFS='|' read -r _ found lat lon ssid last checked <<EOF
$line
EOF

    if [ "$found" = "true" ]; then
        ttl=15552000
    else
        ttl=1209600
    fi

    cache_line_fresh "$checked" "$ttl" || return 1
    printf '%s' "$line"
}

wigle_cache_put() {
    local bssid="$1" found="$2" lat="$3" lon="$4" ssid="$5" last="$6"
    local now tmp
    now="$(epoch_now)"
    ssid="$(sanitize_field "$ssid")"
    last="$(sanitize_field "$last")"
    tmp="$WORK_DIR/wigle-cache.tmp"
    awk -F '|' -v b="$bssid" 'toupper($1)!=toupper(b)' "$WIGLE_CACHE_FILE" 2>/dev/null > "$tmp" || true
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$bssid" "$found" "$lat" "$lon" "$ssid" "$last" "$now" >> "$tmp"
    mv "$tmp" "$WIGLE_CACHE_FILE" 2>/dev/null || true
    chmod 600 "$WIGLE_CACHE_FILE" 2>/dev/null || true
}

build_wigle_candidates() {
    local candidates="$WORK_DIR/wigle-candidates.txt" current
    : > "$candidates"
    current="$(normalize_bssid "$CURRENT_WIFI_BSSID")"

    if [ -n "$current" ]; then
        WIGLE_CURRENT_BSSID="$current"
        if is_google_usable_bssid "$current"; then
            WIGLE_CURRENT_BSSID_ELIGIBILITY="UniversallyAdministered"
            awk -F '|' -v b="$current" '$7=="true" && toupper($1)==toupper(b) {print $1; exit}' "$WIFI_FILE" >> "$candidates"
            if [ -s "$candidates" ]; then
                WIGLE_CURRENT_BSSID_PRIORITIZED="true"
            fi
        else
            WIGLE_CURRENT_BSSID_ELIGIBILITY="$GOOGLE_ELIGIBILITY_REASON"
        fi
    fi

    # First pass adds the strongest representative of each SSID/BSSID family.
    awk -F '|' -v current="$current" '
        $7=="true" && toupper($1)!=toupper(current) {
            family=$2
            if (family=="") family=substr(toupper($1),1,14)
            if (!(family in seen)) {
                print $1
                seen[family]=1
            }
        }
    ' "$WIFI_FILE" >> "$candidates"

    # Second pass adds remaining siblings in observed signal order.
    awk -F '|' -v current="$current" '
        $7=="true" && toupper($1)!=toupper(current) {print $1}
    ' "$WIFI_FILE" |
        while IFS= read -r b; do
            grep -Fxiq "$b" "$candidates" 2>/dev/null || printf '%s\n' "$b" >> "$candidates"
        done

    WIGLE_CANDIDATE_COUNT="$(awk 'NF {n++} END {print n+0}' "$candidates")"
    WIGLE_CANDIDATE_ORDER="$(awk 'NF {printf "%s%s", sep, $0; sep=" > "}' "$candidates")"
}

wigle_parse_rate_headers() {
    local headers="$1"
    WIGLE_RATE_LIMIT_REMAINING="$(awk 'tolower($0) ~ /^x-ratelimit-remaining:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
    WIGLE_RATE_LIMIT_LIMIT="$(awk 'tolower($0) ~ /^x-ratelimit-limit:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
    WIGLE_RATE_LIMIT_RESET="$(awk 'tolower($0) ~ /^x-ratelimit-reset:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
}

resolve_wigle_wifi() {
    local candidates bssid line found lat lon ssid last checked
    local auth config response headers http encoded error_text

    if [ -z "$WIGLE_API_NAME" ] || [ -z "$WIGLE_API_TOKEN" ]; then
        WIGLE_WIFI_RESOLVER_STATUS="SkippedNoCredentials"
        return 1
    fi

    command -v curl >/dev/null 2>&1 || {
        WIGLE_WIFI_RESOLVER_STATUS="SkippedCurlUnavailable"
        return 1
    }

    auth="$(printf '%s' "${WIGLE_API_NAME}:${WIGLE_API_TOKEN}" | base64_compact 2>/dev/null || true)"
    if [ -z "$auth" ]; then
        WIGLE_WIFI_RESOLVER_STATUS="SkippedBase64Unavailable"
        return 1
    fi

    build_wigle_candidates
    candidates="$WORK_DIR/wigle-candidates.txt"

    if [ "$WIGLE_CANDIDATE_COUNT" -eq 0 ]; then
        WIGLE_WIFI_RESOLVER_STATUS="SkippedNoUsableBssids"
        return 1
    fi

    # Pass 1: inspect every fresh cache candidate before spending live quota.
    while IFS= read -r bssid; do
        [ -n "$bssid" ] || continue
        WIGLE_CACHE_CANDIDATES_CHECKED=$((WIGLE_CACHE_CANDIDATES_CHECKED + 1))
        line="$(wigle_cache_get_fresh "$bssid" || true)"
        [ -n "$line" ] || continue
        WIGLE_CACHE_HITS=$((WIGLE_CACHE_HITS + 1))
        IFS='|' read -r _ found lat lon ssid last checked <<EOF
$line
EOF
        if [ "$found" = "true" ] && [ -n "$lat" ] && [ -n "$lon" ]; then
            PHYSICAL_METHOD="WiGLEWiFi"
            PHYSICAL_LAT="$lat"
            PHYSICAL_LON="$lon"
            PHYSICAL_ACCURACY=""
            PHYSICAL_SITE=""
            PHYSICAL_VPN_RESISTANT="true"
            PHYSICAL_DETAIL="WiGLE exact-BSSID cache match [$bssid]${ssid:+ ($ssid)}."
            WIGLE_WIFI_RESOLVER_STATUS="ResolvedFromCache"
            return 0
        fi
    done < "$candidates"

    WIGLE_LIVE_CANDIDATES_ELIGIBLE=0
    while IFS= read -r bssid; do
        [ -n "$bssid" ] || continue
        line="$(wigle_cache_get_fresh "$bssid" || true)"
        [ -n "$line" ] || WIGLE_LIVE_CANDIDATES_ELIGIBLE=$((WIGLE_LIVE_CANDIDATES_ELIGIBLE + 1))
    done < "$candidates"

    config="$WORK_DIR/wigle-curl.conf"
    printf 'header = "Authorization: Basic %s"\n' "$auth" > "$config"
    printf 'header = "Accept: application/json"\n' >> "$config"
    chmod 600 "$config"

    while IFS= read -r bssid; do
        [ -n "$bssid" ] || continue

        # Fresh negative cache entries suppress live lookup.
        line="$(wigle_cache_get_fresh "$bssid" || true)"
        if [ -n "$line" ]; then
            IFS='|' read -r _ found _ _ _ _ _ <<EOF
$line
EOF
            [ "$found" = "false" ] && continue
        fi

        [ "$WIGLE_LIVE_QUERIES_USED" -lt "$MAX_WIGLE_LOOKUPS" ] || {
            WIGLE_WIFI_RESOLVER_STATUS="LookupBudgetExhausted"
            break
        }

        response="$WORK_DIR/wigle-response-${WIGLE_LIVE_QUERIES_USED}.json"
        headers="$WORK_DIR/wigle-headers-${WIGLE_LIVE_QUERIES_USED}.txt"
        encoded="$(printf '%s' "$bssid" | sed 's/:/%3A/g')"

        WIGLE_LIVE_QUERIES_USED=$((WIGLE_LIVE_QUERIES_USED + 1))
        verbose "WiGLE resolver: exact BSSID [$bssid], live query $WIGLE_LIVE_QUERIES_USED/$MAX_WIGLE_LOOKUPS."

        http="$(
            curl -sS --max-time 8 \
                --config "$config" \
                -D "$headers" \
                -o "$response" \
                -w '%{http_code}' \
                "https://api.wigle.net/api/v2/network/search?onlymine=false&resultsPerPage=1&netid=${encoded}" \
                2>"$WORK_DIR/wigle-curl.err" || printf '000'
        )"

        WIGLE_LAST_HTTP_STATUS="$http"
        wigle_parse_rate_headers "$headers"

        case "$http" in
            200)
                lat="$(json_number trilat "$response")"
                lon="$(json_number trilong "$response")"
                ssid="$(json_string ssid "$response")"
                last="$(json_string lastupdt "$response")"

                if [ -n "$lat" ] && [ -n "$lon" ]; then
                    wigle_cache_put "$bssid" "true" "$lat" "$lon" "$ssid" "$last"
                    PHYSICAL_METHOD="WiGLEWiFi"
                    PHYSICAL_LAT="$lat"
                    PHYSICAL_LON="$lon"
                    PHYSICAL_ACCURACY=""
                    PHYSICAL_SITE=""
                    PHYSICAL_VPN_RESISTANT="true"
                    PHYSICAL_DETAIL="WiGLE exact-BSSID match [$bssid]${ssid:+ ($ssid)}."
                    WIGLE_WIFI_RESOLVER_STATUS="Resolved"
                    return 0
                fi

                error_text="$(json_string message "$response")"
                [ -n "$error_text" ] || error_text="$(json_string error "$response")"

                if printf '%s' "$error_text" | grep -Eqi 'rate.?limit|too many|quota'; then
                    WIGLE_TERMINAL_FAILURE="true"
                    WIGLE_TERMINAL_FAILURE_BASIS="API rate-limit message"
                    WIGLE_RATE_LIMIT_BASIS="API message"
                    WIGLE_WIFI_RESOLVER_STATUS="RateLimited"
                    break
                fi

                if printf '%s' "$error_text" | grep -Eqi 'unauthori|forbidden|credential|api.?key|token'; then
                    WIGLE_TERMINAL_FAILURE="true"
                    WIGLE_TERMINAL_FAILURE_BASIS="API authentication/authorization message"
                    WIGLE_WIFI_RESOLVER_STATUS="AuthenticationFailed"
                    break
                fi

                # A clean HTTP 200 with no location is a valid negative exact-BSSID result.
                wigle_cache_put "$bssid" "false" "" "" "" ""
                WIGLE_WIFI_RESOLVER_STATUS="NoMatch"
                ;;
            401)
                WIGLE_WIFI_RESOLVER_STATUS="AuthenticationFailed"
                WIGLE_TERMINAL_FAILURE="true"
                WIGLE_TERMINAL_FAILURE_BASIS="HTTP 401"
                break
                ;;
            403)
                WIGLE_WIFI_RESOLVER_STATUS="AuthenticationFailed"
                WIGLE_TERMINAL_FAILURE="true"
                WIGLE_TERMINAL_FAILURE_BASIS="HTTP 403"
                break
                ;;
            429)
                WIGLE_WIFI_RESOLVER_STATUS="RateLimited"
                WIGLE_TERMINAL_FAILURE="true"
                WIGLE_TERMINAL_FAILURE_BASIS="HTTP 429"
                WIGLE_RATE_LIMIT_BASIS="HTTP 429"
                break
                ;;
            000)
                WIGLE_WIFI_RESOLVER_STATUS="RequestFailed"
                WIGLE_LAST_ERROR_MESSAGE="$(tr '\r\n|' '   ' < "$WORK_DIR/wigle-curl.err" | head -c 240)"
                ;;
            *)
                WIGLE_WIFI_RESOLVER_STATUS="HttpError${http}"
                ;;
        esac

        if [ -s "$response" ]; then
            error_text="$(json_string message "$response")"
            [ -n "$error_text" ] || error_text="$(json_string error "$response")"
            WIGLE_LAST_ERROR_MESSAGE="$(sanitize_field "$error_text")"
            WIGLE_LAST_ERROR_BODY="$(head -c 320 "$response" | tr '\r\n|' '   ')"

            if printf '%s' "$error_text" | grep -Eqi 'rate.?limit|too many|quota'; then
                WIGLE_TERMINAL_FAILURE="true"
                WIGLE_TERMINAL_FAILURE_BASIS="API rate-limit message"
                WIGLE_RATE_LIMIT_BASIS="API message"
                WIGLE_WIFI_RESOLVER_STATUS="RateLimited"
                break
            fi
        fi

        if [ -n "$WIGLE_RATE_LIMIT_REMAINING" ] &&
           printf '%s' "$WIGLE_RATE_LIMIT_REMAINING" | grep -Eq '^[0-9]+$' &&
           [ "$WIGLE_RATE_LIMIT_REMAINING" -le 0 ]; then
            WIGLE_TERMINAL_FAILURE="true"
            WIGLE_TERMINAL_FAILURE_BASIS="Rate-limit remaining=0"
            WIGLE_RATE_LIMIT_BASIS="X-RateLimit-Remaining"
            WIGLE_WIFI_RESOLVER_STATUS="RateLimited"
            break
        fi
    done < "$candidates"

    [ "$WIGLE_WIFI_RESOLVER_STATUS" != "SkippedNoCredentials" ] ||
        WIGLE_WIFI_RESOLVER_STATUS="NoMatch"
    return 1
}

PUBLIC_IP_VERSION=""
PUBLIC_IP_ORG=""
PUBLIC_IP_ASN=""

resolve_public_ip() {
    local ipresponse response preferred

    [ "$SKIP_PUBLIC_IP" -eq 0 ] || return 1
    command -v curl >/dev/null 2>&1 && preferred="$(
        curl -4 -fsS --max-time 5 'https://api.ipify.org?format=json' 2>/dev/null |
        sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
    )"

    response="$WORK_DIR/public-ip.json"
    if [ -n "$preferred" ] &&
       printf '%s' "$preferred" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        verbose "Public-IP resolver: geolocating preferred IPv4 [$preferred]."
        if ! fetch_url "https://ipwho.is/${preferred}" "$response"; then
            preferred=""
        fi
    fi

    if [ -z "$preferred" ]; then
        verbose "Public-IP resolver: ipwho.is caller fallback."
        if ! fetch_url "https://ipwho.is/" "$response"; then
            add_note "Public-IP geolocation failed because no supported HTTP client was available or the request failed."
            return 1
        fi
    fi

    if grep -Eq '"success"[[:space:]]*:[[:space:]]*false' "$response"; then
        return 1
    fi

    PUBLIC_IP="$(json_string ip "$response")"
    [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$preferred"
    PUBLIC_IP_LAT="$(json_number latitude "$response")"
    PUBLIC_IP_LON="$(json_number longitude "$response")"
    PUBLIC_IP_CITY="$(json_string city "$response")"
    PUBLIC_IP_REGION="$(json_string region "$response")"
    PUBLIC_IP_COUNTRY="$(json_string country "$response")"
    PUBLIC_IP_ISP="$(json_string isp "$response")"
    PUBLIC_IP_ORG="$(json_string org "$response")"
    PUBLIC_IP_ASN="$(json_number asn "$response")"

    if printf '%s' "$PUBLIC_IP" | grep -q ':'; then
        PUBLIC_IP_VERSION="IPv6"
    elif [ -n "$PUBLIC_IP" ]; then
        PUBLIC_IP_VERSION="IPv4"
    fi

    [ -n "$PUBLIC_IP_LAT" ] && [ -n "$PUBLIC_IP_LON" ]
}



ACTIVE_INTERFACE=""
ACTIVE_INTERFACE_TYPE=""
LOCAL_IPV4=""
DEFAULT_GATEWAY=""
GATEWAY_MAC=""
GATEWAY_VENDOR=""
DHCP_SERVER=""
CONNECTION_DNS_SUFFIX=""

is_vpn_interface_name() {
    printf '%s' "$1" | grep -Eqi '^(tun[0-9]*|tap[0-9]*|utun[0-9]*|ppp[0-9]*|wg[0-9]*|nordlynx|tailscale[0-9]*|zt[a-z0-9]+)$|vpn|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler'
}

get_network_context_linux() {
    local line rest iface gw src
    command -v ip >/dev/null 2>&1 || return 1

    line="$(
        ip -4 route show default 2>/dev/null |
        while IFS= read -r rest; do
            iface="$(printf '%s\n' "$rest" | sed -n 's/.*[[:space:]]dev[[:space:]]\([^[:space:]]*\).*/\1/p')"
            [ -n "$iface" ] || continue
            is_vpn_interface_name "$iface" && continue
            printf '%s\n' "$rest"
            break
        done
    )"
    [ -n "$line" ] || return 1

    ACTIVE_INTERFACE="$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]dev[[:space:]]\([^[:space:]]*\).*/\1/p')"
    DEFAULT_GATEWAY="$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]via[[:space:]]\([^[:space:]]*\).*/\1/p')"
    LOCAL_IPV4="$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]src[[:space:]]\([^[:space:]]*\).*/\1/p')"

    if [ -z "$LOCAL_IPV4" ] && [ -n "$ACTIVE_INTERFACE" ]; then
        LOCAL_IPV4="$(
            ip -4 -o addr show dev "$ACTIVE_INTERFACE" scope global 2>/dev/null |
            awk '{split($4,a,"/"); print a[1]; exit}'
        )"
    fi

    case "$ACTIVE_INTERFACE" in
        wl*|wlan*) ACTIVE_INTERFACE_TYPE="WiFi" ;;
        en*|eth*)  ACTIVE_INTERFACE_TYPE="Wired" ;;
        *)         ACTIVE_INTERFACE_TYPE="Other" ;;
    esac

    if [ -n "$DEFAULT_GATEWAY" ]; then
        GATEWAY_MAC="$(
            ip neigh show "$DEFAULT_GATEWAY" 2>/dev/null |
            sed -n 's/.*[[:space:]]lladdr[[:space:]]\([0-9A-Fa-f:]*\).*/\1/p' |
            head -n 1
        )"
        GATEWAY_MAC="$(normalize_bssid "$GATEWAY_MAC")"
    fi

    # Keep v3.62 cross-platform behavior conservative: DHCP server and DNS suffix
    # are not inferred unless NetworkManager provides an explicit value.
    if command -v nmcli >/dev/null 2>&1 && [ -n "$ACTIVE_INTERFACE" ]; then
        DHCP_SERVER="$(
            nmcli -g DHCP4.OPTION device show "$ACTIVE_INTERFACE" 2>/dev/null |
            sed -n 's/.*dhcp_server_identifier[[:space:]=]\+\([^[:space:]]*\).*/\1/p' |
            head -n 1
        )"
        CONNECTION_DNS_SUFFIX="$(
            nmcli -g IP4.DOMAIN device show "$ACTIVE_INTERFACE" 2>/dev/null |
            head -n 1
        )"
    fi

    return 0
}

get_network_context_macos() {
    local raw
    [ -x /sbin/route ] || return 1
    raw="$WORK_DIR/macos-default-route.txt"

    /sbin/route -n get default > "$raw" 2>/dev/null || return 1
    DEFAULT_GATEWAY="$(sed -n 's/^[[:space:]]*gateway:[[:space:]]*//p' "$raw" | head -n 1)"
    ACTIVE_INTERFACE="$(sed -n 's/^[[:space:]]*interface:[[:space:]]*//p' "$raw" | head -n 1)"

    [ -n "$ACTIVE_INTERFACE" ] || return 1
    is_vpn_interface_name "$ACTIVE_INTERFACE" && return 1

    if [ -x /usr/sbin/ipconfig ]; then
        LOCAL_IPV4="$(/usr/sbin/ipconfig getifaddr "$ACTIVE_INTERFACE" 2>/dev/null || true)"
    fi

    if [ -n "$DEVICE_WIFI_INTERFACE" ] && [ "$ACTIVE_INTERFACE" = "$DEVICE_WIFI_INTERFACE" ]; then
        ACTIVE_INTERFACE_TYPE="WiFi"
    else
        case "$ACTIVE_INTERFACE" in
            en*) ACTIVE_INTERFACE_TYPE="Other" ;;
            *)   ACTIVE_INTERFACE_TYPE="Other" ;;
        esac
    fi

    if [ -n "$DEFAULT_GATEWAY" ] && [ -x /usr/sbin/arp ]; then
        GATEWAY_MAC="$(
            /usr/sbin/arp -n "$DEFAULT_GATEWAY" 2>/dev/null |
            grep -Eo '([0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2}' |
            head -n 1
        )"
        if [ -n "$GATEWAY_MAC" ]; then
            GATEWAY_MAC="$(
                printf '%s' "$GATEWAY_MAC" |
                awk -F: '{
                    for(i=1;i<=6;i++){
                        v=toupper($i)
                        if(length(v)==1)v="0"v
                        printf "%s%s", (i>1?":":""), v
                    }
                }'
            )"
        fi
    fi

    return 0
}

get_network_context() {
    if [ "$PLATFORM" = "Linux" ]; then
        get_network_context_linux || true
    else
        get_network_context_macos || true
    fi

    if [ -n "$GATEWAY_MAC" ]; then
        GATEWAY_VENDOR="$(get_gateway_vendor_by_mac "$GATEWAY_MAC" 2>/dev/null || true)"
    fi
}

NATPMP_STATUS="NotAttempted"
NATPMP_EXTERNAL_IP=""
PCP_STATUS="NotAttempted"
UPNP_STATUS="NotAttempted"
UPNP_LOCATION=""
UPNP_FRIENDLY_NAME=""
UPNP_MANUFACTURER=""
UPNP_MODEL=""
UPNP_MODEL_NUMBER=""
UPNP_DEVICE_TYPE=""
UPNP_UDN=""
UPNP_SERVICE_TYPE=""
UPNP_CONTROL_URL=""
UPNP_EXTERNAL_IP=""

probe_natpmp() {
    local response bytes b1 b2 b3 b4 b5 b6 b7 b8 ip1 ip2 ip3 ip4
    [ -n "$DEFAULT_GATEWAY" ] || return 1
    command -v nc >/dev/null 2>&1 || {
        NATPMP_STATUS="Unavailable"
        return 1
    }

    response="$WORK_DIR/natpmp.bin"
    : > "$response"
    printf '\x00\x00' |
        nc -u -w 1 "$DEFAULT_GATEWAY" 5351 > "$response" 2>/dev/null || true

    bytes="$(od -An -tu1 -N12 "$response" 2>/dev/null | tr '\n' ' ')"
    set -- $bytes
    [ "$#" -ge 12 ] || {
        NATPMP_STATUS="NoResponse"
        return 1
    }

    if [ "$1" -ne 0 ] || [ "$2" -ne 128 ] || [ "$3" -ne 0 ] || [ "$4" -ne 0 ]; then
        NATPMP_STATUS="UnsupportedOrError"
        return 1
    fi

    ip1="$9"
    shift 9
    ip2="$1"; ip3="$2"; ip4="$3"
    NATPMP_EXTERNAL_IP="${ip1}.${ip2}.${ip3}.${ip4}"
    NATPMP_STATUS="Supported"
    return 0
}

emit_ipv4_binary() {
    local ip="$1" a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    for a in "$a" "$b" "$c" "$d"; do
        printf "\\$(printf '%03o' "$a")"
    done
}

probe_pcp() {
    local request response bytes
    [ -n "$DEFAULT_GATEWAY" ] || return 1
    [ -n "$LOCAL_IPV4" ] || return 1
    command -v nc >/dev/null 2>&1 || {
        PCP_STATUS="Unavailable"
        return 1
    }

    request="$WORK_DIR/pcp-request.bin"
    response="$WORK_DIR/pcp-response.bin"

    {
        # Version=2, Opcode=ANNOUNCE, Lifetime=0, IPv4-mapped client address.
        printf '\x02\x00\x00\x00\x00\x00\x00\x00'
        printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff'
        emit_ipv4_binary "$LOCAL_IPV4"
    } > "$request"

    cat "$request" |
        nc -u -w 1 "$DEFAULT_GATEWAY" 5351 > "$response" 2>/dev/null || true

    bytes="$(od -An -tu1 -N4 "$response" 2>/dev/null | tr '\n' ' ')"
    set -- $bytes
    [ "$#" -ge 4 ] || {
        PCP_STATUS="NoResponse"
        return 1
    }

    if [ "$1" -eq 2 ] && [ "$2" -eq 128 ] && [ "$3" -eq 0 ] && [ "$4" -eq 0 ]; then
        PCP_STATUS="Supported"
        return 0
    fi

    PCP_STATUS="UnsupportedOrError"
    return 1
}

xml_tag_value() {
    local tag="$1" file="$2"
    tr '\r\n' '  ' < "$file" |
        grep -Eo "<${tag}[^>]*>[^<]*</${tag}>" |
        head -n 1 |
        sed -E "s#^<${tag}[^>]*>##" |
        sed -E "s#</${tag}>##" |
        sed 's/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g'
}

resolve_relative_url() {
    local base="$1" child="$2" origin dir
    case "$child" in
        http://*|https://*) printf '%s' "$child"; return ;;
    esac
    origin="$(printf '%s' "$base" | sed -E 's#^(https?://[^/]+).*$#\1#')"
    case "$child" in
        /*) printf '%s%s' "$origin" "$child" ;;
        *)
            dir="${base%/*}"
            printf '%s/%s' "$dir" "$child"
            ;;
    esac
}

probe_upnp() {
    local response st location description serviceblock control soap responsexml
    [ -n "$DEFAULT_GATEWAY" ] || return 1
    command -v nc >/dev/null 2>&1 || {
        UPNP_STATUS="Unavailable"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        UPNP_STATUS="CurlUnavailable"
        return 1
    }

    response="$WORK_DIR/ssdp-response.txt"
    : > "$response"

    for st in \
        'urn:schemas-upnp-org:device:InternetGatewayDevice:2' \
        'urn:schemas-upnp-org:device:InternetGatewayDevice:1'; do

        {
            printf 'M-SEARCH * HTTP/1.1\r\n'
            printf 'HOST: 239.255.255.250:1900\r\n'
            printf 'MAN: "ssdp:discover"\r\n'
            printf 'MX: 1\r\n'
            printf 'ST: %s\r\n\r\n' "$st"
        } |
            nc -u -w 2 239.255.255.250 1900 > "$response" 2>/dev/null || true

        location="$(
            awk 'tolower($0) ~ /^location:/ {
                    gsub("\r","")
                    sub(/^[^:]+:[[:space:]]*/,"")
                    print
                    exit
                 }' "$response"
        )"
        [ -n "$location" ] && break
    done

    [ -n "$location" ] || {
        UPNP_STATUS="NoResponse"
        return 1
    }

    UPNP_LOCATION="$location"
    description="$WORK_DIR/upnp-description.xml"
    curl -fsS --max-time 4 "$location" -o "$description" 2>/dev/null || {
        UPNP_STATUS="DescriptionFailed"
        return 1
    }

    UPNP_FRIENDLY_NAME="$(xml_tag_value friendlyName "$description")"
    UPNP_MANUFACTURER="$(xml_tag_value manufacturer "$description")"
    UPNP_MODEL="$(xml_tag_value modelName "$description")"
    UPNP_MODEL_NUMBER="$(xml_tag_value modelNumber "$description")"
    UPNP_DEVICE_TYPE="$(xml_tag_value deviceType "$description")"
    UPNP_UDN="$(xml_tag_value UDN "$description")"

    serviceblock="$(
        tr '\r\n' '  ' < "$description" |
        sed 's#</service>#</service>\
#g' |
        grep -E 'WAN(IP|PPP)Connection' |
        head -n 1
    )"

    if [ -n "$serviceblock" ]; then
        UPNP_SERVICE_TYPE="$(
            printf '%s' "$serviceblock" |
            sed -n 's:.*<serviceType>\([^<]*\)</serviceType>.*:\1:p'
        )"
        control="$(
            printf '%s' "$serviceblock" |
            sed -n 's:.*<controlURL>\([^<]*\)</controlURL>.*:\1:p'
        )"
        [ -n "$control" ] && UPNP_CONTROL_URL="$(resolve_relative_url "$location" "$control")"
    fi

    if [ -n "$UPNP_CONTROL_URL" ] && [ -n "$UPNP_SERVICE_TYPE" ]; then
        soap="$WORK_DIR/upnp-soap.xml"
        responsexml="$WORK_DIR/upnp-soap-response.xml"
        cat > "$soap" <<EOF
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetExternalIPAddress xmlns:u="$UPNP_SERVICE_TYPE"></u:GetExternalIPAddress>
  </s:Body>
</s:Envelope>
EOF
        curl -fsS --max-time 4 \
            -H 'Content-Type: text/xml; charset="utf-8"' \
            -H "SOAPAction: \"${UPNP_SERVICE_TYPE}#GetExternalIPAddress\"" \
            --data-binary @"$soap" \
            "$UPNP_CONTROL_URL" \
            -o "$responsexml" 2>/dev/null || true
        [ -s "$responsexml" ] &&
            UPNP_EXTERNAL_IP="$(xml_tag_value NewExternalIPAddress "$responsexml")"
    fi

    UPNP_STATUS="Supported"
    return 0
}

ROUTER_WEB_HINT=""
ROUTER_TLS_SUBJECT=""

probe_router_web_identity() {
    local headers body title server auth location
    [ -n "$DEFAULT_GATEWAY" ] || return
    command -v curl >/dev/null 2>&1 || return

    headers="$WORK_DIR/router-http-headers.txt"
    body="$WORK_DIR/router-http-body.txt"

    curl -sS --max-time 2 --connect-timeout 1 \
        -D "$headers" -o "$body" \
        "http://${DEFAULT_GATEWAY}/" 2>/dev/null || true

    server="$(awk 'tolower($0) ~ /^server:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
    auth="$(awk 'tolower($0) ~ /^www-authenticate:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
    location="$(awk 'tolower($0) ~ /^location:/ {gsub("\r",""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$headers")"
    title="$(
        head -c 4096 "$body" 2>/dev/null |
        tr '\r\n' '  ' |
        sed -n 's:.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)</[Tt][Ii][Tt][Ll][Ee]>.*:\1:p' |
        head -n 1
    )"

    ROUTER_WEB_HINT="$(
        printf '%s\n' \
            "${server:+Server=$server}" \
            "${auth:+Auth=$auth}" \
            "${location:+Location=$location}" \
            "${title:+Title=$title}" |
        awk 'NF {printf "%s%s", sep, $0; sep="; "}'
    )"

    if command -v openssl >/dev/null 2>&1; then
        ROUTER_TLS_SUBJECT="$(
            printf '' |
            openssl s_client -connect "${DEFAULT_GATEWAY}:443" -servername "$DEFAULT_GATEWAY" \
                -brief 2>/dev/null |
            sed -n 's/^Peer certificate: //p' |
            head -n 1
        )"
        if [ -z "$ROUTER_TLS_SUBJECT" ]; then
            ROUTER_TLS_SUBJECT="$(
                printf '' |
                openssl s_client -connect "${DEFAULT_GATEWAY}:443" -servername "$DEFAULT_GATEWAY" \
                    2>/dev/null |
                openssl x509 -noout -subject 2>/dev/null |
                sed 's/^subject=//'
            )"
        fi
    fi
}

ROUTER_FRIENDLY_NAME=""
ROUTER_MANUFACTURER=""
ROUTER_MANUFACTURER_RAW=""
ROUTER_MANUFACTURER_RESOLVED=""
ROUTER_PLATFORM=""
ROUTER_IDENTITY_CONFIDENCE="None"
ROUTER_IDENTITY_BASIS=""
ROUTER_MODEL=""
ROUTER_WAN_IP=""
ROUTER_WAN_SOURCE=""
ROUTER_WAN_ISP=""
ROUTER_WAN_GEO=""
ROUTER_WAN_SCOPE=""

normalize_router_identity() {
    local raw model gv
    raw="$(sanitize_field "$UPNP_MANUFACTURER")"
    model="$(sanitize_field "${UPNP_MODEL:-$UPNP_MODEL_NUMBER}")"
    gv="$(sanitize_field "$GATEWAY_VENDOR")"

    ROUTER_FRIENDLY_NAME="$UPNP_FRIENDLY_NAME"
    ROUTER_MANUFACTURER_RAW="$raw"
    ROUTER_MODEL="$model"

    case "$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')" in
        *CGM4331COM*)
            ROUTER_MANUFACTURER_RESOLVED="Vantiva"
            ROUTER_PLATFORM="XB7"
            ROUTER_IDENTITY_CONFIDENCE="High"
            ROUTER_IDENTITY_BASIS="UPnP model CGM4331COM"
            ;;
        *CGM4981COM*)
            ROUTER_MANUFACTURER_RESOLVED="Vantiva"
            ROUTER_PLATFORM="XB8"
            ROUTER_IDENTITY_CONFIDENCE="High"
            ROUTER_IDENTITY_BASIS="UPnP model CGM4981COM"
            ;;
        *CGM4140COM*)
            ROUTER_MANUFACTURER_RESOLVED="Vantiva"
            ROUTER_PLATFORM="XB6"
            ROUTER_IDENTITY_CONFIDENCE="High"
            ROUTER_IDENTITY_BASIS="UPnP model CGM4140COM"
            ;;
    esac

    if [ "$ROUTER_IDENTITY_CONFIDENCE" = "None" ] && [ -n "$gv" ]; then
        if printf '%s' "$gv" | grep -Eqi 'Vantiva|Technicolor'; then
            ROUTER_MANUFACTURER_RESOLVED="Vantiva"
            ROUTER_IDENTITY_CONFIDENCE="Medium"
            ROUTER_IDENTITY_BASIS="Gateway OUI vendor [$gv]"
        else
            ROUTER_MANUFACTURER_RESOLVED="$gv"
            ROUTER_IDENTITY_CONFIDENCE="Medium"
            ROUTER_IDENTITY_BASIS="Gateway OUI vendor"
        fi
    fi

    if [ "$ROUTER_IDENTITY_CONFIDENCE" = "None" ] && [ -n "$raw" ]; then
        ROUTER_MANUFACTURER_RESOLVED="$raw"
        ROUTER_IDENTITY_CONFIDENCE="Low"
        ROUTER_IDENTITY_BASIS="UPnP manufacturer"
    fi

    ROUTER_MANUFACTURER="$ROUTER_MANUFACTURER_RESOLVED"
    [ -n "$ROUTER_MANUFACTURER" ] || ROUTER_MANUFACTURER="$raw"
}

ipv4_scope() {
    local ip="$1" a b
    IFS=. read -r a b _ _ <<EOF
$ip
EOF
    case "$ip" in
        10.*|192.168.*) printf 'RFC1918'; return ;;
        127.*) printf 'Loopback'; return ;;
        169.254.*) printf 'LinkLocal'; return ;;
    esac
    if [ "$a" = "172" ] && [ "${b:-0}" -ge 16 ] 2>/dev/null && [ "${b:-0}" -le 31 ] 2>/dev/null; then
        printf 'RFC1918'; return
    fi
    if [ "$a" = "100" ] && [ "${b:-0}" -ge 64 ] 2>/dev/null && [ "${b:-0}" -le 127 ] 2>/dev/null; then
        printf 'CGNAT'; return
    fi
    case "$ip" in
        0.*|224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|236.*|237.*|238.*|239.*|240.*|241.*|242.*|243.*|244.*|245.*|246.*|247.*|248.*|249.*|250.*|251.*|252.*|253.*|254.*|255.*)
            printf 'Special'; return ;;
    esac
    printf 'Public'
}

discover_router_wan() {
    probe_natpmp || true
    probe_pcp || true
    probe_upnp || true

    if [ -n "$UPNP_EXTERNAL_IP" ]; then
        ROUTER_WAN_IP="$UPNP_EXTERNAL_IP"
        ROUTER_WAN_SOURCE="UPnP"
    elif [ -n "$NATPMP_EXTERNAL_IP" ]; then
        ROUTER_WAN_IP="$NATPMP_EXTERNAL_IP"
        ROUTER_WAN_SOURCE="NAT-PMP"
    fi

    [ -n "$ROUTER_WAN_IP" ] && ROUTER_WAN_SCOPE="$(ipv4_scope "$ROUTER_WAN_IP")"

    normalize_router_identity

    if [ -z "$UPNP_MANUFACTURER" ] || [ -z "$UPNP_MODEL" ]; then
        probe_router_web_identity
    fi
}

IP_GEO_CACHE_FILE=""

get_ip_geo_line() {
    local ip="$1" response line
    [ -n "$IP_GEO_CACHE_FILE" ] || IP_GEO_CACHE_FILE="$WORK_DIR/ip-geo.tsv"

    line="$(awk -F '|' -v ip="$ip" '$1==ip {print; exit}' "$IP_GEO_CACHE_FILE" 2>/dev/null || true)"
    if [ -n "$line" ]; then
        printf '%s' "$line"
        return 0
    fi

    if [ "$ip" = "1.1.1.1" ]; then
        line="1.1.1.1|||||Cloudflare|Cloudflare|13335"
        printf '%s\n' "$line" >> "$IP_GEO_CACHE_FILE"
        printf '%s' "$line"
        return 0
    fi

    response="$WORK_DIR/ipgeo-$(printf '%s' "$ip" | tr '.' '_').json"
    fetch_url "https://ipwho.is/${ip}" "$response" >/dev/null 2>&1 || return 1
    grep -Eq '"success"[[:space:]]*:[[:space:]]*false' "$response" && return 1

    line="$(printf '%s|%s|%s|%s|%s|%s|%s|%s' \
        "$ip" \
        "$(json_number latitude "$response")" \
        "$(json_number longitude "$response")" \
        "$(sanitize_field "$(json_string city "$response")")" \
        "$(sanitize_field "$(json_string region "$response")")" \
        "$(sanitize_field "$(json_string country "$response")")" \
        "$(sanitize_field "$(json_string isp "$response")")" \
        "$(json_number asn "$response")")"
    printf '%s\n' "$line" >> "$IP_GEO_CACHE_FILE"
    printf '%s' "$line"
}

TRACE_FILE=""
TRACE_GEO=""

collect_route_trace() {
    local raw cmd line hop ip scope geo city region country isp asn hopn
    TRACE_FILE="$WORK_DIR/trace.tsv"
    : > "$TRACE_FILE"
    raw="$WORK_DIR/traceroute.txt"

    if [ "$PLATFORM" = "Linux" ]; then
        command -v traceroute >/dev/null 2>&1 || return 1
        run_with_timeout 12 "$raw" "$WORK_DIR/traceroute.err" \
            traceroute -4 -n -m 8 -w 1 1.1.1 || true
    else
        [ -x /usr/sbin/traceroute ] || return 1
        run_with_timeout 12 "$raw" "$WORK_DIR/traceroute.err" \
            /usr/sbin/traceroute -n -m 8 -w 1 1.1.1 || true
    fi

    hopn=0
    while IFS= read -r line; do
        printf '%s\n' "$line" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]' || continue
        hopn="$(printf '%s\n' "$line" | awk '{print $1}')"
        ip="$(
            printf '%s\n' "$line" |
            grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' |
            head -n 1
        )"
        [ -n "$ip" ] || continue
        scope="$(ipv4_scope "$ip")"
        city=""; region=""; country=""; isp=""; asn=""

        if [ "$scope" = "Public" ]; then
            geo="$(get_ip_geo_line "$ip" || true)"
            if [ -n "$geo" ]; then
                IFS='|' read -r _ _ _ city region country isp asn <<EOF
$geo
EOF
            fi
        fi

        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$hopn" "$ip" "$scope" "$city" "$region" "$country" "$isp" "$asn" >> "$TRACE_FILE"
    done < "$raw"

    TRACE_GEO="$(
        awk -F '|' '
            BEGIN {
                printf "%-4s %-15s %-10s %-18s %-18s %-9s %-26s %-8s\n",
                    "Hop","IP","Scope","City","Region","Country","ISP","ASN"
            }
            {
                printf "%-4s %-15s %-10s %-18.18s %-18.18s %-9.9s %-26.26s %-8s\n",
                    $1,$2,$3,$4,$5,$6,$7,$8
            }
        ' "$TRACE_FILE"
    )"

    [ -s "$TRACE_FILE" ]
}

ROUTER_VPN_SUSPECTED="Unknown"
ROUTER_VPN_CONFIDENCE="None"
ROUTER_VPN_EVIDENCE=""

provider_looks_hosting_or_vpn() {
    printf '%s' "$1" |
        grep -Eqi 'M247|DataCamp|Packethub|Mullvad|NordVPN|Proton|Surfshark|ExpressVPN|Private Internet Access|Windscribe|CyberGhost|IPVanish|Leaseweb|OVH|Hetzner|Vultr|DigitalOcean|Choopa|Quadranet|Psychz'
}

provider_matches_observed() {
    local isp="$1" asn="$2"

    if [ -n "$asn" ] && [ -n "$PUBLIC_IP_ASN" ] && [ "$asn" = "$PUBLIC_IP_ASN" ]; then
        return 0
    fi

    if [ -n "$isp" ] && [ -n "$PUBLIC_IP_ISP" ]; then
        awk -v a="$isp" -v b="$PUBLIC_IP_ISP" 'BEGIN {
            a=tolower(a); b=tolower(b)
            exit (index(a,b)>0 || index(b,a)>0) ? 0 : 1
        }'
        return $?
    fi

    return 1
}

assess_router_vpn() {
    local first_public first_scope first_isp first_asn overlay=0 provider_hint=0
    local initial_matches=0 first_provider_match=0 observed_provider wan_geo wan_isp wan_asn transit

    if [ -z "$ROUTER_WAN_IP" ]; then
        if [ "$VPN_ESTABLISHED_IDENTITY" != "None" ] && [ -n "$VPN_ESTABLISHED_IDENTITY" ]; then
            ROUTER_VPN_SUSPECTED="Indeterminate"
            ROUTER_VPN_CONFIDENCE="Low"
            ROUTER_VPN_EVIDENCE="An endpoint VPN/tunnel is established, so router/upstream VPN attribution cannot be separated reliably from endpoint tunneling."
            return
        fi

        if [ -z "$PUBLIC_IP" ]; then
            ROUTER_VPN_SUSPECTED="Unknown"
            ROUTER_VPN_CONFIDENCE="None"
            ROUTER_VPN_EVIDENCE="Observed public egress is unavailable; router/upstream VPN attribution cannot be evaluated."
            return
        fi
    fi

    if [ -n "$ROUTER_WAN_IP" ]; then
        case "$ROUTER_WAN_SCOPE" in
            RFC1918|CGNAT|LinkLocal|Special)
                ROUTER_VPN_SUSPECTED="Indeterminate"
                ROUTER_VPN_CONFIDENCE="Low"
                ROUTER_VPN_EVIDENCE="Router-exposed WAN address [$ROUTER_WAN_IP] is $ROUTER_WAN_SCOPE, so an upstream NAT/CGNAT layer prevents direct router-egress comparison."
                return
                ;;
            Public)
                if [ -z "$PUBLIC_IP" ]; then
                    ROUTER_VPN_SUSPECTED="Unknown"
                    ROUTER_VPN_CONFIDENCE="None"
                    ROUTER_VPN_EVIDENCE="Router exposed public WAN [$ROUTER_WAN_IP], but observed public egress is unavailable."
                    return
                fi

                if [ "$ROUTER_WAN_IP" = "$PUBLIC_IP" ]; then
                    ROUTER_VPN_SUSPECTED="False"
                    ROUTER_VPN_CONFIDENCE="High"
                    ROUTER_VPN_EVIDENCE="Router WAN [$ROUTER_WAN_IP] exactly matches observed public egress."
                    return
                fi

                if [ "$VPN_ESTABLISHED_IDENTITY" != "None" ] && [ -n "$VPN_ESTABLISHED_IDENTITY" ]; then
                    ROUTER_VPN_SUSPECTED="Indeterminate"
                    ROUTER_VPN_CONFIDENCE="Low"
                    ROUTER_VPN_EVIDENCE="Router WAN [$ROUTER_WAN_IP] differs from observed egress [$PUBLIC_IP], but an endpoint VPN/tunnel is established and can fully explain that mismatch."
                    return
                fi

                wan_geo="$(get_ip_geo_line "$ROUTER_WAN_IP" || true)"
                if [ -n "$wan_geo" ]; then
                    IFS='|' read -r _ _ _ _ _ _ wan_isp wan_asn <<EOF
$wan_geo
EOF
                    ROUTER_WAN_ISP="$wan_isp"
                    ROUTER_WAN_GEO="$(printf '%s' "$wan_geo" | awk -F '|' '{printf "%s, %s, %s", $4,$5,$6}')"
                fi

                if { [ -n "$wan_asn" ] && [ -n "$PUBLIC_IP_ASN" ] && [ "$wan_asn" != "$PUBLIC_IP_ASN" ]; } ||
                   { [ -n "$wan_isp" ] && [ -n "$PUBLIC_IP_ISP" ] &&
                     ! awk -v a="$wan_isp" -v b="$PUBLIC_IP_ISP" 'BEGIN {
                         a=tolower(a); b=tolower(b);
                         exit (index(a,b)>0 || index(b,a)>0) ? 0 : 1
                     }'; }; then
                    ROUTER_VPN_SUSPECTED="True"
                    ROUTER_VPN_CONFIDENCE="High"
                    ROUTER_VPN_EVIDENCE="Router WAN [$ROUTER_WAN_IP] differs from observed egress [$PUBLIC_IP], with differing ISP/ASN evidence."
                else
                    ROUTER_VPN_SUSPECTED="Possible"
                    ROUTER_VPN_CONFIDENCE="Medium"
                    ROUTER_VPN_EVIDENCE="Router WAN [$ROUTER_WAN_IP] differs from observed egress [$PUBLIC_IP], but provider attribution is not decisively different."
                fi
                return
                ;;
        esac
    fi

    collect_route_trace || true
    [ -s "$TRACE_FILE" ] || {
        ROUTER_VPN_SUSPECTED="Unknown"
        ROUTER_VPN_CONFIDENCE="Low"
        ROUTER_VPN_EVIDENCE="Router did not expose a WAN address and route trace evidence was unavailable."
        return
    }

    # A private/CGNAT hop after the local gateway indicates an upstream overlay/NAT layer.
    if awk -F '|' 'NR>1 && ($3=="RFC1918" || $3=="CGNAT") {found=1} END{exit !found}' "$TRACE_FILE"; then
        overlay=1
    fi

    first_public="$(awk -F '|' '$3=="Public" && $2!="1.1.1.1" {print; exit}' "$TRACE_FILE")"
    if [ -n "$first_public" ]; then
        IFS='|' read -r _ _ first_scope _ _ _ first_isp first_asn <<EOF
$first_public
EOF
        if provider_matches_observed "$first_isp" "$first_asn"; then
            first_provider_match=1
        fi
    fi

    while IFS='|' read -r _ _ _ _ _ _ first_isp first_asn; do
        if provider_matches_observed "$first_isp" "$first_asn"; then
            initial_matches=$((initial_matches + 1))
        fi
    done <<EOF
$(awk -F '|' '$3=="Public" && $2!="1.1.1.1" {print; n++; if(n>=2) exit}' "$TRACE_FILE")
EOF

    observed_provider="${PUBLIC_IP_ISP} ${PUBLIC_IP_ORG}"
    if provider_looks_hosting_or_vpn "$observed_provider"; then
        provider_hint=1
    fi

    if [ "$overlay" -eq 1 ] && [ -n "$first_public" ] && [ "$provider_hint" -eq 1 ]; then
        ROUTER_VPN_SUSPECTED="True"
        ROUTER_VPN_CONFIDENCE="High"
        ROUTER_VPN_EVIDENCE="No router WAN was exposed; route trace shows an upstream private/CGNAT layer and observed egress provider resembles hosting/VPN infrastructure."
    elif [ "$overlay" -eq 1 ] && [ -n "$first_public" ]; then
        ROUTER_VPN_SUSPECTED="Possible"
        ROUTER_VPN_CONFIDENCE="Medium"
        ROUTER_VPN_EVIDENCE="No router WAN was exposed; route trace shows an upstream private/CGNAT layer before public transit."
    elif [ "$overlay" -eq 0 ] && [ "$first_provider_match" -eq 1 ] &&
         [ "$provider_hint" -eq 0 ] && [ "$initial_matches" -ge 2 ]; then
        ROUTER_VPN_SUSPECTED="False"
        ROUTER_VPN_CONFIDENCE="High"
        ROUTER_VPN_EVIDENCE="Direct ISP route evidence: no upstream RFC1918/CGNAT overlay was observed and the first two public transit hops are consistent with observed egress attribution."
    elif [ "$overlay" -eq 0 ] && [ "$first_provider_match" -eq 1 ] &&
         [ "$provider_hint" -eq 0 ]; then
        ROUTER_VPN_SUSPECTED="False"
        ROUTER_VPN_CONFIDENCE="Medium"
        ROUTER_VPN_EVIDENCE="Direct ISP route evidence: no upstream RFC1918/CGNAT overlay was observed and the first public transit hop is consistent with observed egress attribution."
    else
        ROUTER_VPN_SUSPECTED="Unknown"
        ROUTER_VPN_CONFIDENCE="Low"
        ROUTER_VPN_EVIDENCE="Route evidence was insufficient to positively or negatively attribute router/upstream VPN egress."
    fi
}

VPN_DETECTED_FILE=""
VPN_ESTABLISHED_FILE=""
VPN_DETECTED_IDENTITY="None"
VPN_ESTABLISHED_IDENTITY="None"
VPN_DETECTED_EVIDENCE=""
VPN_ESTABLISHED_EVIDENCE=""

vpn_identity_from_text() {
    local text="$1"
    if printf '%s' "$text" | grep -Eqi 'anyconnect|cisco secure client'; then printf 'Cisco AnyConnect'
    elif printf '%s' "$text" | grep -Eqi 'globalprotect|palo alto'; then printf 'Palo Alto GlobalProtect'
    elif printf '%s' "$text" | grep -Eqi 'zscaler'; then printf 'Zscaler'
    elif printf '%s' "$text" | grep -Eqi 'forti(client|net)|fortinet'; then printf 'Fortinet FortiClient'
    elif printf '%s' "$text" | grep -Eqi 'wireguard|\bwg[0-9]*\b'; then printf 'WireGuard'
    elif printf '%s' "$text" | grep -Eqi 'openvpn'; then printf 'OpenVPN'
    elif printf '%s' "$text" | grep -Eqi 'nordlynx|nordvpn'; then printf 'NordVPN'
    elif printf '%s' "$text" | grep -Eqi 'tailscale'; then printf 'Tailscale'
    elif printf '%s' "$text" | grep -Eqi 'zerotier|\bzt[a-z0-9]+'; then printf 'ZeroTier'
    elif printf '%s' "$text" | grep -Eqi 'check[[:space:]-]*point'; then printf 'Check Point VPN'
    elif printf '%s' "$text" | grep -Eqi 'ivanti|pulse secure'; then printf 'Ivanti/Pulse Secure'
    elif printf '%s' "$text" | grep -Eqi 'juniper'; then printf 'Juniper VPN'
    elif printf '%s' "$text" | grep -Eqi 'sonicwall|netextender'; then printf 'SonicWall NetExtender'
    elif printf '%s' "$text" | grep -Eqi 'big-?ip|f5'; then printf 'F5 BIG-IP Edge'
    elif printf '%s' "$text" | grep -Eqi 'cloudflare.*warp|warp'; then printf 'Cloudflare WARP'
    else printf 'VPN/Tunnel'
    fi
}

collect_vpn_evidence_v2() {
    local line id
    VPN_DETECTED_FILE="$WORK_DIR/vpn-detected.txt"
    VPN_ESTABLISHED_FILE="$WORK_DIR/vpn-established.txt"
    : > "$VPN_DETECTED_FILE"
    : > "$VPN_ESTABLISHED_FILE"

    if [ "$PLATFORM" = "Linux" ]; then
        if command -v ip >/dev/null 2>&1; then
            ip -o link show 2>/dev/null |
                grep -Ei '\b(tun[0-9]*|tap[0-9]*|wg[0-9]*|nordlynx|tailscale[0-9]*|zt[a-z0-9]+|vpn)\b|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler' \
                >> "$VPN_DETECTED_FILE" || true
            ip -o link show up 2>/dev/null |
                grep -Ei '\b(tun[0-9]*|tap[0-9]*|wg[0-9]*|nordlynx|tailscale[0-9]*|zt[a-z0-9]+|vpn)\b|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler' \
                >> "$VPN_ESTABLISHED_FILE" || true
        fi
        if command -v nmcli >/dev/null 2>&1; then
            nmcli -t --escape no -f NAME,TYPE,DEVICE connection show 2>/dev/null |
                grep -Ei ':vpn:|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler|nord|tailscale|zerotier' \
                >> "$VPN_DETECTED_FILE" || true
            nmcli -t --escape no -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
                grep -Ei ':vpn:|wireguard|openvpn|globalprotect|anyconnect|forti|zscaler|nord|tailscale|zerotier' \
                >> "$VPN_ESTABLISHED_FILE" || true
        fi
    else
        if [ -x /sbin/ifconfig ]; then
            /sbin/ifconfig -a 2>/dev/null |
                grep -E '^(utun[0-9]+|ppp[0-9]+|tun[0-9]+|tap[0-9]+|wg[0-9]+):' \
                >> "$VPN_DETECTED_FILE" || true
            /sbin/ifconfig 2>/dev/null |
                grep -E '^(utun[0-9]+|ppp[0-9]+|tun[0-9]+|tap[0-9]+|wg[0-9]+):' \
                >> "$VPN_ESTABLISHED_FILE" || true
        fi
        if [ -x /usr/sbin/scutil ]; then
            /usr/sbin/scutil --nc list 2>/dev/null |
                grep -Ei '\((Connected|Disconnected|Connecting|Disconnecting)\)' \
                >> "$VPN_DETECTED_FILE" || true
            /usr/sbin/scutil --nc list 2>/dev/null |
                grep -Ei '\(Connected\)' \
                >> "$VPN_ESTABLISHED_FILE" || true
        fi
    fi

    sort -u "$VPN_DETECTED_FILE" -o "$VPN_DETECTED_FILE" 2>/dev/null || true
    sort -u "$VPN_ESTABLISHED_FILE" -o "$VPN_ESTABLISHED_FILE" 2>/dev/null || true

    if [ -s "$VPN_DETECTED_FILE" ]; then
        VPN_DETECTED_EVIDENCE="$(cat "$VPN_DETECTED_FILE")"
        VPN_DETECTED_IDENTITY="$(
            while IFS= read -r line; do
                printf '%s\n' "$(vpn_identity_from_text "$line")"
            done < "$VPN_DETECTED_FILE" |
            awk 'NF && !seen[$0]++ {printf "%s%s", sep, $0; sep="; "}'
        )"
    fi

    if [ -s "$VPN_ESTABLISHED_FILE" ]; then
        VPN_ESTABLISHED_EVIDENCE="$(cat "$VPN_ESTABLISHED_FILE")"
        VPN_ESTABLISHED_IDENTITY="$(
            while IFS= read -r line; do
                printf '%s\n' "$(vpn_identity_from_text "$line")"
            done < "$VPN_ESTABLISHED_FILE" |
            awk 'NF && !seen[$0]++ {printf "%s%s", sep, $0; sep="; "}'
        )"
    fi
}

format_established_vpn_tunnel() {
    if [ "$VPN_ESTABLISHED_IDENTITY" = "None" ] || [ -z "$VPN_ESTABLISHED_IDENTITY" ]; then
        printf 'None'
    else
        printf '%s' "$VPN_ESTABLISHED_IDENTITY" |
        awk -F '; ' '{
            for(i=1;i<=NF;i++) printf "%s%s = No tunnel IPv4 assigned", (i>1?", ":""), $i
        }'
    fi
}

LOCAL_CITY=""
LOCAL_PROVINCE=""
LOCAL_COUNTRY=""
LOCAL_CITY_MATCH_TYPE="Unmatched"
LOCAL_CITY_SOURCE="NotReported"
LOCAL_CITY_INSIDE_RANGE="false"
LOCAL_CITY_CENTER_DISTANCE=""
LOCAL_CITY_CENTER=""
LOCAL_CITY_LAT_RANGE=""
LOCAL_CITY_LON_RANGE=""

resolve_local_city() {
    local lat="$1" lon="$2" cities evaluated selected distance inside
    local city prov clat clon minlat maxlat minlon maxlon

    # Match the v3.62 Canadian-only envelope before considering city buckets.
    if ! awk -v lat="$lat" -v lon="$lon" \
        'BEGIN {exit !(lat>=41.0 && lat<=84.0 && lon>=-142.0 && lon<=-52.0)}'; then
        return 1
    fi

    cities="$WORK_DIR/canadian-cities.tsv"
    evaluated="$WORK_DIR/canadian-cities-evaluated.tsv"

    cat > "$cities" <<'EOF'
St. John's|NL|47.5615|-52.7126|47.48|47.66|-52.85|-52.62
Charlottetown|PE|46.2382|-63.1311|46.20|46.30|-63.20|-63.05
Halifax|NS|44.6488|-63.5752|44.55|44.75|-63.75|-63.45
Moncton|NB|46.0878|-64.7782|46.00|46.18|-64.90|-64.68
Fredericton|NB|45.9636|-66.6431|45.90|46.05|-66.75|-66.55
Quebec City|QC|46.8139|-71.2080|46.72|46.92|-71.40|-71.10
Montreal|QC|45.5019|-73.5674|45.40|45.70|-73.95|-73.45
Ottawa|ON|45.4215|-75.6972|45.25|45.55|-75.95|-75.45
Kingston|ON|44.2312|-76.4860|44.15|44.32|-76.65|-76.35
Toronto|ON|43.6532|-79.3832|43.55|43.85|-79.65|-79.10
Hamilton|ON|43.2557|-79.8711|43.15|43.35|-80.05|-79.70
London|ON|42.9849|-81.2453|42.90|43.10|-81.40|-81.10
Windsor|ON|42.3149|-83.0364|42.22|42.38|-83.15|-82.90
Thunder Bay|ON|48.3809|-89.2477|48.25|48.50|-89.45|-89.05
Winnipeg|MB|49.8951|-97.1384|49.75|50.05|-97.35|-96.95
Regina|SK|50.4452|-104.6189|50.35|50.55|-104.75|-104.45
Saskatoon|SK|52.1579|-106.6702|52.05|52.25|-106.85|-106.50
Edmonton|AB|53.5461|-113.4938|53.40|53.72|-113.75|-113.25
Calgary|AB|51.0447|-114.0719|50.85|51.20|-114.30|-113.85
Kelowna|BC|49.8880|-119.4960|49.75|50.05|-119.70|-119.30
Vancouver|BC|49.2827|-123.1207|49.18|49.38|-123.30|-122.95
Victoria|BC|48.4284|-123.3656|48.35|48.52|-123.50|-123.25
EOF

    : > "$evaluated"
    while IFS='|' read -r city prov clat clon minlat maxlat minlon maxlon; do
        inside="$(
            awk -v lat="$lat" -v lon="$lon" \
                -v a="$minlat" -v b="$maxlat" -v c="$minlon" -v d="$maxlon" \
                'BEGIN {print (lat>=a && lat<=b && lon>=c && lon<=d) ? "true" : "false"}'
        )"
        distance="$(distance_km "$lat" "$lon" "$clat" "$clon")"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$city" "$prov" "$clat" "$clon" "$minlat" "$maxlat" "$minlon" "$maxlon" \
            "$inside" "$distance" >> "$evaluated"
    done < "$cities"

    selected="$(
        awk -F '|' '$9=="true" {print $10 "\t" $0}' "$evaluated" |
        sort -n -k1,1 |
        head -n 1 |
        cut -f2-
    )"

    if [ -n "$selected" ]; then
        LOCAL_CITY_MATCH_TYPE="InsideRange"
    else
        selected="$(
            awk -F '|' '{print $10 "\t" $0}' "$evaluated" |
            sort -n -k1,1 |
            head -n 1 |
            cut -f2-
        )"
        [ -n "$selected" ] || return 1
        distance="$(printf '%s' "$selected" | awk -F '|' '{print $10}')"
        number_le "$distance" "200" || return 1
        LOCAL_CITY_MATCH_TYPE="NearestCenter"
    fi

    IFS='|' read -r \
        city prov clat clon minlat maxlat minlon maxlon inside distance <<EOF
$selected
EOF

    LOCAL_CITY="$city"
    LOCAL_PROVINCE="$prov"
    LOCAL_COUNTRY="Canada"
    LOCAL_CITY_SOURCE="CanadianEmbeddedCityTable"
    LOCAL_CITY_INSIDE_RANGE="$inside"
    LOCAL_CITY_CENTER_DISTANCE="$distance"
    LOCAL_CITY_CENTER="${clat},${clon}"
    LOCAL_CITY_LAT_RANGE="${minlat}..${maxlat}"
    LOCAL_CITY_LON_RANGE="${minlon}..${maxlon}"
    return 0
}

BLUETOOTH_SCAN_STATUS=""
BLUETOOTH_SCAN_DETAIL=""
BLUETOOTH_EVIDENCE=""

set_bluetooth_contract_status() {
    [ "$BLUETOOTH_EXPLICIT" -eq 1 ] || return
    if [ "$SKIP_BLUETOOTH" -eq 1 ]; then
        BLUETOOTH_SCAN_STATUS="SkippedByParameter"
        BLUETOOTH_SCAN_DETAIL="Bluetooth scan skipped by parameter."
    else
        BLUETOOTH_SCAN_STATUS="UnsupportedPlatform"
        BLUETOOTH_SCAN_DETAIL="Bluetooth LE advertisement scanning in Get-DeviceCoords-v3.62 is implemented for Windows only; macOS/Linux parity intentionally reports UnsupportedPlatform."
    fi
}

make_map_uri() {
    local lat="$1" lon="$2"
    [ -n "$lat" ] && [ -n "$lon" ] &&
        printf 'https://www.google.com/maps/search/?api=1&query=%s,%s' "$lat" "$lon"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

verbose "Get-DeviceCoords Unix v$SCRIPT_VERSION aligned to Windows v$WINDOWS_REFERENCE_VERSION; platform=$PLATFORM; bash=$BASH_VERSION."

init_persistent_cache
get_device_profile
if [ "$PLATFORM" = "Linux" ]; then
    if find_geoclue_helper >/dev/null 2>&1; then
        LINUX_NATIVE_PROVIDER="GeoClue"
    else
        LINUX_NATIVE_PROVIDER="GeoClueUnavailable"
    fi
fi
collect_wifi
collect_current_wifi
set_bluetooth_contract_status

NEARBY_WIFI_COUNT="$(wifi_count)"
GOOGLE_USABLE_COUNT="$(google_usable_count)"
STRONGEST_LINE="$(get_strongest_usable_line)"

STRONGEST_BSSID=""
STRONGEST_SSID=""
STRONGEST_SIGNAL_PCT=""
STRONGEST_SIGNAL_DBM=""
STRONGEST_CHANNEL=""

if [ -n "$STRONGEST_LINE" ]; then
    IFS='|' read -r \
        STRONGEST_BSSID STRONGEST_SSID STRONGEST_SIGNAL_PCT \
        STRONGEST_SIGNAL_DBM STRONGEST_CHANNEL _ _ _ <<EOF
$STRONGEST_LINE
EOF
fi

verbose "Wi-Fi collector=$WIFI_COLLECTOR; currentStatus=$CURRENT_WIFI_STATUS; nearbyBssids=$NEARBY_WIFI_COUNT; googleUsable=$GOOGLE_USABLE_COUNT."

if [ "$GOOGLE_USABLE_COUNT" -eq 0 ] && [ "$NEARBY_WIFI_COUNT" -gt 0 ]; then
    rejection_summary="$(awk -F '|' '$7!="true" {c[$8]++} END {for (r in c) printf "%s%s=%d", sep, r, c[r]; sep=", "}' "$WIFI_FILE")"
    add_note "Wi-Fi was detected, but none of the observed BSSIDs are Google-usable. Rejection summary: $rejection_summary."
fi

if [ -n "$GOOGLE_API_KEY" ] && [ -n "$STRONGEST_BSSID" ]; then
    if [ -n "$STRONGEST_SIGNAL_DBM" ]; then
        signal_description="${STRONGEST_SIGNAL_DBM} dBm"
    elif [ -n "$STRONGEST_SIGNAL_PCT" ]; then
        signal_description="${STRONGEST_SIGNAL_PCT}%"
    else
        signal_description="<unknown>"
    fi

    [ -n "$STRONGEST_SSID" ] || STRONGEST_SSID="<unknown SSID>"
    add_note "Strongest Google-usable BSSID is [$STRONGEST_BSSID] ($STRONGEST_SSID) at $signal_description."
fi

# Applicable macOS/Linux physical-location trust order from the v3.62 contract:
# Known Wi-Fi -> Google Wi-Fi -> WiGLE -> native OS provider -> public IP fallback.
if resolve_known_wifi; then
    [ -n "$GOOGLE_API_KEY" ] && GOOGLE_WIFI_RESOLVER_STATUS="SkippedHigherPriorityLocationResolved"
    if [ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ]; then
        WIGLE_WIFI_RESOLVER_STATUS="SkippedHigherPriorityLocationResolved"
    fi
else
    resolve_google_wifi || true
fi

if [ -n "$PHYSICAL_METHOD" ]; then
    if [ "$PHYSICAL_METHOD" = "GoogleWiFi" ] &&
       [ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ]; then
        WIGLE_WIFI_RESOLVER_STATUS="SkippedHigherPriorityLocationResolved"
    fi
elif resolve_wigle_wifi; then
    :
else
    resolve_native_location || true
fi

if [ -n "$PHYSICAL_METHOD" ] &&
   [ "$PHYSICAL_METHOD" != "KnownWiFi" ] &&
   [ "$PHYSICAL_METHOD" != "GoogleWiFi" ] &&
   [ "$PHYSICAL_METHOD" != "WiGLEWiFi" ]; then

    if [ -n "$PHYSICAL_ACCURACY" ] && number_le "$PHYSICAL_ACCURACY" "5000"; then
        PHYSICAL_VPN_RESISTANT="true"
    else
        PHYSICAL_VPN_RESISTANT=""
        add_note "Native OS location returned coarse/unknown accuracy; its underlying source cannot be proven from this result."
    fi
fi

if [ -z "$GOOGLE_API_KEY" ] && [ "$NEARBY_WIFI_COUNT" -gt 0 ]; then
    add_note "Wi-Fi evidence is present. Google Wi-Fi geolocation was skipped because no API key is configured; other resolvers continued as needed."
fi

if [ -n "$GOOGLE_API_KEY" ] && [ "$GOOGLE_USABLE_COUNT" -lt 2 ]; then
    add_note "Google Wi-Fi geolocation requires at least two usable universally administered BSSIDs; $GOOGLE_USABLE_COUNT were available."
fi

if [ "$PLATFORM" = "Linux" ] &&
   [ "$LINUX_NATIVE_PROVIDER" = "GeoClueUnavailable" ]; then
    add_note "GeoClue where-am-i helper was not found. Linux native location was unavailable; Wi-Fi resolvers and public-IP fallback remain available."
fi

if [ "$PLATFORM" = "macOS" ] && [ "$NEARBY_WIFI_COUNT" -eq 0 ]; then
    add_note "macOS may restrict SSID/BSSID access until Location Services permission is granted to the process providing Wi-Fi information."
fi

# Public-IP evidence is collected even when a stronger physical location exists,
# because v3.62 uses it for physical-vs-egress and router/upstream assessment.
resolve_public_ip || true

get_network_context
collect_vpn_evidence_v2
discover_router_wan

# Enrich a public router WAN address independently of the router-VPN decision.
ROUTER_WAN_LAT=""
ROUTER_WAN_LON=""
if [ -n "$ROUTER_WAN_IP" ] && [ "$ROUTER_WAN_SCOPE" = "Public" ]; then
    router_wan_geo_line="$(get_ip_geo_line "$ROUTER_WAN_IP" || true)"
    if [ -n "$router_wan_geo_line" ]; then
        IFS='|' read -r \
            _ ROUTER_WAN_LAT ROUTER_WAN_LON \
            router_city router_region router_country \
            ROUTER_WAN_ISP router_asn <<EOF
$router_wan_geo_line
EOF
        ROUTER_WAN_GEO="$(
            printf '%s, %s, %s' "$router_city" "$router_region" "$router_country" |
            sed 's/^[, ]*//;s/[, ]*$//'
        )"
    fi
fi

assess_router_vpn

SELECTED_METHOD="$PHYSICAL_METHOD"
SELECTED_LAT="$PHYSICAL_LAT"
SELECTED_LON="$PHYSICAL_LON"
SELECTED_ACCURACY="$PHYSICAL_ACCURACY"
SELECTED_SITE="$PHYSICAL_SITE"
SELECTED_VPN_RESISTANT="$PHYSICAL_VPN_RESISTANT"
SELECTED_DETAIL="$PHYSICAL_DETAIL"

if [ -z "$SELECTED_METHOD" ] && [ -n "$PUBLIC_IP_LAT" ] && [ -n "$PUBLIC_IP_LON" ]; then
    SELECTED_METHOD="PublicIP"
    SELECTED_LAT="$PUBLIC_IP_LAT"
    SELECTED_LON="$PUBLIC_IP_LON"
    SELECTED_ACCURACY=""
    SELECTED_SITE=""
    SELECTED_VPN_RESISTANT="false"
    SELECTED_DETAIL="Fallback only; coordinates represent Internet egress and may be a VPN/proxy endpoint"

    if [ "$NEARBY_WIFI_COUNT" -gt 0 ]; then
        add_note "$NEARBY_WIFI_COUNT nearby Wi-Fi BSSID(s) were detected, but no Wi-Fi resolver produced coordinates."
    else
        add_note "No nearby Wi-Fi BSSIDs were collected."
    fi

    add_note "No device-native physical location was available; selected coordinates are based on public IP only."
fi

if [ -z "$SELECTED_METHOD" ]; then
    echo "ERROR: Unable to obtain location from known Wi-Fi, Google Wi-Fi, WiGLE Wi-Fi, native OS location, or public IP." >&2
    exit 1
fi

PHYSICAL_VS_PUBLIC_DISTANCE=""
VPN_REMOTE_EGRESS_LIKELY="false"

if [ -n "$PHYSICAL_METHOD" ] &&
   [ -n "$PUBLIC_IP_LAT" ] &&
   [ -n "$PUBLIC_IP_LON" ]; then

    PHYSICAL_VS_PUBLIC_DISTANCE="$(distance_km \
        "$PHYSICAL_LAT" "$PHYSICAL_LON" \
        "$PUBLIC_IP_LAT" "$PUBLIC_IP_LON")"

    if number_ge "$PHYSICAL_VS_PUBLIC_DISTANCE" "100"; then
        VPN_REMOTE_EGRESS_LIKELY="true"
        add_note "Physical and public-IP locations differ by $PHYSICAL_VS_PUBLIC_DISTANCE km; remote/VPN egress is likely."
    fi
fi

if [ "$VPN_ESTABLISHED_IDENTITY" != "None" ]; then
    VPN_REMOTE_EGRESS_LIKELY="true"
    add_note "An active VPN/tunnel indicator was detected ($VPN_ESTABLISHED_IDENTITY). Public-IP location should not be treated as physical location."
fi

if [ "$SELECTED_METHOD" = "PublicIP" ] &&
   [ "$ROUTER_VPN_SUSPECTED" = "True" ] &&
   [ "$ROUTER_VPN_CONFIDENCE" = "High" ]; then
    SELECTED_DETAIL="Public-IP location represents a high-confidence upstream VPN/tunnel egress, not a reliable physical endpoint location."
fi

CONFIDENCE="$(location_confidence "$SELECTED_METHOD" "$SELECTED_ACCURACY")"
TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
COMPUTER_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"

resolve_local_city "$SELECTED_LAT" "$SELECTED_LON" || true
if [ "$LOCAL_CITY_MATCH_TYPE" = "Unmatched" ] && [ "$SELECTED_METHOD" = "PublicIP" ]; then
    LOCAL_CITY="$PUBLIC_IP_CITY"
    LOCAL_PROVINCE="$PUBLIC_IP_REGION"
    LOCAL_COUNTRY="$PUBLIC_IP_COUNTRY"
    LOCAL_CITY_SOURCE="PublicIpGeo"
    LOCAL_CITY_MATCH_TYPE="PublicIpGeo"
fi

SELECTED_MAP_URI="$(make_map_uri "$SELECTED_LAT" "$SELECTED_LON")"
KNOWN_WIFI_MAP_URI=""
GOOGLE_WIFI_MAP_URI=""
WIGLE_MAP_URI=""
NATIVE_LOCATION_MAP_URI=""
PUBLIC_IP_MAP_URI="$(make_map_uri "$PUBLIC_IP_LAT" "$PUBLIC_IP_LON")"
ROUTER_WAN_MAP_URI="$(make_map_uri "$ROUTER_WAN_LAT" "$ROUTER_WAN_LON")"

case "$SELECTED_METHOD" in
    KnownWiFi) KNOWN_WIFI_MAP_URI="$SELECTED_MAP_URI" ;;
    GoogleWiFi) GOOGLE_WIFI_MAP_URI="$SELECTED_MAP_URI" ;;
    WiGLEWiFi) WIGLE_MAP_URI="$SELECTED_MAP_URI" ;;
    MacCoreLocation|LinuxGeoClue) NATIVE_LOCATION_MAP_URI="$SELECTED_MAP_URI" ;;
esac

WIFI_SCAN_STATUS="Success"
if [ "$WIFI_COLLECTOR" = "Unavailable" ]; then
    WIFI_SCAN_STATUS="Unavailable"
elif [ "$NEARBY_WIFI_COUNT" -eq 0 ]; then
    WIFI_SCAN_STATUS="NoBssids"
fi

if [ "$PLATFORM" = "macOS" ]; then
    NATIVE_PROVIDER="CoreLocation"
    NATIVE_STATUS="$MAC_NATIVE_LOCATION_STATUS"
else
    NATIVE_PROVIDER="$LINUX_NATIVE_PROVIDER"
    NATIVE_STATUS="$LINUX_NATIVE_LOCATION_STATUS"
fi

ESTABLISHED_VPN_TUNNEL="$(format_established_vpn_tunnel)"
WIFI_EVIDENCE="$(wifi_evidence_flat)"
NOTES="$(cat "$NOTES_FILE" 2>/dev/null || true)"

verbose "Native location: provider=$NATIVE_PROVIDER; status=$NATIVE_STATUS."
verbose "Google Wi-Fi resolver: configured=$([ -n "$GOOGLE_API_KEY" ] && printf true || printf false); status=$GOOGLE_WIFI_RESOLVER_STATUS; keySource=$GOOGLE_API_KEY_SOURCE; accessPointsUsed=$GOOGLE_WIFI_APS_USED."
verbose "WiGLE resolver: configured=$([ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ] && printf true || printf false); status=$WIGLE_WIFI_RESOLVER_STATUS; credentialSource=$WIGLE_CREDENTIAL_SOURCE; liveQueries=$WIGLE_LIVE_QUERIES_USED/$MAX_WIGLE_LOOKUPS; cacheHits=$WIGLE_CACHE_HITS."
verbose "Known Wi-Fi map configured=$([ -n "$WIFI_MAP_PATH" ] && printf true || printf false)."
verbose "Router discovery: gateway=${DEFAULT_GATEWAY:-<none>}; upnp=$UPNP_STATUS; natpmp=$NATPMP_STATUS; pcp=$PCP_STATUS; wan=${ROUTER_WAN_IP:-<none>}; routerVpn=$ROUTER_VPN_SUSPECTED/$ROUTER_VPN_CONFIDENCE."
verbose "Selected method=$SELECTED_METHOD; confidence=$CONFIDENCE; detectedVpn=$VPN_DETECTED_IDENTITY; establishedVpn=$VPN_ESTABLISHED_IDENTITY; remoteEgressLikely=$VPN_REMOTE_EGRESS_LIKELY."

# Core identity/location.
print_field "ComputerName" "$COMPUTER_NAME"
print_field "DeviceType" "$DEVICE_TYPE"
print_field "TimestampUtc" "$TIMESTAMP_UTC"
print_field "Method" "$SELECTED_METHOD"
print_field "Confidence" "$CONFIDENCE"
print_field "Latitude" "$SELECTED_LAT"
print_field "Longitude" "$SELECTED_LON"
print_field "AccuracyMeters" "${SELECTED_ACCURACY:-NotReported}"
print_field "Site" "${SELECTED_SITE:-NotReported}"
print_field "VpnResistant" "${SELECTED_VPN_RESISTANT:-Unknown}"

# Locality evidence.
print_field "LocalCity" "${LOCAL_CITY:-NotResolved}"
print_field "LocalProvince" "${LOCAL_PROVINCE:-NotResolved}"
print_field "LocalCountry" "${LOCAL_COUNTRY:-NotResolved}"
print_field "LocalCityMatchType" "$([ "$LOCAL_CITY_MATCH_TYPE" = "Unmatched" ] && printf NoLocalityMatch || printf %s "$LOCAL_CITY_MATCH_TYPE")"
print_field "LocalCitySource" "$([ "$LOCAL_CITY_SOURCE" = "NotReported" ] && printf None || printf %s "$LOCAL_CITY_SOURCE")"
print_field "LocalCityInsideRange" "$LOCAL_CITY_INSIDE_RANGE"
print_field "LocalCityCenterDistanceKm" "${LOCAL_CITY_CENTER_DISTANCE:-NotApplicable}"
print_field "LocalCityCenter" "${LOCAL_CITY_CENTER:-NotApplicable}"
print_field "LocalCityLatRange" "${LOCAL_CITY_LAT_RANGE:-NotApplicable}"
print_field "LocalCityLongRange" "${LOCAL_CITY_LON_RANGE:-NotApplicable}"

# Google is capability-aware: expose its detailed fields only when configured.
if [ -n "$GOOGLE_API_KEY" ]; then
    print_field "StrongestGoogleUsableBssid" "$STRONGEST_BSSID"
    print_field "StrongestGoogleUsableSsid" "$STRONGEST_SSID"
    print_field "StrongestGoogleUsableSignalPct" "$STRONGEST_SIGNAL_PCT"
    print_field "StrongestGoogleUsableSignalDbm" "$STRONGEST_SIGNAL_DBM"
    print_field "StrongestGoogleUsableChannel" "$STRONGEST_CHANNEL"
    print_field "GoogleWifiResolverStatus" "$GOOGLE_WIFI_RESOLVER_STATUS"
    print_field "GoogleWifiAccessPointsUsed" "$GOOGLE_WIFI_APS_USED"
fi

# WiGLE diagnostics are emitted only when credentials are configured.
if [ -n "$WIGLE_API_NAME" ] && [ -n "$WIGLE_API_TOKEN" ]; then
    print_field "WigleWifiResolverStatus" "$WIGLE_WIFI_RESOLVER_STATUS"
    print_field "WigleCredentialSource" "$WIGLE_CREDENTIAL_SOURCE"
    print_field "WigleLiveQueriesUsed" "$WIGLE_LIVE_QUERIES_USED"
    print_field "WigleLookupBudget" "$MAX_WIGLE_LOOKUPS"
    print_field "WigleCacheHits" "$WIGLE_CACHE_HITS"
    print_field "WigleCandidateCount" "$WIGLE_CANDIDATE_COUNT"
    print_field "WigleCacheCandidatesChecked" "$WIGLE_CACHE_CANDIDATES_CHECKED"
    print_field "WigleLiveCandidatesEligible" "$WIGLE_LIVE_CANDIDATES_ELIGIBLE"
    print_field "WigleCurrentBssidPrioritized" "$WIGLE_CURRENT_BSSID_PRIORITIZED"
    print_field "WigleCurrentBssid" "${WIGLE_CURRENT_BSSID:-NotAvailable}"
    print_field "WigleCurrentBssidEligibility" "$WIGLE_CURRENT_BSSID_ELIGIBILITY"
    print_field "WigleLastHttpStatus" "${WIGLE_LAST_HTTP_STATUS:-NotReported}"
    print_field "WigleLastErrorMessage" "${WIGLE_LAST_ERROR_MESSAGE:-NotReported}"
    print_field "WigleLastErrorBody" "${WIGLE_LAST_ERROR_BODY:-NotReported}"
    print_field "WigleTerminalFailure" "$WIGLE_TERMINAL_FAILURE"
    print_field "WigleTerminalFailureBasis" "${WIGLE_TERMINAL_FAILURE_BASIS:-None}"
    print_field "WigleRateLimitBasis" "${WIGLE_RATE_LIMIT_BASIS:-None}"
    print_field "WigleRateLimitRemaining" "${WIGLE_RATE_LIMIT_REMAINING:-NotReported}"
    print_field "WigleRateLimitLimit" "${WIGLE_RATE_LIMIT_LIMIT:-NotReported}"
    print_field "WigleRateLimitReset" "${WIGLE_RATE_LIMIT_RESET:-NotReported}"
    print_field "WigleCandidateOrder" "${WIGLE_CANDIDATE_ORDER:-None}"
fi

# BLE contract fields appear only after explicit BLE controls, matching v3.62.
if [ "$BLUETOOTH_EXPLICIT" -eq 1 ]; then
    print_field "BluetoothScanStatus" "$BLUETOOTH_SCAN_STATUS"
    if [ "$SKIP_BLUETOOTH" -eq 1 ]; then
        print_field "BluetoothScanEngine" "NotApplicable"
    else
        print_field "BluetoothScanEngine" "UnsupportedPlatform"
    fi
    print_field "BluetoothScanDetail" "$BLUETOOTH_SCAN_DETAIL"
    print_field "BluetoothDeviceCount" "0"
    print_field "BluetoothAnchorCount" "0"
    print_field "StrongestBluetoothName" ""
    print_field "StrongestBluetoothAddress" ""
    print_field "StrongestBluetoothRssi" ""
    if [ -n "$BLUETOOTH_MAP_PATH" ]; then
        print_field "BluetoothLocationMatch" "NoMatch"
    else
        print_field "BluetoothLocationMatch" "NotConfigured"
    fi
    print_field "BluetoothLocationDistanceKm" "NotApplicable"
fi

# Current Wi-Fi and LAN context.
print_field "WifiScanStatus" "$WIFI_SCAN_STATUS"
print_field "CurrentWifiStatus" "$CURRENT_WIFI_STATUS"
print_field "CurrentWifiSsid" "${CURRENT_WIFI_SSID:-NotReported}"
print_field "CurrentWifiBssid" "${CURRENT_WIFI_BSSID:-NotReported}"
print_field "CurrentWifiSignalPct" "${CURRENT_WIFI_SIGNAL_PCT:-NotReported}"
print_field "CurrentWifiSignalDbm" "${CURRENT_WIFI_SIGNAL_DBM:-NotReported}"
print_field "CurrentWifiChannel" "${CURRENT_WIFI_CHANNEL:-NotReported}"

print_field "ActiveInterface" "${ACTIVE_INTERFACE:-NotReported}"
print_field "ActiveInterfaceType" "${ACTIVE_INTERFACE_TYPE:-NotReported}"
print_field "LocalIPv4" "${LOCAL_IPV4:-NotReported}"
print_field "DefaultGateway" "${DEFAULT_GATEWAY:-NotReported}"
print_field "GatewayMac" "${GATEWAY_MAC:-NotReported}"
print_field "GatewayVendor" "${GATEWAY_VENDOR:-NotReported}"
print_field "DhcpServer" "${DHCP_SERVER:-NotReported}"
print_field "ConnectionDnsSuffix" "${CONNECTION_DNS_SUFFIX:-NotReported}"

# Public egress and router evidence.
print_field "PublicIp" "${PUBLIC_IP:-NotReported}"
print_field "PublicIpVersion" "${PUBLIC_IP_VERSION:-NotReported}"
print_field "PublicIpCity" "${PUBLIC_IP_CITY:-NotReported}"
print_field "PublicIpRegion" "${PUBLIC_IP_REGION:-NotReported}"
print_field "PublicIpCountry" "${PUBLIC_IP_COUNTRY:-NotReported}"
print_field "PublicIpIsp" "${PUBLIC_IP_ISP:-NotReported}"
print_field "PublicIpOrganization" "${PUBLIC_IP_ORG:-NotReported}"
print_field "PublicIpAsn" "${PUBLIC_IP_ASN:-NotReported}"

print_field "RouterFriendlyName" "${ROUTER_FRIENDLY_NAME:-NotReported}"
print_field "RouterManufacturer" "${ROUTER_MANUFACTURER:-NotReported}"
print_field "RouterManufacturerRaw" "${ROUTER_MANUFACTURER_RAW:-NotReported}"
print_field "RouterManufacturerResolved" "${ROUTER_MANUFACTURER_RESOLVED:-NotReported}"
print_field "RouterPlatform" "${ROUTER_PLATFORM:-NotReported}"
print_field "RouterIdentityConfidence" "$ROUTER_IDENTITY_CONFIDENCE"
print_field "RouterIdentityBasis" "${ROUTER_IDENTITY_BASIS:-NotReported}"
print_field "RouterModel" "${ROUTER_MODEL:-NotReported}"
print_field "RouterWebHint" "${ROUTER_WEB_HINT:-NotReported}"
print_field "RouterTlsSubject" "${ROUTER_TLS_SUBJECT:-NotReported}"
print_field "RouterWanIp" "${ROUTER_WAN_IP:-NotExposed}"
print_field "RouterWanSource" "${ROUTER_WAN_SOURCE:-NotReported}"
print_field "RouterWanIsp" "${ROUTER_WAN_ISP:-NotAvailable}"
print_field "RouterWanGeo" "${ROUTER_WAN_GEO:-NotAvailable}"
print_field "NatPmpStatus" "$NATPMP_STATUS"
print_field "PcpStatus" "$PCP_STATUS"
print_field "UpnpStatus" "$UPNP_STATUS"

print_field "RouterVpnSuspected" "$ROUTER_VPN_SUSPECTED"
print_field "RouterVpnConfidence" "$ROUTER_VPN_CONFIDENCE"
print_field "RouterVpnEvidence" "$ROUTER_VPN_EVIDENCE"
print_field "TraceGeo" "$TRACE_GEO"

# VPN/egress evidence.
print_field "PhysicalVsPublicIpDistanceKm" "${PHYSICAL_VS_PUBLIC_DISTANCE:-NotReported}"
print_field "VpnAdapterDetected" "$VPN_DETECTED_IDENTITY"
print_field "EstablishedVpnTunnel" "$ESTABLISHED_VPN_TUNNEL"
print_field "VpnOrRemoteEgressLikely" "$VPN_REMOTE_EGRESS_LIKELY"
print_field "VpnEvidence" "$VPN_DETECTED_EVIDENCE"
print_field "EstablishedVpnEvidence" "$VPN_ESTABLISHED_EVIDENCE"

# Provenance and maps.
print_field "Detail" "$SELECTED_DETAIL"
print_field "MapUri" "$SELECTED_MAP_URI"
print_field "SelectedMapUri" "$SELECTED_MAP_URI"
print_field "GpsMapUri" "NotAvailable"
print_field "KnownWifiMapUri" "${KNOWN_WIFI_MAP_URI:-NotAvailable}"
print_field "GoogleWifiMapUri" "${GOOGLE_WIFI_MAP_URI:-NotAvailable}"
print_field "WigleMapUri" "${WIGLE_MAP_URI:-NotAvailable}"
print_field "NativeLocationMapUri" "${NATIVE_LOCATION_MAP_URI:-NotAvailable}"
print_field "OgLocationMapUri" "NotAvailable"
print_field "PublicIpMapUri" "${PUBLIC_IP_MAP_URI:-NotAvailable}"
print_field "RouterWanMapUri" "${ROUTER_WAN_MAP_URI:-NotAvailable}"
print_field "og_devcoordscript_says" "NotAvailable"
print_field "OG_and_NewG_gap" "NotAvailable"
print_field "Notes" "$NOTES"

if [ "$BLUETOOTH_EXPLICIT" -eq 1 ]; then
    print_field "BluetoothAnchorMapUri" "NotAvailable"
    print_field "BluetoothEvidence" "$BLUETOOTH_EVIDENCE"
fi

# Deliberately final, matching the production PowerShell property contract.
print_field "WifiEvidence" "$WIFI_EVIDENCE"
