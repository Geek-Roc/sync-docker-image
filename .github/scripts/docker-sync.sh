#!/usr/bin/env bash

set -euo pipefail

PLATFORMS=(
  "linux/amd64"
  "linux/arm/v6"
  "linux/arm/v7"
  "linux/arm64"
)

REGCTL_IMAGE="${REGCTL_IMAGE:-ghcr.io/regclient/regctl:latest}"
REGCTL=(docker run --rm -v "${HOME}/.docker:/home/nonroot/.docker:ro" "${REGCTL_IMAGE}")

login() {
  local registry="$1"
  local credential="$2"

  if [ -z "$credential" ] || [[ "$credential" != *:* ]]; then
    return
  fi

  local username="${credential%%:*}"
  local password="${credential#*:}"

  if [ -z "$username" ] || [ -z "$password" ]; then
    return
  fi

  echo "Login to ${registry}"
  echo "$password" | docker login "$registry" -u "$username" --password-stdin
}

platform_tag() {
  echo "${1//\//-}"
}

copy_platform_images() {
  local src="$1"
  local dst="$2"
  local copied_refs=()
  local copied_platforms=()

  for platform in "${PLATFORMS[@]}"; do
    local tmp="${dst}-$(platform_tag "$platform")"

    echo "Copy ${src} (${platform}) to ${tmp}"
    if "${REGCTL[@]}" image copy --platform "$platform" "$src" "$tmp"; then
      copied_refs+=(--ref "$tmp")
      copied_platforms+=(--platform "$platform")
    else
      echo "::warning::Skip ${src} (${platform}), platform is unavailable or failed to copy"
    fi
  done

  if [ "${#copied_refs[@]}" -eq 0 ]; then
    echo "::error::No platform images copied for ${src}"
    return 1
  fi

  echo "Create manifest list ${dst}"
  "${REGCTL[@]}" index create "$dst" \
    --media-type application/vnd.docker.distribution.manifest.list.v2+json \
    "${copied_refs[@]}" \
    "${copied_platforms[@]}"
}

copy_one() {
  local line="$1"
  local arr
  read -r -a arr <<< "$line"

  if [ "${#arr[@]}" -lt 2 ]; then
    echo "::error::Invalid copy input: ${line}"
    return 1
  fi

  local src="${SOURCE}/${arr[0]}"
  local dst="${DESTINATION}/${arr[1]}"

  echo "::group::Copy ${src} to ${dst}"
  copy_platform_images "$src" "$dst"
  echo "::endgroup::"
}

repo_name_from_source() {
  local repo="$1"
  repo="${repo%:*}"
  echo "${repo##*/}"
}

sync_one() {
  local line="$1"
  local arr
  read -r -a arr <<< "$line"

  if [ "${#arr[@]}" -lt 2 ]; then
    echo "::error::Invalid sync input: ${line}"
    return 1
  fi

  local src_repo="${arr[0]%:*}"
  local dst_scope="${arr[1]}"
  local dst_repo
  dst_repo="$(repo_name_from_source "$src_repo")"

  echo "::group::List tags for ${SOURCE}/${src_repo}"
  local tags
  tags="$("${REGCTL[@]}" tag ls "${SOURCE}/${src_repo}")"
  echo "::endgroup::"

  while IFS= read -r tag; do
    if [ -z "$tag" ]; then
      continue
    fi

    copy_platform_images \
      "${SOURCE}/${src_repo}:${tag}" \
      "${DESTINATION}/${dst_scope}/${dst_repo}:${tag}"
  done <<< "$tags"
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
  docker pull "$REGCTL_IMAGE"

  login "$SOURCE" "${SOURCE_CREDENTIAL:-}"
  login "$DESTINATION" "${DESTINATION_CREDENTIAL:-}"

  if [ -n "${COPY:-}" ]; then
    run_with_lines "$COPY" copy_one
  fi

  if [ -n "${SYNC:-}" ]; then
    run_with_lines "$SYNC" sync_one
  fi
}

main "$@"
