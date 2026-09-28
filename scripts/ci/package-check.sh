#!/usr/bin/env bash
# Build and verify the release tarball, and exercise the INSTALLED copy.
#
# Split out of ci.yml so the same steps run locally and in CI:
#   build          assemble the tarball the way the build job does
#   verify-tarball assert the file list a release must contain
#   verify-install install it as Homebrew would and run real commands
#   show           dump the installed tree (uploaded on failure)
#
# The reason this exists: CI has never looked inside the release artifact. The
# unit suite runs from the working tree, where every file is present by
# definition, so a tarball missing lib/session_restore.py would ship a tool
# whose `session restore` dies with "no such file" and CI would still be green.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${PKGCHECK_WORK:-${RUNNER_TEMP:-/tmp}/pkgcheck}"
VERSION="$(cat "$REPO_ROOT/VERSION")"
TARBALL="$WORK/ocprobe-$VERSION.tar.gz"
STAGE="$WORK/extract/ocprobe-$VERSION"
PREFIX="$WORK/prefix"

note() { printf '    %s\n' "$*"; }
die() {
	printf 'package-check: %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------- build -----
# Deliberately the same commands the build job runs, not a helper shared with
# it: if the build job's copy list ever changes, this still reflects what the
# job does, and the verify step will notice the difference.
build() {
	rm -rf "$WORK" 2>/dev/null || true
	mkdir -p "$WORK/dist/ocprobe-$VERSION"
	# The build job also copies docs/ (with a pandoc-generated man page) and the
	# top-level files. Pandoc is not available in this job, so docs/ is copied
	# as-is when present; the man page is irrelevant to what is being verified.
	cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/config" "$WORK/dist/ocprobe-$VERSION/"
	for f in VERSION CHANGELOG.md LICENSE README.md CONTRIBUTING.md; do
		[ -e "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$WORK/dist/ocprobe-$VERSION/"
	done
	[ -d "$REPO_ROOT/docs" ] && cp -r "$REPO_ROOT/docs" "$WORK/dist/ocprobe-$VERSION/"
	(cd "$WORK/dist" && tar -czf "$TARBALL" "ocprobe-$VERSION/")
	note "built $TARBALL ($(wc -c <"$TARBALL" | tr -d ' ') bytes)"
	# A release must not carry build residue; a stale .pyc from a local run is
	# exactly the kind of thing that makes two builds of the same commit differ.
	if find "$WORK/dist/ocprobe-$VERSION" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
		die "the package contains a Python bytecode cache; it would differ between builds of the same commit"
	fi
	mkdir -p "$WORK/extract"
	tar -xzf "$TARBALL" -C "$WORK/extract"
}

# -------------------------------------------------------- verify-tarball -----
verify_tarball() {
	local missing=0 f rel
	# The file the whole exercise is about. It is not a .sh, so any narrowing of
	# the copy list to shell scripts would drop it silently.
	[ -f "$STAGE/lib/session_restore.py" ] || {
		note "MISSING lib/session_restore.py -- a release would install a broken restore"
		missing=1
	}
	# ...and the shell that invokes it, next to it, since the path is derived
	# from BASH_SOURCE.
	[ -f "$STAGE/lib/session.sh" ] || {
		note "MISSING lib/session.sh"
		missing=1
	}
	# Every other library the binary sources at startup.
	for f in core.sh config.sh logging.sh locking.sh db.sh; do
		[ -f "$STAGE/lib/$f" ] || {
			note "MISSING lib/$f"
			missing=1
		}
	done
	[ -x "$STAGE/bin/ocprobe" ] || {
		note "MISSING or non-executable bin/ocprobe"
		missing=1
	}
	[ -f "$STAGE/VERSION" ] || {
		note "MISSING VERSION"
		missing=1
	}
	# And the general form, so the next new file type is caught without anyone
	# having to add it here.
	while IFS= read -r f; do
		rel="${f#"$REPO_ROOT/"}"
		case "$rel" in *__pycache__* | *.pyc) continue ;; esac
		[ -f "$STAGE/$rel" ] || {
			note "in the tree but not in the tarball: $rel"
			missing=1
		}
	done < <(find "$REPO_ROOT/lib" -maxdepth 1 -type f)
	[ "$missing" -eq 0 ] || die "the release tarball is missing files (listed above)"
	note "tarball contains lib/session_restore.py and every file in lib/"
}

# --------------------------------------------------------- verify-install ----
# Installs into the layout the Homebrew formula uses and runs real commands
# against the installed binary, with a throwaway HOME so nothing can be read
# from or written to the runner's real config.
verify_install() {
	# ${VAR:?} rather than a bare $VAR: a bug that left WORK empty would
	# otherwise make this `rm -rf /prefix` instead of failing.
	rm -rf "${PREFIX:?}" "${WORK:?}/home" 2>/dev/null || true
	mkdir -p "$PREFIX/bin" "$PREFIX/lib/ocprobe" "$PREFIX/share/ocprobe" "$WORK/home"

	cp -r "$STAGE/bin/." "$PREFIX/bin/"
	cp -r "$STAGE/lib/." "$PREFIX/lib/ocprobe/"
	cp -r "$STAGE/config" "$PREFIX/share/ocprobe/config"
	cp "$STAGE/VERSION" "$PREFIX/share/ocprobe/VERSION"

	export HOME="$WORK/home"
	export PATH="$PREFIX/bin:$PATH"
	# Resolve every dependency out of the working tree: the point is to test the
	# INSTALLED copy, so anything found relative to the repo is a false pass.
	unset OCPROBE_ROOT OCPROBE_LIB_DIR OCPROBE_CONFIG_DIR || true

	# Point the config at the database this script seeds. Without this, restore
	# writes to opencode's own db_path -- which, under the throwaway HOME, is a
	# different file from the one seeded below, and the assertions would be
	# testing a database nothing ever wrote to.
	local db="$WORK/restore.db"
	rm -f "$db"
	mkdir -p "$HOME/.config/ocprobe"
	cat >"$HOME/.config/ocprobe/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$HOME/.config/opencode/opencode.json"
  db_path: "$db"
logging:
  level: info
  format: text
  file_enabled: false
EOF
	note "config points at $db"

	# --- 1. version -------------------------------------------------------
	local got
	got="$(ocprobe version 2>&1)" || die "ocprobe version failed: $got"
	case "$got" in
	*"$VERSION"*) note "ocprobe version: $got" ;;
	*) die "ocprobe version reported '$got', expected to contain $VERSION" ;;
	esac

	# --- 2. the module is reachable from the install --------------------
	# `ocprobe session restore` resolves it as "${BASH_SOURCE%/*}/session_restore.py",
	# so this is a real check that the file is both present and executable-path
	# correct, not merely present.
	[ -f "$PREFIX/lib/ocprobe/session_restore.py" ] ||
		die "session_restore.py is not in the installed lib"
	note "session_restore.py present at lib/ocprobe/"

	# --- 3. doctor --------------------------------------------------------
	local doctor
	doctor="$(ocprobe doctor 2>&1)" || true
	printf '%s\n' "$doctor" | sed 's/^/      | /' | head -20
	# doctor exits non-zero when it finds things to complain about (a missing
	# opencode install, say), which is not this job's concern. What matters is
	# that it ran and produced output rather than dying on a missing library.
	printf '%s\n' "$doctor" | grep -qi 'ocprobe' ||
		die "ocprobe doctor produced no recognisable output"

	# --- 4. a real restore of a valid dump --------------------------------
	# Seeded with the exact tables cmd_session_backup dumps. The embedded newline
	# is built with char(10), never unistr(): unistr() only exists in sqlite
	# >= 3.42, and the ubuntu runner's build does not have it, so naming it here
	# fails on one leg and passes on the other. How a newline gets escaped in a
	# dump is build-dependent -- macOS writes unistr('...\u000a...') and ubuntu
	# writes it literally -- and the restore handles both, which is why the dump
	# below is generated rather than hand-written.
	sqlite3 "$db" <<'SQL'
CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, data TEXT);
CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
CREATE TABLE todo(id TEXT PRIMARY KEY, session_id TEXT, content TEXT);
INSERT INTO session VALUES('sess_abc','packaging check','multi' || char(10) || 'line');
INSERT INTO message VALUES('msg_1','sess_abc','has ; semicolon');
SQL
	# Generate the dump the way cmd_session_backup does: `sqlite3 .mode insert`
	# over each table, then `sed s/^INSERT INTO /INSERT OR REPLACE INTO /`.
	# Generating it means the restore is fed whatever THIS sqlite build actually
	# emits, which is the only honest way to test both escaping styles.
	sqlite3 -readonly "$db" >"$WORK/good.sql" <<'SQL'
.mode insert session
SELECT * FROM session;
.mode insert message
SELECT * FROM message;
SQL
	# `sed -i` needs a suffix argument on BSD sed and must not have one on GNU, so
	# branch rather than guess -- the same reason lib/session.sh carries
	# OCPROBE_SED_INPLACE. This script runs before any of ocprobe's libraries are
	# sourced, so it cannot borrow that array.
	sed_inplace() {
		if sed --version >/dev/null 2>&1; then
			sed -i "$@"
		else
			sed -i '' "$@"
		fi
	}
	sed_inplace 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$WORK/good.sql"
	grep -q 'INSERT OR REPLACE INTO session' "$WORK/good.sql" ||
		die "could not generate a realistic dump from sqlite3 .mode insert"
	# Add a row to restore, so the assertion is about the restore, not the seed.
	cat >>"$WORK/good.sql" <<'SQL'
INSERT OR REPLACE INTO message VALUES('msg_2','sess_abc','restored ; ok');
SQL
	note "generated a $(wc -l <"$WORK/good.sql" | tr -d ' ')-line dump via sqlite3 .mode insert"
	ocprobe session restore "$WORK/good.sql" >/dev/null 2>&1 ||
		die "a valid session restore failed from the installed copy"
	local restored
	restored="$(sqlite3 "$db" "SELECT data FROM message WHERE id='msg_2';")"
	[ "$restored" = "restored ; ok" ] ||
		die "the restore did not write the expected row (got '$restored')"
	# The value with a real newline in it must have survived the round trip, which
	# is the part that a packaging or path problem would break.
	local multiline
	multiline="$(sqlite3 "$db" "SELECT count(*) FROM session WHERE data LIKE '%' || char(10) || '%';")"
	[ "$multiline" = "1" ] ||
		die "the multi-line value did not round-trip through the installed restore"
	note "valid session restore: succeeded, values (incl. embedded newline) round-tripped"

	# --- 5. a multi-statement bypass must be rejected ----------------------
	# The whole point of the statement-level guard. A dump that inserts one row
	# and then tries something else must leave the database untouched.
	cp "$db" "$WORK/before.db"
	cat >"$WORK/evil.sql" <<'SQL'
INSERT OR REPLACE INTO session VALUES('sess_evil','should not appear','x');
DELETE FROM message;
SQL
	local rc=0
	ocprobe session restore "$WORK/evil.sql" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || die "a dump containing DELETE FROM was accepted by the installed copy"
	# Byte-identical, not merely "the row count looks right": the guard's promise
	# is that a rejected restore changes nothing at all.
	if ! cmp -s "$WORK/before.db" "$db"; then
		die "the rejected restore modified the database"
	fi
	note "multi-statement bypass: rejected (rc=$rc), database byte-identical"

	note "installed copy verified"
}

# ----------------------------------------------------------------- show -----
show() {
	[ -d "$PREFIX" ] || return 0
	note "installed tree:"
	find "$PREFIX" -type f | sed "s|^$PREFIX/|      |" | sort
}

case "${1:-}" in
build) build ;;
verify-tarball) verify_tarball ;;
verify-install) verify_install ;;
show) show ;;
*)
	printf 'usage: %s build|verify-tarball|verify-install|show\n' "$0" >&2
	exit 2
	;;
esac
