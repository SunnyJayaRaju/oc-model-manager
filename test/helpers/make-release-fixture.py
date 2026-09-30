#!/usr/bin/env python3
"""Fixture helper: build a tarball and the JSON/gh/curl mocks verify-release.sh drives.

Used by test/unit/verify_release_script.bats. Everything is local: the tarball
is built with python's tarfile, and the `gh` and `curl` on PATH are stubs that
read this JSON instead of reaching github.com.

Fixture knobs, via the environment:
  FX_VERSION            version under test (default 3.1.3)
  FX_TAG_MISSING        "1" -> the tag ref request 404s
  FX_ANNOTATED          "1" -> the tag is an annotated tag object
  FX_TAG_VERSION        VERSION file content at the tagged commit
  FX_RELEASE_MISSING    "1" -> the release request 404s
  FX_TARBALL_COUNT      number of tarball assets in the release (default 1)
  FX_NO_SHA_ASSET       "1" -> omit the .sha256 asset
  FX_EMPTY_ASSET_URL    "1" -> the .sha256 asset exists but has no download URL
  FX_PUBLISHED_SHA      override the published hash (default: the real one)
  FX_APPLEDOUBLE        "1" -> add a ._* member to the tarball
  FX_NO_RESTORE         "1" -> omit lib/session_restore.py
  FX_FORMULA_URL        url line for the live formula
  FX_FORMULA_SHA        sha256 line for the live formula
  FX_API_ERROR          HTTP status for a non-404 API failure (403/401/500/...)
  FX_API_ERROR_ON       endpoint substring to fail on; all endpoints if unset
"""

import hashlib
import io
import json
import os
import sys
import tarfile

OUT = sys.argv[1]
V = os.environ.get("FX_VERSION", "3.1.3")
os.makedirs(OUT, exist_ok=True)

# --- the tarball ----------------------------------------------------------
tb = os.path.join(OUT, "ocprobe-%s.tar.gz" % V)
members = {
    "ocprobe-%s/VERSION" % V: (V + "\n").encode(),
    "ocprobe-%s/lib/session_restore.py" % V: b"import sys\n",
    "ocprobe-%s/lib/session.sh" % V: b"#!/bin/bash\n",
    "ocprobe-%s/lib/core.sh" % V: b"#!/bin/bash\n",
    "ocprobe-%s/bin/ocprobe" % V: b"#!/bin/bash\n",
}
if os.environ.get("FX_NO_RESTORE") == "1":
    members.pop("ocprobe-%s/lib/session_restore.py" % V)
if os.environ.get("FX_APPLEDOUBLE") == "1":
    members["ocprobe-%s/._VERSION" % V] = b""

with tarfile.open(tb, "w:gz") as t:
    for name, data in members.items():
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))

real_sha = hashlib.sha256(open(tb, "rb").read()).hexdigest()
published = os.environ.get("FX_PUBLISHED_SHA", real_sha)

# --- release JSON ---------------------------------------------------------
tarball_count = int(os.environ.get("FX_TARBALL_COUNT", "1"))
assets = []
for i in range(tarball_count):
    assets.append(
        {
            "name": "ocprobe-%s.tar.gz" % V,
            "browser_download_url": "https://example.invalid/ocprobe-%s.tar.gz" % V,
        }
    )
if os.environ.get("FX_NO_SHA_ASSET") != "1":
    assets.append(
        {
            "name": "ocprobe-%s.tar.gz.sha256" % V,
            "browser_download_url": "https://example.invalid/ocprobe-%s.tar.gz.sha256"
            % V,
        }
    )
if os.environ.get("FX_EMPTY_ASSET_URL") == "1":
    for a in assets:
        if a["name"].endswith(".sha256"):
            a["browser_download_url"] = ""
if tarball_count > 1:
    assets.append(
        {
            "name": "ocprobe-9.9.9.tar.gz",
            "browser_download_url": "https://example.invalid/ocprobe-9.9.9.tar.gz",
        }
    )

json.dump(
    {
        "tag_ref": (
            None
            if os.environ.get("FX_TAG_MISSING") == "1"
            else {
                "ref": "refs/tags/v%s" % V,
                "object": {
                    "type": (
                        "tag" if os.environ.get("FX_ANNOTATED") == "1" else "commit"
                    ),
                    "sha": "0" * 39 + "1",
                },
            }
        ),
        "tag_object_sha": "0" * 39 + "2",
        "tag_version_b64": __import__("base64")
        .b64encode((os.environ.get("FX_TAG_VERSION", V) + "\n").encode())
        .decode(),
        "release": (
            None
            if os.environ.get("FX_RELEASE_MISSING") == "1"
            else {
                "tag_name": "v%s" % V,
                "html_url": "https://example.invalid/releases/v%s" % V,
                "assets": assets,
            }
        ),
        "real_sha": real_sha,
        "published_sha": published,
        "tarball_path": tb,
        "api_error": os.environ.get("FX_API_ERROR") or None,
        "api_error_on": os.environ.get("FX_API_ERROR_ON") or None,
        "formula": (
            'class Ocprobe < Formula\n  desc "x"\n  url "%s"\n  sha256 "%s"\nend\n'
        )
        % (
            os.environ.get(
                "FX_FORMULA_URL",
                "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v%s/ocprobe-%s.tar.gz"
                % (V, V),
            ),
            os.environ.get("FX_FORMULA_SHA", real_sha),
        ),
    },
    open(os.path.join(OUT, "fixture.json"), "w"),
)
print(real_sha)
