#!/usr/bin/env bats
# test/unit/policy.bats — Policy engine glob matcher tests (EXPERIMENTAL)

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
}

# ---- policy_glob_match tests ----

@test "policy_glob_match: exact match succeeds" {
	policy_glob_match "openai/gpt-4o" "openai/gpt-4o"
}

@test "policy_glob_match: exact mismatch fails" {
	! policy_glob_match "openai/gpt-4o" "openai/gpt-4"
}

@test "policy_glob_match: trailing wildcard matches same provider" {
	policy_glob_match "anthropic/*" "anthropic/claude-3"
}

@test "policy_glob_match: trailing wildcard rejects other provider" {
	! policy_glob_match "anthropic/*" "openai/gpt-4"
}

@test "policy_glob_match: wildcard crosses slash (intentional — * matches /)" {
	policy_glob_match "*/*-preview" "openai/gpt-4-preview"
}

@test "policy_glob_match: case sensitivity — OpenAI/* does not match openai/*" {
	! policy_glob_match "OpenAI/*" "openai/gpt-4"
}

# ---- policy_match_any tests ----

@test "policy_match_any: nonexistent patterns file returns failure" {
	! policy_match_any "openai/gpt-4" "/tmp/nonexistent_patterns_12345"
}

@test "policy_match_any: patterns file with blank lines and matching pattern" {
	local patterns_file
	patterns_file=$(mktemp)
	cat >"$patterns_file" <<'EOF'
openai/*

anthropic/*

google/gemini
EOF
	policy_match_any "anthropic/claude-3" "$patterns_file"
	! policy_match_any "openai/gpt-4" "$patterns_file"
	! policy_match_any "google/gemini-pro" "$patterns_file"
	rm -f "$patterns_file"
}

@test "policy_match_any: no matching pattern returns failure" {
	local patterns_file
	patterns_file=$(mktemp)
	cat >"$patterns_file" <<'EOF'
openai/*
anthropic/*
EOF
	! policy_match_any "google/gemini-pro" "$patterns_file"
	rm -f "$patterns_file"
}

# ---- cmd_policy validate tests ----

@test "cmd_policy validate: invalid policy file returns failure" {
	local invalid_policy
	invalid_policy=$(mktemp)
	cat >"$invalid_policy" <<'EOF'
version: 2
enabled: true
EOF
	run bash -c "export OCPROBE_CONFIG_DIR='$BATS_TEST_DIRNAME/../../config'; source '$BATS_TEST_DIRNAME/../helpers/setup_libs.bash'; OCPROBE_POLICY_OVERRIDE='$invalid_policy' cmd_policy validate"
	assert_failure
	assert_output --partial "INVALID"
	rm -f "$invalid_policy"
}

# ---- policy_write_never_remove_file tests ----

@test "policy_write_never_remove_file: creates empty file when policy disabled" {
	local policy_file
	policy_file=$(mktemp)
	cat >"$policy_file" <<'EOF'
version: 1
enabled: false
never_remove:
  - "openai/gpt-4"
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_RUN_DIR=$(mktemp -d /tmp/ocprobe-test-XXXXXX)
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=0
	policy_write_never_remove_file
	[[ -f "$OCPROBE_RUN_DIR/policy-never_remove.txt" ]]
	[[ ! -s "$OCPROBE_RUN_DIR/policy-never_remove.txt" ]]
	rm -rf "$OCPROBE_RUN_DIR" "$policy_file"
}

@test "policy_write_never_remove_file: writes never_remove patterns when enabled" {
	local policy_file
	policy_file=$(mktemp)
	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
never_remove:
  - "openai/gpt-4"
  - "anthropic/claude-3"
never_add: []
providers: {}
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_RUN_DIR=$(mktemp -d /tmp/ocprobe-test-XXXXXX)
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=1
	OCPROBE_POLICY_FILE="$policy_file"
	policy_write_never_remove_file
	run cat "$OCPROBE_RUN_DIR/policy-never_remove.txt"
	assert_success
	assert_output --partial "openai/gpt-4"
	assert_output --partial "anthropic/claude-3"
	rm -rf "$OCPROBE_RUN_DIR" "$policy_file"
}

# ---- apply_policy_new_filter tests ----

@test "apply_policy_new_filter: excludes never_add models" {
	local policy_file new_file excluded_file
	policy_file=$(mktemp)
	new_file=$(mktemp)
	excluded_file=$(mktemp)

	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
never_remove: []
never_add:
  - "openai/gpt-3.5-turbo"
  - "anthropic/claude-3"
providers: {}
EOF

	cat >"$new_file" <<'EOF'
openai/gpt-4
openai/gpt-3.5-turbo
anthropic/claude-3
google/gemini-pro
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=1
	OCPROBE_POLICY_FILE="$policy_file"
	apply_policy_new_filter "$new_file" "$excluded_file"

	run cat "$excluded_file"
	assert_success
	assert_output --partial "openai/gpt-3.5-turbo"
	assert_output --partial "anthropic/claude-3"

	run cat "$new_file"
	assert_success
	refute_output --partial "openai/gpt-3.5-turbo"
	refute_output --partial "anthropic/claude-3"
	assert_output --partial "openai/gpt-4"
	assert_output --partial "google/gemini-pro"

	rm -f "$new_file" "$excluded_file" "$policy_file"
}

@test "apply_policy_new_filter: excludes by provider exclude pattern" {
	local policy_file new_file excluded_file
	policy_file=$(mktemp)
	new_file=$(mktemp)
	excluded_file=$(mktemp)

	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
never_remove: []
never_add: []
providers:
  openai:
    enabled: true
    include: ["*"]
    exclude:
      - "openai/gpt-3.5-*"
EOF

	cat >"$new_file" <<'EOF'
openai/gpt-4
openai/gpt-3.5-turbo
openai/gpt-3.5-instruct
google/gemini-pro
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=1
	OCPROBE_POLICY_FILE="$policy_file"
	apply_policy_new_filter "$new_file" "$excluded_file"

	run cat "$excluded_file"
	assert_success
	assert_output --partial "openai/gpt-3.5-turbo"
	assert_output --partial "openai/gpt-3.5-instruct"

	run cat "$new_file"
	assert_success
	refute_output --partial "openai/gpt-3.5-turbo"
	refute_output --partial "openai/gpt-3.5-instruct"
	assert_output --partial "openai/gpt-4"
	assert_output --partial "google/gemini-pro"

	rm -f "$new_file" "$excluded_file" "$policy_file"
}

@test "apply_policy_new_filter: respects provider include list (only matching models kept)" {
	local policy_file new_file excluded_file
	policy_file=$(mktemp)
	new_file=$(mktemp)
	excluded_file=$(mktemp)

	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
never_remove: []
never_add: []
providers:
  openai:
    enabled: true
    include:
      - "openai/gpt-4*"
EOF

	cat >"$new_file" <<'EOF'
openai/gpt-4
openai/gpt-4-turbo
openai/gpt-3.5-turbo
google/gemini-pro
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=1
	OCPROBE_POLICY_FILE="$policy_file"
	apply_policy_new_filter "$new_file" "$excluded_file"

	run cat "$excluded_file"
	assert_success
	assert_output --partial "openai/gpt-3.5-turbo"

	run cat "$new_file"
	assert_success
	refute_output --partial "openai/gpt-3.5-turbo"
	assert_output --partial "openai/gpt-4"
	assert_output --partial "openai/gpt-4-turbo"
	assert_output --partial "google/gemini-pro"

	rm -f "$new_file" "$excluded_file" "$policy_file"
}

@test "apply_policy_new_filter: disabled provider excludes all its models" {
	local policy_file new_file excluded_file
	policy_file=$(mktemp)
	new_file=$(mktemp)
	excluded_file=$(mktemp)

	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
never_remove: []
never_add: []
providers:
  openai:
    enabled: false
EOF

	cat >"$new_file" <<'EOF'
openai/gpt-4
openai/gpt-3.5-turbo
google/gemini-pro
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=1
	OCPROBE_POLICY_FILE="$policy_file"
	apply_policy_new_filter "$new_file" "$excluded_file"

	run cat "$excluded_file"
	assert_success
	assert_output --partial "openai/gpt-4"
	assert_output --partial "openai/gpt-3.5-turbo"

	run cat "$new_file"
	assert_success
	refute_output --partial "openai/gpt-4"
	refute_output --partial "openai/gpt-3.5-turbo"
	assert_output --partial "google/gemini-pro"

	rm -f "$new_file" "$excluded_file" "$policy_file"
}

@test "apply_policy_new_filter: does nothing when policy disabled" {
	local policy_file new_file excluded_file
	policy_file=$(mktemp)
	new_file=$(mktemp)
	excluded_file=$(mktemp)

	cat >"$policy_file" <<'EOF'
version: 1
enabled: false
never_remove: []
never_add:
  - "openai/gpt-3.5-turbo"
providers: {}
EOF

	cat >"$new_file" <<'EOF'
openai/gpt-4
openai/gpt-3.5-turbo
google/gemini-pro
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	OCPROBE_POLICY_ENABLED=0
	OCPROBE_POLICY_FILE="$policy_file"
	apply_policy_new_filter "$new_file" "$excluded_file"

	run cat "$excluded_file"
	assert_success
	assert_output ""

	run cat "$new_file"
	assert_success
	assert_output --partial "openai/gpt-4"
	assert_output --partial "openai/gpt-3.5-turbo"
	assert_output --partial "google/gemini-pro"

	rm -f "$new_file" "$excluded_file" "$policy_file"
}
