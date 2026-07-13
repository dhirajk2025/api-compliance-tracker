#!/bin/bash

# Organizations API - Seed Passport Issuer Organizations
# Fetches an OAuth2 access token from Core API, then creates
# organizations from a CSV file or Google Sheet.
#
# CSV format (header row required):
#   Legal Name,Sector,Structure,Jurisdiction
#
# Usage:
#   ./seed-issuers.sh \
#     --base-url      https://organizations-api.staging.idme.com \
#     --token-url     https://core-api.staging.idme.com/api/v1/oauth/tokens \
#     --client-id     <client-id> \
#     --client-secret <client-secret> \
#     --csv           ./issuers.csv              # local CSV file
#     --sheet-url     "<google-sheet-csv-url>"   # or Google Sheet export URL
#     [--dry-run]

# Strict mode for startup/config errors — disabled inside the seed loop
# so one bad record does not abort the entire run.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BASE_URL=""
TOKEN_URL=""
CLIENT_ID=""
CLIENT_SECRET=""
CSV_FILE=""
SHEET_URL=""
DRY_RUN=false
LOG_FILE="seed-issuers-$(date +%Y%m%d-%H%M%S).log"

# Report arrays — track each row outcome for the final report
REPORT_ROWS=()   # "<row>|<status>|<legal_name>|<jurisdiction>|<detail>"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  echo "Organizations API - Seed Passport Issuer Organizations"
  echo "======================================================="
  echo ""
  echo "Usage:"
  echo "  $0 --base-url <url> --token-url <url> --client-id <id> --client-secret <secret>"
  echo "     --csv <file> | --sheet-url <url>"
  echo "     [--dry-run]"
  echo ""
  echo "Required:"
  echo "  --base-url      Org API base URL    (e.g. https://organizations-api.staging.idme.com)"
  echo "  --token-url     Core API token URL  (e.g. https://core-api.staging.idme.com/api/v1/oauth/tokens)"
  echo "  --client-id     OAuth2 client ID"
  echo "  --client-secret OAuth2 client secret"
  echo ""
  echo "Data source (one required):"
  echo "  --csv           Path to a local CSV file"
  echo "  --sheet-url     Google Sheets CSV export URL"
  echo ""
  echo "  CSV format (header row required):"
  echo "    Legal Name,Sector,Structure,Jurisdiction"
  echo ""
  echo "  To get the Google Sheet export URL:"
  echo "    Open sheet → File → Share → Publish to web → CSV → Copy link"
  echo "    Or use: https://docs.google.com/spreadsheets/d/<SHEET_ID>/export?format=csv&gid=<GID>"
  echo ""
  echo "Optional:"
  echo "  --dry-run       Print request bodies without sending any requests"
  echo "  --log-file      Path for the log file (default: seed-issuers-<timestamp>.log)"
  echo "  --help          Show this help"
  echo ""
  echo "Example:"
  echo "  $0 \\"
  echo "    --base-url     https://organizations-api.staging.idme.com \\"
  echo "    --token-url    https://core-api.staging.idme.com/api/v1/oauth/tokens \\"
  echo "    --client-id    abc123 \\"
  echo "    --client-secret mysecret \\"
  echo "    --csv          ./issuers.csv"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)      BASE_URL="$2";      shift 2 ;;
    --token-url)     TOKEN_URL="$2";     shift 2 ;;
    --client-id)     CLIENT_ID="$2";     shift 2 ;;
    --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
    --csv)           CSV_FILE="$2";      shift 2 ;;
    --sheet-url)     SHEET_URL="$2";     shift 2 ;;
    --log-file)      LOG_FILE="$2";      shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift   ;;
    --help|-h)       usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
MISSING=()
[[ -z "$BASE_URL"      ]] && MISSING+=("--base-url")
[[ -z "$TOKEN_URL"     ]] && MISSING+=("--token-url")
[[ -z "$CLIENT_ID"     ]] && MISSING+=("--client-id")
[[ -z "$CLIENT_SECRET" ]] && MISSING+=("--client-secret")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: missing required arguments: ${MISSING[*]}"
  echo ""
  usage
  exit 1
fi

if [[ -z "$CSV_FILE" && -z "$SHEET_URL" ]]; then
  echo "Error: provide either --csv <file> or --sheet-url <url>"
  echo ""
  usage
  exit 1
fi

if [[ -n "$CSV_FILE" && -n "$SHEET_URL" ]]; then
  echo "Error: provide only one of --csv or --sheet-url, not both"
  exit 1
fi

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Load CSV — from local file or Google Sheet
# ---------------------------------------------------------------------------
load_csv() {
  if [[ -n "$SHEET_URL" ]]; then
    echo -n "Fetching CSV from Google Sheet... "
    CSV_DATA=$(curl -sL "$SHEET_URL")
    if [[ -z "$CSV_DATA" ]]; then
      echo "Error: empty response from sheet URL. Check the URL is a published CSV export."
      exit 1
    fi
    echo "OK"
  else
    if [[ ! -f "$CSV_FILE" ]]; then
      echo "Error: CSV file not found: $CSV_FILE"
      exit 1
    fi
    CSV_DATA=$(cat "$CSV_FILE")
  fi

  # Parse CSV into ISSUERS array (skip header row, skip blank lines)
  # Fields: Legal Name, Sector, Structure, Jurisdiction
  # Uses | as internal separator since org names can contain commas
  ISSUERS=()
  local first=true
  while IFS= read -r line; do
    # Skip header
    if [[ "$first" == true ]]; then
      first=false
      continue
    fi
    # Skip blank lines
    [[ -z "${line// }" ]] && continue

    # Parse CSV line — handles quoted fields containing commas
    # Extract fields using python3 (available on all Macs) for robust CSV parsing
    parsed=$(python3 -c "
import csv, sys
reader = csv.reader([sys.stdin.read().strip()])
for row in reader:
    if len(row) >= 4:
        print('|'.join(row[:4]))
" <<< "$line")

    [[ -n "$parsed" ]] && ISSUERS+=("$parsed")
  done <<< "$CSV_DATA"
}

# ---------------------------------------------------------------------------
# Token fetch
# ---------------------------------------------------------------------------
get_access_token() {
  local credentials
  credentials=$(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64)

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Authorization: Basic $credentials" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=organizations:write")

  local body http_code
  body=$(echo "$response" | head -n -1)
  http_code=$(echo "$response" | tail -n 1)

  if [[ "$http_code" != "200" ]]; then
    echo "Error: token request failed with HTTP $http_code"
    echo "$body" | jq '.' 2>/dev/null || echo "$body"
    exit 1
  fi

  echo "$body" | jq -r '.access_token'
}

# ---------------------------------------------------------------------------
# Build request body
# ---------------------------------------------------------------------------
build_request_body() {
  local legal_name="$1"
  local sector="$2"
  local structure="$3"
  local jurisdiction="$4"

  # Use jq to safely build JSON — handles special characters and quotes
  jq -n \
    --arg legalName               "$legal_name" \
    --arg organizationSector      "$sector" \
    --arg organizationStructure   "$structure" \
    --arg jurisdictionOfFormation "$jurisdiction" \
    '{
      legalName:               $legalName,
      organizationSector:      $organizationSector,
      organizationStructure:   $organizationStructure,
      jurisdictionOfFormation: $jurisdictionOfFormation
    }'
  # claimantType and claimant are intentionally omitted — M2M integration;
  # the API resolves the claimant to the Org UUID from the access token.
}

# ---------------------------------------------------------------------------
# Logging — writes to both stdout and log file
# ---------------------------------------------------------------------------
log() {
  echo "$*" | tee -a "$LOG_FILE"
}

log_raw() {
  # For printf-style output — already formatted by caller
  echo "$*" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Organizations API - Seed Passport Issuer Organizations"
log "======================================================="
log "Started:   $(date)"
log "Log file:  $LOG_FILE"
log ""

# Load issuers
load_csv
log "Issuers loaded: ${#ISSUERS[@]}"
log ""
log "Base URL:  $BASE_URL"
log "Token URL: $TOKEN_URL"
log ""

if [[ ${#ISSUERS[@]} -eq 0 ]]; then
  log "Error: no issuers found in CSV. Check format (header: Legal Name,Sector,Structure,Jurisdiction)"
  exit 1
fi

# Dry run
if [[ "$DRY_RUN" == true ]]; then
  log "--- DRY RUN — no requests will be sent ---"
  log ""
  local_row=0
  for entry in "${ISSUERS[@]}"; do
    (( local_row++ ))
    IFS='|' read -r legal_name sector structure jurisdiction <<< "$entry"
    log "[$local_row] POST $BASE_URL/v1/organizations"
    build_request_body "$legal_name" "$sector" "$structure" "$jurisdiction" | tee -a "$LOG_FILE"
    log ""
  done
  log "Dry run complete. $local_row rows would be sent."
  exit 0
fi

# Fetch token — fatal if it fails (no point continuing without a token)
log -n "Fetching access token... "
ACCESS_TOKEN=$(get_access_token)
log "OK"
log ""

# ---------------------------------------------------------------------------
# Seed loop
# Disable set -e here so one failed row does not abort the entire run.
# Each row is handled individually and outcomes are tracked in REPORT_ROWS.
# ---------------------------------------------------------------------------
set +e

SUCCESS=0
SKIPPED=0
FAILED=0
ROW=0

printf "%-5s %-68s %-12s %s\n" "Row" "Organization" "Status" "Detail" | tee -a "$LOG_FILE"
printf '%0.s-' {1..120} | tee -a "$LOG_FILE"; echo "" | tee -a "$LOG_FILE"

for entry in "${ISSUERS[@]}"; do
  (( ROW++ ))
  IFS='|' read -r legal_name sector structure jurisdiction <<< "$entry"
  short_name="${legal_name:0:66}"

  # Validate required fields before calling the API
  if [[ -z "$legal_name" || -z "$sector" || -z "$structure" || -z "$jurisdiction" ]]; then
    detail="Missing required field(s) — skipped"
    printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "SKIPPED" "$detail" | tee -a "$LOG_FILE"
    REPORT_ROWS+=("$ROW|SKIPPED|$legal_name|$jurisdiction|$detail")
    (( FAILED++ ))
    continue
  fi

  body=$(build_request_body "$legal_name" "$sector" "$structure" "$jurisdiction")

  # Log the full request body to file (not stdout) for traceability
  echo "  [row $ROW] REQUEST: $body" >> "$LOG_FILE"

  response=$(curl -s -w "\n%{http_code}" \
    --max-time 15 \
    -X POST "$BASE_URL/v1/organizations" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$body" 2>> "$LOG_FILE")

  curl_exit=$?
  response_body=$(echo "$response" | head -n -1)
  http_code=$(echo "$response" | tail -n 1)

  # Log full response body to file for traceability
  echo "  [row $ROW] RESPONSE HTTP=$http_code: $response_body" >> "$LOG_FILE"

  # Handle curl-level failures (network error, timeout)
  if [[ $curl_exit -ne 0 ]]; then
    detail="curl error (exit $curl_exit) — network issue or timeout"
    printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "ERROR" "$detail" | tee -a "$LOG_FILE"
    REPORT_ROWS+=("$ROW|ERROR|$legal_name|$jurisdiction|$detail")
    (( FAILED++ ))
    continue
  fi

  case "$http_code" in
    200|201)
      uuid=$(echo "$response_body" | jq -r '.uuid // empty' 2>/dev/null)
      detail="uuid=$uuid"
      printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "CREATED" "$detail" | tee -a "$LOG_FILE"
      REPORT_ROWS+=("$ROW|CREATED|$legal_name|$jurisdiction|$detail")
      (( SUCCESS++ ))
      ;;
    409)
      # Per spec: existing org returned — not an error
      uuid=$(echo "$response_body" | jq -r '.uuid // empty' 2>/dev/null)
      detail="uuid=$uuid (already exists)"
      printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "EXISTS" "$detail" | tee -a "$LOG_FILE"
      REPORT_ROWS+=("$ROW|EXISTS|$legal_name|$jurisdiction|$detail")
      (( SKIPPED++ ))
      ;;
    422)
      # Full error detail — validation failure, bad field value
      detail=$(echo "$response_body" | jq -r '.message // .errors // .error // .' 2>/dev/null)
      printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "422 INVALID" "${detail:0:60}" | tee -a "$LOG_FILE"
      REPORT_ROWS+=("$ROW|INVALID|$legal_name|$jurisdiction|$detail")
      (( FAILED++ ))
      ;;
    401)
      # Token expired mid-run — abort immediately, nothing further will work
      log ""
      log "FATAL: received 401 Unauthorized on row $ROW — token expired or scope incorrect."
      log "Rows processed before failure: $ROW  Created: $SUCCESS  Skipped: $SKIPPED  Failed: $FAILED"
      print_report
      exit 1
      ;;
    "")
      detail="No response — API unreachable or connection refused"
      printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "NO RESPONSE" "$detail" | tee -a "$LOG_FILE"
      REPORT_ROWS+=("$ROW|NO_RESPONSE|$legal_name|$jurisdiction|$detail")
      (( FAILED++ ))
      ;;
    *)
      detail="HTTP $http_code — $(echo "$response_body" | head -c 80)"
      printf "%-5s %-68s %-12s %s\n" "[$ROW]" "$short_name" "$http_code FAIL" "${detail:0:60}" | tee -a "$LOG_FILE"
      REPORT_ROWS+=("$ROW|FAILED|$legal_name|$jurisdiction|$detail")
      (( FAILED++ ))
      ;;
  esac

  sleep 0.2
done

set -e

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
print_report() {
  printf '%0.s-' {1..120} | tee -a "$LOG_FILE"; echo "" | tee -a "$LOG_FILE"
  log ""
  log "=============================="
  log " SEED RUN REPORT"
  log "=============================="
  log "Completed:  $(date)"
  log "Total rows: ${#ISSUERS[@]}"
  log "  Created:        $SUCCESS"
  log "  Already existed: $SKIPPED"
  log "  Failed/Invalid:  $FAILED"
  log ""

  if [[ $FAILED -gt 0 ]]; then
    log "--- Failures (requires attention) ---"
    for row in "${REPORT_ROWS[@]}"; do
      IFS='|' read -r row_num status name jurisdiction detail <<< "$row"
      if [[ "$status" != "CREATED" && "$status" != "EXISTS" ]]; then
        log "  Row $row_num | $status | $name ($jurisdiction)"
        log "           Detail: $detail"
      fi
    done
    log ""
  fi

  log "Full log: $LOG_FILE"
}

print_report

# Exit with non-zero if any rows failed — useful for CI/scripted runs
if [[ $FAILED -gt 0 ]]; then
  exit 2
fi
