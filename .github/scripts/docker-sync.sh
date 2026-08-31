#!/usr/bin/env bash

set -euo pipefail

SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"
AUTH_DIR="${RUNNER_TEMP:-/tmp}/skopeo-auth"
AUTH_FILE="${AUTH_DIR}/auth.json"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"

exec_skopeo() {
  mkdir -p "$AUTH_DIR"
  if [ ! -s "$AUTH_FILE" ]; then
    printf '{}\n' > "$AUTH_FILE"
  fi
  docker run --rm -i \
    -v "${AUTH_DIR}:/auth" \
    -e REGISTRY_AUTH_FILE=/auth/auth.json \
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

  if ! echo "$password" | docker login "$registry" -u "$username" --password-stdin; then
    echo "::error::Docker login to ${registry} failed"
    return 1
  fi
}

platform_tag() {
  echo "${1//\//-}"
}

platform_os() {
  echo "${1%%/*}"
}

platform_arch() {
  local platform="$1"
  platform="${platform#*/}"
  echo "${platform%%/*}"
}

repo_name_from_source() {
  local repo="$1"
  repo="${repo%:*}"
  echo "${repo##*/}"
}

copy_image() {
  local src="$1"
  local dst="$2"
  local copied_refs=""

  for platform in $PLATFORMS; do
    local os
    local arch
    local tmp
    os="$(platform_os "$platform")"
    arch="$(platform_arch "$platform")"
    tmp="${dst}-$(platform_tag "$platform")"

    echo "Copy ${src} (${platform}) to ${tmp}"
    if ! exec_skopeo copy \
      --override-os "$os" \
      --override-arch "$arch" \
      "docker://${src}" \
      "docker://${tmp}"; then
      echo "::error::Copy ${src} (${platform}) to ${tmp} failed"
      return 1
    fi

    copied_refs="${copied_refs} ${tmp}"
  done

  echo "Create manifest list ${dst}"
  if ! docker buildx imagetools create -t "$dst" $copied_refs; then
    echo "::error::Create manifest list ${dst} failed"
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
  if ! copy_image "$src" "$dst"; then
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
  local dst_repo
  local tags
  dst_repo="$(repo_name_from_source "$src_repo")"
  if ! tags="$(exec_skopeo list-tags "docker://${SOURCE}/${src_repo}" | jq -r '.Tags[]')"; then
    echo "::error::List tags for ${SOURCE}/${src_repo} failed"
    echo "::endgroup::"
    return 1
  fi

  while IFS= read -r tag; do
    if [ -z "$tag" ]; then
      continue
    fi

    if ! copy_image \
      "${SOURCE}/${src_repo}:${tag}" \
      "${DESTINATION}/${dst_scope}/${dst_repo}:${tag}"; then
      echo "::error::Sync ${SOURCE}/${src_repo}:${tag} failed"
      echo "::endgroup::"
      return 1
    fi
  done <<< "$tags"
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
  docker buildx version
  jq --version
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
