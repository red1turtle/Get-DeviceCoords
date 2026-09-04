#!/usr/bin/env bash
#
# get-device-coords-v1.0.sh
#
# Standalone macOS/Linux companion to the frozen Windows
# Get-DeviceCoords-v3.5.ps1 baseline.
#
# Core resolver order:
#   1. Known Wi-Fi BSSID map (optional)
#   2. Google Geolocation API from nearby usable BSSIDs (optional)
#   3. Native OS location provider
#        macOS: CoreWLAN for Wi-Fi + Core Location for position
#        Linux: NetworkManager nmcli (preferred), iw fallback, GeoClue helper
#   4. Public-IP geolocation fallback
#
# No PowerShell, Python, jq, Homebrew, or package installation is required
# by the script itself. Optional OS tooling is detected at runtime.
#
# Bash 3.2+ compatible for the Bash shipped with macOS.
#

set -o pipefail
umask 077

SCRIPT_VERSION="1.0"
VERBOSE=1
TIMEOUT_SECONDS=8
GOOGLE_API_KEY="${GOOGLE_GEO_API_KEY:-}"
GOOGLE_API_KEY_SOURCE="None"
WIFI_MAP_PATH="${DEVICE_COORDS_WIFI_MAP:-}"
SKIP_PUBLIC_IP=0

if [ -n "${GOOGLE_API_KEY}" ]; then
    GOOGLE_API_KEY_SOURCE="Environment"
fi

usage() {
    cat <<'EOF'
Usage:
  get-device-coords-v1.0.sh [options]

Options:
  --google-api-key KEY   Optional Google Geolocation API key.
                        If omitted, GOOGLE_GEO_API_KEY is used when set.
  --wifi-map PATH        Optional CSV:
                        BSSID,Latitude,Longitude,Site,AccuracyMeters
  --timeout SECONDS      Native-location timeout. Default: 8.
  --skip-public-ip       Do not perform public-IP geolocation.
  --quiet                Suppress default verbose diagnostics.
  --verbose              Enable verbose diagnostics (default).
  --help                 Show this help.

Examples:
  ./get-device-coords-v1.0.sh

  GOOGLE_GEO_API_KEY='...' ./get-device-coords-v1.0.sh

  ./get-device-coords-v1.0.sh --wifi-map ./Corporate-WifiLocations.csv

Notes:
  * Google is never contacted unless a key is configured.
  * Google Wi-Fi requests use considerIp=false.
  * WifiEvidence always contains only Google-usable BSSIDs.
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
        --wifi-map)
            shift
            if [ "$#" -eq 0 ]; then
                echo "ERROR: --wifi-map requires a path." >&2
                exit 2
            fi
            WIFI_MAP_PATH="$1"
            ;;
        --timeout)
            shift
            if [ "$#" -eq 0 ] || ! printf '%s' "$1" | grep -Eq '^[0-9]+$'; then
                echo "ERROR: --timeout requires an integer number of seconds." >&2
                exit 2
            fi
            TIMEOUT_SECONDS="$1"
            ;;
        --skip-public-ip)
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
    local lat lon accuracy key_safe

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

    if ! curl -sS --max-time 8 \
        --config "$config" \
        -H 'Content-Type: application/json' \
        --data-binary @"$body" \
        -o "$response"; then

        GOOGLE_WIFI_RESOLVER_STATUS="FailedRequest"
        return 1
    fi

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
# Main
# ---------------------------------------------------------------------------

verbose "Get-DeviceCoords Unix v$SCRIPT_VERSION; platform=$PLATFORM; bash=$BASH_VERSION."

collect_wifi

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

verbose "Wi-Fi collector=$WIFI_COLLECTOR; nearbyBssids=$NEARBY_WIFI_COUNT; googleUsable=$GOOGLE_USABLE_COUNT."

if [ "$GOOGLE_USABLE_COUNT" -eq 0 ] && [ "$NEARBY_WIFI_COUNT" -gt 0 ]; then
    rejection_summary="$(awk -F '|' '$7!="true" {c[$8]++} END {for (r in c) printf "%s%s=%d", sep, r, c[r]; sep=", "}' "$WIFI_FILE")"
    add_note "Wi-Fi was detected, but none of the observed BSSIDs are Google-usable. Rejection summary: $rejection_summary."
fi

if [ -n "$STRONGEST_BSSID" ]; then
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

# Highest-priority resolver.
if resolve_known_wifi; then
    if [ -n "$GOOGLE_API_KEY" ]; then
        GOOGLE_WIFI_RESOLVER_STATUS="SkippedHigherPriorityLocationResolved"
    fi
else
    resolve_google_wifi || true
fi

if [ -z "$PHYSICAL_METHOD" ]; then
    resolve_native_location || true
fi

if [ -n "$PHYSICAL_METHOD" ] &&
   [ "$PHYSICAL_METHOD" != "KnownWiFi" ] &&
   [ "$PHYSICAL_METHOD" != "GoogleWiFi" ]; then

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
   [ -z "$PHYSICAL_METHOD" ] &&
   [ "$LINUX_NATIVE_PROVIDER" = "GeoClueUnavailable" ]; then
    add_note "GeoClue where-am-i helper was not found. Linux native location was unavailable; public-IP fallback remains available."
fi

resolve_public_ip || true
collect_vpn_evidence

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
    echo "ERROR: Unable to obtain location from known Wi-Fi, Google Wi-Fi, native OS location, or public IP." >&2
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

if [ -s "$VPN_FILE" ]; then
    VPN_ADAPTER_DETECTED="true"
    if [ "$VPN_REMOTE_EGRESS_LIKELY" != "true" ]; then
        add_note "An active VPN/tunnel indicator was detected. Public-IP location should not be treated as physical location."
    fi
else
    VPN_ADAPTER_DETECTED="false"
fi

CONFIDENCE="$(location_confidence "$SELECTED_METHOD" "$SELECTED_ACCURACY")"
TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
COMPUTER_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
MAP_URI="https://www.google.com/maps/search/?api=1&query=${SELECTED_LAT},${SELECTED_LON}"
WIFI_EVIDENCE="$(wifi_evidence_flat)"
VPN_EVIDENCE="$(cat "$VPN_FILE" 2>/dev/null || true)"
NOTES="$(cat "$NOTES_FILE" 2>/dev/null || true)"

if [ "$PLATFORM" = "macOS" ]; then
    NATIVE_PROVIDER="CoreLocation"
    NATIVE_STATUS="$MAC_NATIVE_LOCATION_STATUS"
else
    NATIVE_PROVIDER="$LINUX_NATIVE_PROVIDER"
    NATIVE_STATUS="$LINUX_NATIVE_LOCATION_STATUS"
fi

verbose "Native location: provider=$NATIVE_PROVIDER; status=$NATIVE_STATUS."
verbose "Google Wi-Fi resolver: configured=$([ -n "$GOOGLE_API_KEY" ] && printf true || printf false); status=$GOOGLE_WIFI_RESOLVER_STATUS; keySource=$GOOGLE_API_KEY_SOURCE; accessPointsUsed=$GOOGLE_WIFI_APS_USED."
verbose "Known Wi-Fi map configured=$([ -n "$WIFI_MAP_PATH" ] && printf true || printf false)."
verbose "Selected method=$SELECTED_METHOD; confidence=$CONFIDENCE; VPN/tunnel detected=$VPN_ADAPTER_DETECTED; remoteEgressLikely=$VPN_REMOTE_EGRESS_LIKELY."

print_field "ComputerName" "$COMPUTER_NAME"
print_field "TimestampUtc" "$TIMESTAMP_UTC"
print_field "Method" "$SELECTED_METHOD"
print_field "Confidence" "$CONFIDENCE"
print_field "Latitude" "$SELECTED_LAT"
print_field "Longitude" "$SELECTED_LON"
print_field "AccuracyMeters" "$SELECTED_ACCURACY"
print_field "Site" "$SELECTED_SITE"
print_field "VpnResistant" "$SELECTED_VPN_RESISTANT"

print_field "StrongestGoogleUsableBssid" "$STRONGEST_BSSID"
print_field "StrongestGoogleUsableSsid" "$STRONGEST_SSID"
print_field "StrongestGoogleUsableSignalPct" "$STRONGEST_SIGNAL_PCT"
print_field "StrongestGoogleUsableSignalDbm" "$STRONGEST_SIGNAL_DBM"
print_field "StrongestGoogleUsableChannel" "$STRONGEST_CHANNEL"

print_field "PublicIp" "$PUBLIC_IP"
print_field "PublicIpCity" "$PUBLIC_IP_CITY"
print_field "PublicIpRegion" "$PUBLIC_IP_REGION"
print_field "PublicIpCountry" "$PUBLIC_IP_COUNTRY"
print_field "PublicIpIsp" "$PUBLIC_IP_ISP"

print_field "PhysicalVsPublicIpDistanceKm" "$PHYSICAL_VS_PUBLIC_DISTANCE"
print_field "VpnAdapterDetected" "$VPN_ADAPTER_DETECTED"
print_field "VpnOrRemoteEgressLikely" "$VPN_REMOTE_EGRESS_LIKELY"
print_field "VpnEvidence" "$VPN_EVIDENCE"

print_field "WifiEvidence" "$WIFI_EVIDENCE"
print_field "Detail" "$SELECTED_DETAIL"
print_field "MapUri" "$MAP_URI"
print_field "Notes" "$NOTES"
