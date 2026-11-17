#!/usr/bin/env bats
# ============================================================================
# test/unit/dependency_messages.bats
#
# On a python that cannot import PyYAML/jsonschema, both `make test` and
# `ocprobe doctor` must print the intended actionable message — not a
# ModuleNotFoundError traceback from the config reader itself.
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
}

teardown() {
  rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
}

# A python3 that refuses the yaml/jsonschema import and delegates everything
# else to the real interpreter on this machine.
stub_python_lacking_yaml() {
  local dir="$BATS_TEST_TMPDIR/pystub"
  mkdir -p "$dir"
  local real
  real=$(command -v python3)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *yaml*|*jsonschema*) echo "ModuleNotFoundError: No module named \x27yaml\x27" >&2; exit 1 ;; esac\n'
    printf 'exec %q "$@"\n' "$real"
  } >"$dir/python3"
  chmod +x "$dir/python3"
  printf '%s\n' "$dir/python3"
}

@test "make test with a python lacking PyYAML/jsonschema refuses and names the fix" {
  local stub
  stub=$(stub_python_lacking_yaml)
  run env OCPROBE_PYTHON="$stub" make test-unit
  assert_failure
  assert_output --partial "cannot import yaml/jsonschema"
  assert_output --partial "bin/ocprobe doctor"
}

@test "ocprobe doctor with a python lacking PyYAML/jsonschema prints the actionable message, not a traceback" {
  local stub
  stub=$(stub_python_lacking_yaml)
  local mock="$BATS_TEST_TMPDIR/bin-mock"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 2.3.0" ;; models) exit 0 ;; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  run env OCPROBE_PYTHON="$stub" PATH="$mock:$PATH" bash "$OCPROBE_ROOT/bin/ocprobe" doctor
  assert_failure
  assert_output --partial "missing PyYAML/jsonschema"
  assert_output --partial "make setup"
  assert_output --partial "OCPROBE_PYTHON"
  refute_output --partial "ModuleNotFoundError"
  refute_output --partial "command not found"
}

@test "the config reader itself refuses the same way when the resolver fails" {
  local stub
  stub=$(stub_python_lacking_yaml)
  OCPROBE_PYTHON="$stub" run oc_python_require
  assert_failure
  assert_output --partial "missing PyYAML/jsonschema"
  assert_output --partial "pip install PyYAML jsonschema"
}
