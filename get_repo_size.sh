#!/bin/bash

# Set the starting directory
SEARCH_DIR=${1:-$(pwd)} # Default to current directory if no argument provided

# Function to check if a directory is a Git repository
is_git_repo() {
  [[ -d "$1/.git" ]]
}

# Function to get the size of Git repository history
get_git_history_size() {
  local repo_size_bytes=$(du -sb "$1/.git" 2>/dev/null | awk '{print $1}')
  echo "$repo_size_bytes"
}

# Function to get the upstream information
get_git_upstream() {
  local upstream=$(git -C "$1" remote -v 2>/dev/null | awk '/fetch/{print $2}' | head -n 1)
  echo "${upstream:-No upstream found}"
}

# Function to color output
color_output() {
  local size_bytes="$1"
  local size_human
  size_human=$(numfmt --to=iec "$size_bytes") # Convert to human-readable format
  if (( size_bytes > 25 * 1024 * 1024 * 1024 )); then # 25GB in bytes
    echo -e "\033[31m$size_human\033[0m" # Red color for > 25GB
  else
    echo "$size_human"
  fi
}

# Recursively find all directories
find "$SEARCH_DIR" -type d | while read -r dir; do

  # Check if it's a Git repository
  if is_git_repo "$dir"; then
    repo_history_size_bytes=$(get_git_history_size "$dir")
    color_size=$(color_output "$repo_history_size_bytes")
    upstream=$(get_git_upstream "$dir")
    echo "Found Git repository: $dir"
    echo "  History Size: $color_size"
    echo "  Upstream: $upstream"
  fi

done
[201~
#!/bin/bash

# Set the starting directory
SEARCH_DIR=${1:-$(pwd)} # Default to current directory if no argument provided

# Function to check if a directory is a Git repository
is_git_repo() {
  [[ -d "$1/.git" ]]
}

# Function to get the size of Git repository history
get_git_history_size() {
  local repo_size_bytes=$(du -sb "$1/.git" 2>/dev/null | awk '{print $1}')
  echo "$repo_size_bytes"
}

# Function to get the upstream information
get_git_upstream() {
  local upstream=$(git -C "$1" remote -v 2>/dev/null | awk '/fetch/{print $2}' | head -n 1)
  echo "${upstream:-No upstream found}"
}

# Function to color output
color_output() {
  local size_bytes="$1"
  local size_human
  size_human=$(numfmt --to=iec "$size_bytes") # Convert to human-readable format
  if (( size_bytes > 25 * 1024 * 1024 * 1024 )); then # 25GB in bytes
    echo -e "\033[31m$size_human\033[0m" # Red color for > 25GB
  else
    echo "$size_human"
  fi
}

# Recursively find all directories
find "$SEARCH_DIR" -type d | while read -r dir; do

  # Check if it's a Git repository
  if is_git_repo "$dir"; then
    repo_history_size_bytes=$(get_git_history_size "$dir")
    color_size=$(color_output "$repo_history_size_bytes")
    upstream=$(get_git_upstream "$dir")
    echo "Found Git repository: $dir"
    echo "  History Size: $color_size"
    echo "  Upstream: $upstream"
  fi

done



