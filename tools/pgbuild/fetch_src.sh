#!/usr/bin/env bash
# Fetch the distro's own PostgreSQL 16 package sources (matching the installed binary version) into /tmp/pgsrc-distro.
# Needs a deb-src entry: /etc/apt/sources.list.d/ubuntu-src.sources (Types: deb-src for archive and security,
# suites noble noble-updates noble-security, components main universe) and a prior `apt-get update`.
set -euo pipefail
VER=${1:-$(dpkg-query -W -f='${Version}' postgresql-16)}
mkdir -p /tmp/pgsrc-distro
cd /tmp/pgsrc-distro
apt-cache showsrc postgresql-16 | grep -E '^Version' || true
apt-get source "postgresql-16=$VER" 2>&1 | tail -5
ls -d /tmp/pgsrc-distro/postgresql-16-*/ 2>/dev/null || true
