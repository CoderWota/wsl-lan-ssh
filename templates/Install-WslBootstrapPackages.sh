#!/bin/sh
set -eu

required_base_packages="__REQUIRED_BASE_PACKAGES__"
bootstrap_packages="__BOOTSTRAP_PACKAGES__"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Required package manager 'apt-get' is missing from this Ubuntu installation." >&2
  exit 1
fi

for package_name in $required_base_packages; do
  if ! dpkg-query -W -f='${Status}\n' "$package_name" 2>/dev/null | grep -qx 'install ok installed'; then
    echo "Required base package '$package_name' is missing. The managed Ubuntu distro is not in a supported state." >&2
    exit 1
  fi
done

missing_packages=""
for package_name in $bootstrap_packages; do
  if ! dpkg-query -W -f='${Status}\n' "$package_name" 2>/dev/null | grep -qx 'install ok installed'; then
    missing_packages="$missing_packages $package_name"
  fi
done

missing_packages="$(printf '%s' "$missing_packages" | xargs)"
if [ -z "$missing_packages" ]; then
  echo "All requested Ubuntu bootstrap packages are already installed."
  exit 0
fi

echo "Installing missing Ubuntu packages: $missing_packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y $missing_packages
