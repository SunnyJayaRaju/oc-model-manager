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
