#!/usr/bin/env bash
set -Eeuo pipefail

# Install Docker Engine and the Compose plugin on an Ubuntu or Debian host.
# This script deliberately does not remove packages or modify Docker data.

if [[ ${EUID} -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Run as root or install sudo first." >&2
    exit 1
  fi
  exec sudo -- "$0" "$@"
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this Linux distribution (/etc/os-release missing)." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  ubuntu)
    docker_repo_distribution=ubuntu
    docker_repo_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    ;;
  debian)
    docker_repo_distribution=debian
    docker_repo_codename="${VERSION_CODENAME:-}"
    ;;
  *)
    echo "Supported host distributions are Ubuntu and Debian; found '${ID:-unknown}'." >&2
    exit 1
    ;;
esac

if [[ -z "$docker_repo_codename" ]]; then
  echo "Could not determine the distribution codename." >&2
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
  echo "This installer requires apt-get and dpkg-query." >&2
  exit 1
fi

# Keep an existing working Docker installation and its data untouched.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  systemctl enable --now docker
  docker info >/dev/null
  docker compose version
  echo "Docker Engine and the Compose plugin are ready."
  exit 0
fi

# Do not automatically remove another runtime or package set: it may own
# containers or volumes unrelated to this project.
conflicting_packages=()
for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
  package_status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
  if [[ "$package_status" == installed ]]; then
    conflicting_packages+=("$package")
  fi
done
if ((${#conflicting_packages[@]} > 0)); then
  printf 'Conflicting packages are installed: %s\n' "${conflicting_packages[*]}" >&2
  echo "Review the host runtime before installing Docker; this script will not remove packages or containers." >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings

key_tmp="$(mktemp /etc/apt/keyrings/docker.asc.XXXXXX)"
source_tmp="$(mktemp /etc/apt/sources.list.d/docker.sources.XXXXXX)"
trap 'rm -f "$key_tmp" "$source_tmp"' EXIT

curl -fsSL "https://download.docker.com/linux/${docker_repo_distribution}/gpg" -o "$key_tmp"
install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc

cat > "$source_tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_repo_distribution}
Suites: ${docker_repo_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
install -m 0644 "$source_tmp" /etc/apt/sources.list.d/docker.sources

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

docker info >/dev/null
docker compose version
echo "Docker Engine and the Compose plugin are ready."
