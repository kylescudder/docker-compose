#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
YTDLP_PATH="${YTDLP_PATH:-$BIN_DIR/yt-dlp}"
TMDB_API_KEY="${TMDB_API_KEY:-}"
YOUTUBE_API_KEY="${YOUTUBE_API_KEY:-}"

# Radarr environment variables
EVENT_TYPE="${radarr_eventtype:-}"
MOVIE_TITLE="${radarr_movie_title:-}"
MOVIE_YEAR="${radarr_movie_year:-}"
MOVIE_PATH="${radarr_movie_path:-}"

# === FUNCTIONS ===

bootstrap_ytdlp() {
  if [[ ! -x "$YTDLP_PATH" ]]; then
    echo "[TrailerDownloader] ⬇️ yt-dlp not found, downloading..."
    mkdir -p "$BIN_DIR"
    curl -sSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
      -o "$YTDLP_PATH"
    chmod +x "$YTDLP_PATH"
    echo "[TrailerDownloader] ✅ yt-dlp installed at $YTDLP_PATH"
  fi
}

get_trailer_url() {
  local title="$1"
  local year="$2"

  echo "[TrailerDownloader] 🔍 Searching TMDB for \"$title\" ${year:+($year)}" >&2

  local search
  search=$(curl -s --get "https://api.themoviedb.org/3/search/movie" \
    --data-urlencode "api_key=$TMDB_API_KEY" \
    --data-urlencode "query=$title" \
    --data-urlencode "year=$year")

  local movie_id
  movie_id=$(echo "$search" | jq -r '.results[0].id // empty')

  if [[ -z "$movie_id" ]]; then
    echo "[TrailerDownloader] ❌ No TMDB results for $title" >&2
    return 1
  fi

  echo "[TrailerDownloader] ✅ Found TMDB entry for $title (id=$movie_id)" >&2

  local videos
  videos=$(curl -s "https://api.themoviedb.org/3/movie/$movie_id/videos?api_key=$TMDB_API_KEY")

  # Prioritize: Official Trailer > Trailer > Teaser > Clip
  local trailer_key
  trailer_key=$(echo "$videos" | jq -r '
    .results
    | map(select(.site=="YouTube"))
    | sort_by(
        if .official == true and .type == "Trailer" then 0
        elif .type == "Trailer" then 1
        elif .type == "Teaser" then 2
        elif .type == "Clip" then 3
        else 4 end
      )
    | .[0].key // empty
  ')

  if [[ -n "$trailer_key" ]]; then
    echo "[TrailerDownloader] ✅ Found TMDB trailer for $title" >&2
    echo "https://www.youtube.com/watch?v=$trailer_key"
    return 0
  fi

  echo "[TrailerDownloader] ⚠️ No TMDB trailer found for $title, searching YouTube..." >&2

  if [[ -z "$YOUTUBE_API_KEY" ]]; then
    echo "[TrailerDownloader] ⚠️ Skipping YouTube search (no YOUTUBE_API_KEY set)" >&2
    return 1
  fi

  local yt_search
  yt_search=$(curl -s --get "https://www.googleapis.com/youtube/v3/search" \
    --data-urlencode "key=$YOUTUBE_API_KEY" \
    --data-urlencode "q=$title ${year} official trailer" \
    --data-urlencode "part=snippet" \
    --data-urlencode "maxResults=1" \
    --data-urlencode "type=video")

  local yt_id
  yt_id=$(echo "$yt_search" | jq -r '.items[0].id.videoId // empty')

  if [[ -n "$yt_id" ]]; then
    echo "https://www.youtube.com/watch?v=$yt_id"
    return 0
  fi

  return 1
}

download_trailer() {
  local url="$1"
  local output_path="$2"
  local trailer_name="$3"

  local format="bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best"

  if [[ -f "$SCRIPT_DIR/cookies.txt" ]]; then
    echo "[TrailerDownloader] 🍪 Using cookies.txt for YouTube authentication"
    "$YTDLP_PATH" \
      --cookies "$SCRIPT_DIR/cookies.txt" \
      -o "$output_path/$trailer_name" \
      -f "$format" \
      --merge-output-format mp4 \
      "$url"
  else
    "$YTDLP_PATH" \
      -o "$output_path/$trailer_name" \
      -f "$format" \
      --merge-output-format mp4 \
      "$url"
  fi
}

# === MAIN ===
echo "[TrailerDownloader] 🎥 Radarr Trailer Downloader"
echo "[TrailerDownloader] 📌 Event: $EVENT_TYPE"
echo "[TrailerDownloader] 🎬 Movie: $MOVIE_TITLE ($MOVIE_YEAR)"
echo "[TrailerDownloader] 📂 Path: $MOVIE_PATH"

# Handle Radarr "Test" event
if [[ "$EVENT_TYPE" == "Test" ]]; then
  echo "[TrailerDownloader] ✅ Script test successful (no action taken)."
  exit 0
fi

if [[ -z "$TMDB_API_KEY" ]]; then
  echo "[TrailerDownloader] ❌ TMDB_API_KEY is required. Exiting."
  exit 1
fi

# Ensure yt-dlp is available
bootstrap_ytdlp

# Only run on relevant events
if [[ "$EVENT_TYPE" != "Download" && "$EVENT_TYPE" != "MovieAdded" && "$EVENT_TYPE" != "Upgrade" ]]; then
  echo "[TrailerDownloader] ℹ️ Ignoring event type: $EVENT_TYPE"
  exit 0
fi

trailer_url=$(get_trailer_url "$MOVIE_TITLE" "$MOVIE_YEAR" || true)

if [[ -z "$trailer_url" ]]; then
  echo "[TrailerDownloader] ❌ No trailer found for $MOVIE_TITLE"
  exit 0
fi

# Sanitize only for the filename, not the folder
if [[ -n "$MOVIE_YEAR" ]]; then
  safe_name="$(echo "$MOVIE_TITLE ($MOVIE_YEAR)" | sed 's/[^a-zA-Z0-9,& ()-]//g' | tr -s ' ')"
else
  safe_name="$(echo "$MOVIE_TITLE" | sed 's/[^a-zA-Z0-9,& ()-]//g' | tr -s ' ')"
fi

trailer_name="${safe_name}-trailer.mp4"
expected_file="$MOVIE_PATH/$trailer_name"

if [[ -f "$expected_file" ]]; then
  echo "[TrailerDownloader] ⏭️ Skipping $MOVIE_TITLE — trailer already exists"
  exit 0
fi

echo "[TrailerDownloader] 📥 Downloading trailer for $MOVIE_TITLE"
if download_trailer "$trailer_url" "$MOVIE_PATH" "$trailer_name"; then
  echo "[TrailerDownloader] ✅ Trailer saved: $expected_file"
else
  echo "[TrailerDownloader] ❌ Failed to download trailer for $MOVIE_TITLE"
fi