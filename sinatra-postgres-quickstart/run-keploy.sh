#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="$(basename "$ROOT_DIR")"
POSTGRES_VOLUME="${PROJECT_NAME}_postgres_data"
APP_HOST_PORT="${APP_HOST_PORT:-}"
BASE_URL="${BASE_URL:-}"
CONTAINER_NAME="ruby-books-app"
SUDO_PREFIX=()

cd "$ROOT_DIR"

if ! command -v keploy >/dev/null 2>&1; then
  echo "Error: keploy binary not found in PATH"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required"
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO_PREFIX=(sudo -n)
  else
    echo "Refreshing sudo credentials for Keploy..."
    sudo -v
    SUDO_PREFIX=(sudo)
  fi
fi

request_counter=0

choose_free_port() {
  local candidate
  local occupied_ports
  occupied_ports="$(ss -ltnH | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u)"

  for candidate in $(seq 18080 18120); do
    if ! printf '%s\n' "$occupied_ports" | grep -qx "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ -z "$APP_HOST_PORT" ]]; then
  APP_HOST_PORT="$(choose_free_port)" || {
    echo "Error: no free host port found in range 18080-18120"
    exit 1
  }
fi

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="http://localhost:${APP_HOST_PORT}"
fi

export APP_HOST_PORT BASE_URL

cleanup() {
  echo "Cleaning up containers..."
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker volume rm -f "$POSTGRES_VOLUME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "Resetting docker services for a clean recording run..."
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker volume rm -f "$POSTGRES_VOLUME" >/dev/null 2>&1 || true

echo "Starting Keploy record mode..."
"${SUDO_PREFIX[@]}" keploy record -c "APP_HOST_PORT=$APP_HOST_PORT BASE_URL=$BASE_URL docker compose up --build" --container-name "$CONTAINER_NAME" --cmd-type docker-compose --sync &
KEPLOY_PID=$!

wait_for_health() {
  local retries=60
  local wait_seconds=2

  echo "Waiting for API readiness..."
  for ((i=1; i<=retries; i++)); do
    local status
    local body
    status="$(curl -sS -o /tmp/keploy_health_body.$$ -w "%{http_code}" "$BASE_URL/health" 2>/dev/null || true)"
    body="$(cat /tmp/keploy_health_body.$$ 2>/dev/null || true)"
    rm -f /tmp/keploy_health_body.$$ >/dev/null 2>&1 || true

    if [[ "$status" == "200" ]] && [[ "$body" == *'"status":"healthy"'* ]] && [[ "$body" == *'"service":"Ruby Books API"'* ]]; then
      echo "API is ready."
      return 0
    fi

    if ! kill -0 "$KEPLOY_PID" >/dev/null 2>&1; then
      echo "Error: Keploy record process exited before API became ready"
      return 1
    fi

    sleep "$wait_seconds"
  done

  echo "Error: API did not become healthy in time"
  return 1
}

api_call() {
  local label="$1"
  local method="$2"
  local endpoint="$3"
  local expected_status="$4"
  local payload="${5:-}"

  request_counter=$((request_counter + 1))
  local tmp_body
  tmp_body="$(mktemp)"

  local status
  if [[ -n "$payload" ]]; then
    status="$(curl -sS -o "$tmp_body" -w "%{http_code}" -X "$method" "$BASE_URL$endpoint" -H "Content-Type: application/json" -d "$payload")"
  else
    status="$(curl -sS -o "$tmp_body" -w "%{http_code}" -X "$method" "$BASE_URL$endpoint")"
  fi

  local body
  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  echo "[$request_counter] $label" >&2
  echo "    $method $endpoint => $status" >&2
  echo "    $body" >&2

  if [[ "$status" != "$expected_status" ]]; then
    echo "Error: expected HTTP $expected_status but got $status"
    kill -INT "$KEPLOY_PID" >/dev/null 2>&1 || true
    wait "$KEPLOY_PID" >/dev/null 2>&1 || true
    exit 1
  fi

  printf '%s' "$body"
}

extract_first_numeric_id() {
  local json_input="$1"

  printf '%s' "$json_input" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -n 1 | grep -oE '[0-9]+'
}

generate_isbn() {
  local seed
  seed="$(( ($(date +%s) + $$ + request_counter) % 10000000000 ))"
  printf '978%010d' "$seed"
}

wait_for_health

# 1
api_call "Health check" "GET" "/health" "200" >/dev/null

# 2
api_call "List books" "GET" "/books?page=1&per_page=3&sort_by=title&order=asc" "200" >/dev/null

# 3
api_call "Search and filter books" "GET" "/books?q=the&min_year=1900&include_stats=true" "200" >/dev/null

# 4 - expected validation error
api_call "Invalid pagination" "GET" "/books?page=0" "400" >/dev/null

# 5
api_call "Get book with reviews" "GET" "/books/1?include_reviews=true" "200" >/dev/null

# 6 - expected 404
api_call "Get missing book" "GET" "/books/9999" "404" >/dev/null

# 7
book_isbn="$(generate_isbn)"
new_book_json="{\"title\":\"Dune\",\"author\":\"Frank Herbert\",\"isbn\":\"$book_isbn\",\"published_year\":1965}"
create_book_response="$(api_call "Create book" "POST" "/books" "201" "$new_book_json")"
BOOK_ID="$(extract_first_numeric_id "$create_book_response")"

if [[ -z "$BOOK_ID" ]]; then
  echo "Error: Failed to capture BOOK_ID from create response"
  exit 1
fi

# 8 - expected duplicate ISBN error
api_call "Create duplicate ISBN" "POST" "/books" "400" "$new_book_json" >/dev/null

# 9
api_call "Patch book" "PATCH" "/books/$BOOK_ID" "200" '{"title":"Dune (Extended Edition)","published_year":1966}' >/dev/null

# 10
updated_book_isbn="$(generate_isbn)"
api_call "Put full book update" "PUT" "/books/$BOOK_ID" "200" "{\"title\":\"Dune: Revised\",\"author\":\"Frank Herbert\",\"isbn\":\"$updated_book_isbn\",\"published_year\":1967}" >/dev/null

# 11
review_1_response="$(api_call "Create first review" "POST" "/books/$BOOK_ID/reviews" "201" '{"reviewer":"qa-team@example.com","rating":5,"comment":"Excellent world building."}')"
REVIEW_ID="$(extract_first_numeric_id "$review_1_response")"

if [[ -z "$REVIEW_ID" ]]; then
  echo "Error: Failed to capture REVIEW_ID from create review response"
  exit 1
fi

# 12
review_2_response="$(api_call "Create second review" "POST" "/books/$BOOK_ID/reviews" "201" '{"reviewer":"integration@example.com","rating":4,"comment":"Great pacing and detail."}')"
REVIEW_2_ID="$(extract_first_numeric_id "$review_2_response")"

if [[ -z "$REVIEW_2_ID" ]]; then
  echo "Error: Failed to capture REVIEW_2_ID from second review"
  exit 1
fi

# 13
api_call "List reviews with pagination" "GET" "/books/$BOOK_ID/reviews?page=1&per_page=1" "200" >/dev/null

# 14
api_call "Update first review" "PATCH" "/books/$BOOK_ID/reviews/$REVIEW_ID" "200" '{"rating":5,"comment":"Still excellent after re-read."}' >/dev/null

# 15
api_call "Analytics top rated" "GET" "/analytics/books/top-rated?limit=3&min_reviews=1" "200" >/dev/null

# 16 - expected validation error
api_call "Invalid review rating" "POST" "/books/$BOOK_ID/reviews" "400" '{"reviewer":"bad-rating@example.com","rating":8,"comment":"Should fail"}' >/dev/null

# 17
api_call "Delete second review" "DELETE" "/books/$BOOK_ID/reviews/$REVIEW_2_ID" "200" >/dev/null

# 18
api_call "Delete created book" "DELETE" "/books/$BOOK_ID" "200" >/dev/null

# 19 - expected 404 after deletion
api_call "Get deleted book" "GET" "/books/$BOOK_ID" "404" >/dev/null

# 20
api_call "Final books listing" "GET" "/books?page=1&per_page=5" "200" >/dev/null

echo "Stopping Keploy recording..."
kill -INT "$KEPLOY_PID" >/dev/null 2>&1 || true
wait "$KEPLOY_PID" >/dev/null 2>&1 || true

echo "Recorded $request_counter API interactions."
echo "Run replay with: keploy test -c \"docker compose up\" --container-name \"$CONTAINER_NAME\" --delay 20"