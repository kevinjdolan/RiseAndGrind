#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
project_spec="${repository_root}/project.yml"

usage() {
  echo "Usage: $0 [build-number] [marketing-version]" >&2
  echo "Without a build number, the current build number is incremented." >&2
}

if (( $# > 2 )); then
  usage
  exit 64
fi

cd "${repository_root}"

current_build="$(
  sed -nE 's/^[[:space:]]+CURRENT_PROJECT_VERSION: "([0-9]+)"$/\1/p' \
    "${project_spec}"
)"

if [[ -z "${current_build}" ]]; then
  echo "Could not find one numeric CURRENT_PROJECT_VERSION in project.yml." >&2
  exit 65
fi

build_number="${1:-$((current_build + 1))}"
marketing_version="${2:-}"

if [[ ! "${build_number}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 64
fi

if [[ -n "${marketing_version}" && \
      ! "${marketing_version}" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Marketing version must look like 1.0 or 1.0.0." >&2
  exit 64
fi

build_setting_count="$(
  grep -Ec '^[[:space:]]+CURRENT_PROJECT_VERSION:' "${project_spec}"
)"

if [[ "${build_setting_count}" != "1" ]]; then
  echo "Expected exactly one CURRENT_PROJECT_VERSION setting." >&2
  exit 65
fi

sed -i '' -E \
  "s/^([[:space:]]+CURRENT_PROJECT_VERSION:).*/\\1 \"${build_number}\"/" \
  "${project_spec}"

if [[ -n "${marketing_version}" ]]; then
  version_setting_count="$(
    grep -Ec '^[[:space:]]+MARKETING_VERSION:' "${project_spec}"
  )"

  if [[ "${version_setting_count}" != "1" ]]; then
    echo "Expected exactly one MARKETING_VERSION setting." >&2
    exit 65
  fi

  sed -i '' -E \
    "s/^([[:space:]]+MARKETING_VERSION:).*/\\1 \"${marketing_version}\"/" \
    "${project_spec}"
fi

xcodegen generate --spec "${project_spec}"

resolved_version="$(
  sed -nE 's/^[[:space:]]+MARKETING_VERSION: "([^"]+)"$/\1/p' \
    "${project_spec}"
)"

echo "Prepared Rise & Grind ${resolved_version} (${build_number}) for archiving."
