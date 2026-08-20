#!/bin/bash
# Pelican Panel – Incremental Git-Based Update Script
# Applies only the files that changed between your current version and the latest release.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 0a.  Dependency check – git must be available
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
  echo "git is not installed or not in PATH. Please install git and re-run this script." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 0b.  Root check
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

PANEL_REPO="https://github.com/pelican/panel.git"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# ─────────────────────────────────────────────────────────────────────────────
# 0c.  Log file – tee all output so we can upload it later
# ─────────────────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/pelican_update_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Update log: $LOG_FILE"

# Upload log to logs.pelican.dev and print the URL.
upload_log() {
  if ! command -v curl &>/dev/null; then
    echo "curl not found – cannot upload log." >&2
    return 1
  fi
  local content
  content=$(cat "$LOG_FILE")
  local response
  response=$(curl -s -w "\n%{http_code}" \
    -F "c=$content" \
    -F "e=14d" \
    "https://logs.pelican.dev")
  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" = "200" ]; then
    # Parse the url field from JSON response
    local paste_url
    paste_url=$(echo "$body" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
    if [ -n "$paste_url" ]; then
      echo ""
      echo "  ✓ Log uploaded successfully."
      echo "  URL: $paste_url"
      echo ""
    else
      echo "Uploaded but could not parse URL from response: $body"
    fi
  else
    echo "Upload failed (HTTP $http_code): $body" >&2
    return 1
  fi
}

# Offer to upload the log – called on success and on error traps.
offer_log_upload() {
  echo ""
  echo "Log saved to: $LOG_FILE"
  echo "Note: the log contains command output, file paths, and version information from this run."
  read -rp "Upload log to logs.pelican.dev to share with the Pelican team? (y/n) [n]: " upload_confirm </dev/tty || true
  upload_confirm="${upload_confirm:-n}"
  if [[ "${upload_confirm,,}" == "y" ]]; then
    upload_log
  fi
}

# Trap unexpected exits so we always offer the upload on failure.
_error_handler() {
  local exit_code=$?
  echo ""
  echo "Script exited unexpectedly (exit code $exit_code)."
  offer_log_upload
  exit "$exit_code"
}
trap '_error_handler' ERR

# ─────────────────────────────────────────────────────────────────────────────
# 1.  Installation directory
# ─────────────────────────────────────────────────────────────────────────────
read -rp "Enter the directory for the panel location [/var/www/pelican]: " install_dir
install_dir="${install_dir:-/var/www/pelican}"

if [ ! -d "$install_dir" ]; then
  echo "Directory $install_dir does not exist. Exiting..."
  exit 1
fi

env_file="$install_dir/.env"
if [ ! -f "$env_file" ]; then
  echo "File $env_file does not exist. Exiting..."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Owner / group (auto-detect with fallback)
# ─────────────────────────────────────────────────────────────────────────────
owner=$(stat -c '%U' "$install_dir" 2>/dev/null || echo "www-data")
read -rp "Enter the owner of the files [$owner]: " owner_input
owner="${owner_input:-$owner}"

group=$(stat -c '%G' "$install_dir" 2>/dev/null || echo "www-data")
read -rp "Enter the group of the files [$group]: " group_input
group="${group_input:-$group}"

# ─────────────────────────────────────────────────────────────────────────────
# 3.  Detect current version
# ─────────────────────────────────────────────────────────────────────────────
current_version=""

config_app="$install_dir/config/app.php"
if [ -f "$config_app" ]; then
  current_version=$(grep -oP "'version'\s*=>\s*'\K[^']+" "$config_app" | tr -d '[:space:]')
fi

if [ -z "$current_version" ]; then
  read -rp "Could not detect current version from config/app.php. Enter it manually (e.g. v1.0.0): " current_version
fi

# Normalise: ensure leading 'v'
[[ "$current_version" != v* ]] && current_version="v${current_version}"
echo "Current installed version: $current_version"

# ─────────────────────────────────────────────────────────────────────────────
# 4.  Clone / update a local mirror of the panel repo
# ─────────────────────────────────────────────────────────────────────────────
tmp_repo="/tmp/pelican_panel_repo_${TIMESTAMP}"
echo ""
echo "Cloning Pelican Panel repository to $tmp_repo (this may take a moment)..."
git clone --bare "$PANEL_REPO" "$tmp_repo" --quiet
cd "$tmp_repo"

# Fetch all tags
git fetch --tags --quiet

# ─────────────────────────────────────────────────────────────────────────────
# 5.  Collect and sort version tags
# ─────────────────────────────────────────────────────────────────────────────
mapfile -t all_tags < <(git tag -l 'v*' | sort -V)

if [ ${#all_tags[@]} -eq 0 ]; then
  echo "No version tags found in the repository. Exiting..."
  rm -rf "$tmp_repo"
  exit 1
fi

latest_version="${all_tags[-1]}"
echo "Latest available version: $latest_version"

if [ "$current_version" = "$latest_version" ]; then
  echo "Panel is already up to date ($current_version). Nothing to do."
  rm -rf "$tmp_repo"
  trap - ERR
  offer_log_upload
  exit 0
fi

# Build the ordered list of versions strictly newer than current
upgrade_path=()
found_current=false
for tag in "${all_tags[@]}"; do
  if [ "$tag" = "$current_version" ]; then
    found_current=true
    continue
  fi
  if $found_current; then
    upgrade_path+=("$tag")
  fi
done

if [ ${#upgrade_path[@]} -eq 0 ]; then
  if ! $found_current; then
    echo "WARNING: Current version tag '$current_version' not found in repository."
    echo "Cannot determine safe upgrade path. Exiting."
  else
    echo "Panel is already at the latest known tag ($current_version). Nothing to do."
  fi
  rm -rf "$tmp_repo"
  exit 1
fi

echo ""
echo "Upgrade path:"
prev="$current_version"
for v in "${upgrade_path[@]}"; do
  echo "  $prev -> $v"
  prev="$v"
done

# ─────────────────────────────────────────────────────────────────────────────
# 6.  DB connection check
# ─────────────────────────────────────────────────────────────────────────────
db_connection=$(grep "^DB_CONNECTION=" "$env_file" | cut -d '=' -f2 | tr -d "\"'" || echo "sqlite")
db_connection="${db_connection:-sqlite}"
echo ""
echo "DB_CONNECTION: $db_connection"

db_database=""
if [ "$db_connection" = "sqlite" ]; then
  db_database=$(grep "^DB_DATABASE=" "$env_file" | cut -d '=' -f2 | tr -d "\"'" || echo "database.sqlite")
  db_database="${db_database:-database.sqlite}"
  [[ "$db_database" != *.sqlite ]] && db_database="${db_database}.sqlite"
  echo "SQLite database: $db_database"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7.  Backup
# ─────────────────────────────────────────────────────────────────────────────
read -rp "Do you want to create a backup before updating? (y/n) [y]: " backup_confirm
backup_confirm="${backup_confirm:-y}"
if [[ "${backup_confirm,,}" != "y" ]]; then
  echo "Backup canceled. Aborting."
  rm -rf "$tmp_repo"
  exit 1
fi

backup_dir="$install_dir/backup_${TIMESTAMP}"
mkdir -p "$backup_dir/storage/app"
echo "Backup directory: $backup_dir"

cp -a "$env_file" "$backup_dir/.env.backup"
echo "  ✓ Backed up .env"

if [ -d "$install_dir/storage/app/public" ]; then
  cp -a "$install_dir/storage/app/public" "$backup_dir/storage/app/"
  echo "  ✓ Backed up storage/app/public"
fi

if [ "$db_connection" = "sqlite" ] && [ -f "$install_dir/database/$db_database" ]; then
  cp -a "$install_dir/database/$db_database" "$backup_dir/${db_database}.backup"
  echo "  ✓ Backed up SQLite database"
elif [ "$db_connection" != "sqlite" ]; then
  echo ""
  echo "WARNING: MySQL/MariaDB databases are NOT backed up by this script."
  read -rp "Pause now and make your own DB backup, then continue? (y/n) [y]: " db_warn
  db_warn="${db_warn:-y}"
  if [[ "${db_warn,,}" != "y" ]]; then
    echo "Update canceled."
    rm -rf "$tmp_repo"
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8.  Paths that are never overwritten
# ─────────────────────────────────────────────────────────────────────────────
PROTECTED_PATHS=(
  ".env"
  "storage/app/public"
)
# Add the dynamic SQLite path if applicable
if [ "$db_connection" = "sqlite" ] && [ -n "$db_database" ]; then
  PROTECTED_PATHS+=("database/$db_database")
fi

is_protected() {
  local file="$1"
  for protected in "${PROTECTED_PATHS[@]}"; do
    if [[ "$file" == "$protected" || "$file" == "$protected/"* ]]; then
      return 0
    fi
  done
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 9.  Apply each version hop
# ─────────────────────────────────────────────────────────────────────────────
needs_composer=false
needs_migrations=false
any_changes=false

prev_tag="$current_version"

for next_tag in "${upgrade_path[@]}"; do
  echo ""
  echo "-----------------------------------------"
  echo " Applying changes: $prev_tag -> $next_tag"
  echo "-----------------------------------------"

  # Collect changed, added, deleted files between the two tags.
  # For renames (R*) git outputs: STATUS  OLD_PATH  NEW_PATH
  # We emit: STATUS OLD_PATH NEW_PATH  (space-separated, new path may be empty for non-renames)
  diff_output=$(git diff --name-status "${prev_tag}..${next_tag}" 2>&1) || {
    echo "  [ERROR]  git diff failed for ${prev_tag}..${next_tag}: $diff_output"
    prev_tag="$next_tag"
    continue
  }
  mapfile -t changed_files < <(echo "$diff_output" | awk '{print $1, $2, ($3 != "" ? $3 : $2)}')

  if [ ${#changed_files[@]} -eq 0 ]; then
    echo "  No file changes detected between $prev_tag and $next_tag."
    prev_tag="$next_tag"
    continue
  fi

  any_changes=true
  added=0; modified=0; deleted=0; skipped=0

  for entry in "${changed_files[@]}"; do
    status="${entry%% *}"
    rest="${entry#* }"
    old_file="${rest%% *}"
    new_file="${rest##* }"
    # For non-rename entries, old_file == new_file
    file="$new_file"

    # Skip protected paths
    if is_protected "$file"; then
      echo "  [SKIP ]  $file  (protected)"
      ((skipped++)) || true
      continue
    fi

    case "$status" in
      A|M|C*)
        # Added, Modified, Copied -> extract from next_tag and write
        dest="$install_dir/$file"
        dest_dir=$(dirname "$dest")
        mkdir -p "$dest_dir"

        git show "${next_tag}:${file}" > "$dest" 2>/dev/null && {
          if [ "$status" = "A" ]; then
            echo "  [ADD  ]  $file"
            ((added++)) || true
          else
            echo "  [MOD  ]  $file"
            ((modified++)) || true
          fi
        } || {
          echo "  [WARN ]  Could not extract $file from $next_tag – skipping"
          ((skipped++)) || true
        }

        # Flag post-update steps if relevant files changed
        [[ "$file" == composer.json || "$file" == composer.lock ]] && needs_composer=true
        [[ "$file" == database/migrations/* ]] && needs_migrations=true
        ;;

      R*)
        # Renamed -> remove old path, write new path
        if ! is_protected "$old_file" && [ -f "$install_dir/$old_file" ]; then
          rm -f "$install_dir/$old_file"
          echo "  [DEL  ]  $old_file  (renamed)"
          ((deleted++)) || true
        fi

        dest="$install_dir/$file"
        dest_dir=$(dirname "$dest")
        mkdir -p "$dest_dir"

        git show "${next_tag}:${file}" > "$dest" 2>/dev/null && {
          echo "  [ADD  ]  $file  (renamed from $old_file)"
          ((added++)) || true
        } || {
          echo "  [WARN ]  Could not extract $file from $next_tag – skipping"
          ((skipped++)) || true
        }

        [[ "$file" == composer.json || "$file" == composer.lock ]] && needs_composer=true
        [[ "$file" == database/migrations/* ]] && needs_migrations=true
        ;;

      D)
        # Deleted
        if [ -f "$install_dir/$file" ]; then
          rm -f "$install_dir/$file"
          echo "  [DEL  ]  $file"
          ((deleted++)) || true
        fi
        ;;

      *)
        echo "  [SKIP ]  $file  (unhandled status: $status)"
        ((skipped++)) || true
        ;;
    esac
  done

  echo ""
  echo "  Summary for $prev_tag -> $next_tag:"
  echo "    Added:    $added"
  echo "    Modified: $modified"
  echo "    Deleted:  $deleted"
  echo "    Skipped:  $skipped"

  prev_tag="$next_tag"
done

# Cleanup temp repo
rm -rf "$tmp_repo"

# ─────────────────────────────────────────────────────────────────────────────
# 10.  Post-update steps
# ─────────────────────────────────────────────────────────────────────────────
if ! $any_changes; then
  echo ""
  echo "No file changes were applied. Panel may already be at $latest_version."
  trap - ERR
  offer_log_upload
  exit 0
fi

cd "$install_dir"

if $needs_composer || [ ! -d "$install_dir/vendor" ]; then
  echo ""
  echo "Running Composer..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
fi

echo ""
echo "Clearing & optimizing cache..."
php artisan optimize:clear
php artisan filament:optimize

echo ""
echo "Ensuring storage symlinks..."
php artisan storage:link

if $needs_migrations; then
  echo ""
  echo "Running database migrations..."
  php artisan migrate --seed --force
else
  # Always run migrations to be safe; migrations are idempotent
  echo ""
  echo "Running database migrations (idempotent)..."
  php artisan migrate --force
fi

echo ""
echo "Restarting queue workers..."
php artisan queue:restart

# ─────────────────────────────────────────────────────────────────────────────
# 11.  Permissions
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Setting permissions..."

chmod_cmd="chmod -R 755 \"$install_dir\"/storage/* \"$install_dir\"/bootstrap/cache"
chown_cmd="chown -R $owner:$group \"$install_dir\""

chmod -R 755 "$install_dir"/storage/* "$install_dir"/bootstrap/cache \
  || echo "WARNING: chmod failed – run manually: sudo $chmod_cmd"
chown -R "$owner:$group" "$install_dir" \
  || echo "WARNING: chown failed – run manually: sudo $chown_cmd"

# ─────────────────────────────────────────────────────────────────────────────
# 12.  Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo " Panel updated: $current_version -> $latest_version"
echo "=================================================="
echo ""
echo "Backup saved to: $backup_dir"
echo ""
echo "If you had custom themes installed, rebuild assets manually:"
echo "  cd $install_dir && yarn install && yarn build"
echo ""
echo "To verify permissions:"
echo "  sudo $chmod_cmd"
echo "  sudo $chown_cmd"

# Disable the ERR trap so a clean exit doesn't trigger the error handler.
trap - ERR
offer_log_upload

exit 0
