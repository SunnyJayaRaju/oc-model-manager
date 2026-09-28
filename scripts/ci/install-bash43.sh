#!/usr/bin/env bash
# Install the bash 4.3 that the "Unit Tests (bash 4.3)" job runs the suite
# under, and put it first on PATH.
#
# Split out of ci.yml because the job now caches the compiled binary: a hit
# costs seconds, a miss costs ~3m20s. actions/cache restores the tree before
# this runs, so the only question here is "is there a usable bash already?".
#
# The source sha256 pin, the build flags, the PATH wiring and the version
# assertion all live here, so the one place that decides what "bash 4.3" means
# is this file. The cache key in ci.yml embeds the same version and hash
# prefix, so bumping either invalidates the cache.
set -euo pipefail

BASH_VERSION="4.3.30"
# Pinned deliberately: a moving download of an ancient shell that is PATH-first
# for a whole test run should not be taken on trust.
BASH_SHA256="317881019bbf2262fb814b7dd8e40632d13c3608d2f237800a8828fbb8a640dd"
PREFIX="${BASH43_PREFIX:-$HOME/bash43}"

have_bash43() {
	[[ -x "$PREFIX/bin/bash" ]] || return 1
	[[ "$("$PREFIX/bin/bash" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" == "4.3" ]]
}

build_bash43() {
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	echo "building bash $BASH_VERSION from the pinned tarball..."
	curl -fsSL -o "$work/bash.tar.gz" \
		"https://ftp.gnu.org/gnu/bash/bash-${BASH_VERSION}.tar.gz"
	(cd "$work" && echo "${BASH_SHA256}  bash.tar.gz" | sha256sum -c -)
	tar xzf "$work/bash.tar.gz" -C "$work"
	# -std=gnu89 and the -W flags are not cosmetic: 4.3 predates C99 and uses
	# K&R definitions plus implicit ioctl/time declarations, which a current
	# gcc or clang rejects outright, so the stock flags fail to build.
	(
		cd "$work/bash-${BASH_VERSION}"
		./configure --prefix="$PREFIX" --without-bash-malloc \
			CFLAGS="-O1 -std=gnu89 -Wno-implicit-function-declaration -fcommon" >/dev/null
		make -j"$(nproc)" >/dev/null
		make install >/dev/null
	)
}

if have_bash43; then
	echo "bash $BASH_VERSION already present at $PREFIX (restored from cache)"
else
	build_bash43
fi

# GITHUB_PATH entries are prepended, but only for LATER steps -- the next step
# gets it, this one does not. So export it here as well: without that, the check
# below (and anything else in this script) would still see the runner's bash and
# wrongly report a failure on a perfectly good install.
export PATH="$PREFIX/bin:$PATH"
echo "$PREFIX/bin" >>"${GITHUB_PATH:-$PWD/.gopath}"

# Fail loudly rather than silently testing the wrong shell. Without this the job
# would go green while proving nothing.
resolved="$(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
if [[ "$resolved" != "4.3" ]]; then
	echo "::error::bash on PATH is $resolved, expected 4.3 -- this job would prove nothing"
	exit 1
fi
echo "bash on PATH: $(command -v bash) ($resolved)"
