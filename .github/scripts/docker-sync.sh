#!/usr/bin/env bash

set -euo pipefail

SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"
AUTH_FILE="${RUNNER_TEMP:-/tmp}/containers-auth.json"

exec_skopeo() {
  mkdir -p "$(dirname "$AUTH_FILE")"
  touch "$AUTH_FILE"
  docker run --rm -i \
    -v "${AUTH_FILE}:/auth.json" \
    -e REGISTRY_AUTH_FILE=/auth.json \
    "$SKOPEO_IMAGE" "$@"
}

login() {
  local registry="$1"
  local credential="$2"
  local required="${3:-false}"

  if [ -z "$credential" ] || [[ "$credential" != *:* ]]; then
    if [ "$required" = "true" ]; then
      echo "::error::Missing or invalid credential for ${registry}. Set DESTINATION_CREDENTIAL as <Username>:<Password> in GitHub Actions secrets."
      return 1
    fi
    return
  fi

  local username="${credential%%:*}"
  local password="${credential#*:}"

  if [ -z "$username" ] || [ -z "$password" ]; then
    if [ "$required" = "true" ]; then
      echo "::error::Missing username or password for ${registry}. Set DESTINATION_CREDENTIAL as <Username>:<Password> in GitHub Actions secrets."
      return 1
    fi
    return
  fi

  echo "Login to ${registry}"
  if ! echo "$password" | exec_skopeo login --password-stdin -u "$username" "$registry"; then
    echo "::error::Login to ${registry} failed"
    return 1
  fi
}

copy_one() {
  local line="$1"
  local src_arg
  local dst_arg
  local unused
  read -r src_arg dst_arg unused <<< "$line"

  if [ -z "${src_arg:-}" ] || [ -z "${dst_arg:-}" ]; then
    echo "::error::Invalid copy input: ${line}"
    return 1
  fi

  local src="${SOURCE}/${src_arg}"
  local dst="${DESTINATION}/${dst_arg}"

  echo "::group::Copy ${src} to ${dst}"
  if ! exec_skopeo copy "docker://${src}" "docker://${dst}"; then
    echo "::error::Copy ${src} to ${dst} failed"
    echo "::endgroup::"
    return 1
  fi
  echo "::endgroup::"
}

sync_one() {
  local line="$1"
  local src_repo
  local dst_scope
  local unused
  read -r src_repo dst_scope unused <<< "$line"

  if [ -z "${src_repo:-}" ] || [ -z "${dst_scope:-}" ]; then
    echo "::error::Invalid sync input: ${line}"
    return 1
  fi

  echo "::group::Sync ${SOURCE}/${src_repo} to ${DESTINATION}/${dst_scope}"
  if ! exec_skopeo sync --src docker --dest docker "${SOURCE}/${src_repo}" "${DESTINATION}/${dst_scope}"; then
    echo "::error::Sync ${SOURCE}/${src_repo} to ${DESTINATION}/${dst_scope} failed"
    echo "::endgroup::"
    return 1
  fi
  echo "::endgroup::"
}

run_with_lines() {
  local input="$1"
  local handler="$2"

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      "$handler" "$line"
    fi
  done <<< "$(echo -e "$input" | tr ';' '\n')"
}

main() {
  echo "::group::Pull skopeo"
  docker pull "$SKOPEO_IMAGE"
  docker -v
  exec_skopeo --version
  echo "::endgroup::"

  echo "::group::Login"
  login "$SOURCE" "${SOURCE_CREDENTIAL:-}"
  login "$DESTINATION" "${DESTINATION_CREDENTIAL:-}" true
  echo "::endgroup::"

  if [ -n "${COPY:-}" ]; then
    run_with_lines "$COPY" copy_one
  fi

  if [ -n "${SYNC:-}" ]; then
    run_with_lines "$SYNC" sync_one
  fi
}

main "$@"
