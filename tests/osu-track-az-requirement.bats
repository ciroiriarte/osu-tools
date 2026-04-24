#!/usr/bin/env bats

# Tests for osu-track-az-requirement.sh

load 'test_helper'

setup() {
    # Disable colors for consistent test output
    export C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''

    # Source the script's functions
    load_script_functions "osu-track-az-requirement.sh"
}

# --- Version and Help ---

@test "script exists and is executable" {
    [[ -x "${PROJECT_ROOT}/osu-track-az-requirement.sh" ]]
}

@test "--version outputs version number" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --version
    assert_exit_code 0
    assert_contains "$output" "osu-track-az-requirement.sh"
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "--help outputs usage information" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --help
    assert_exit_code 0
    assert_contains "$output" "Usage:"
    assert_contains "$output" "Options:"
}

@test "-h is equivalent to --help" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" -h
    assert_exit_code 0
    assert_contains "$output" "Usage:"
}

@test "-v is equivalent to --version" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" -v
    assert_exit_code 0
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

# --- Argument parsing ---

@test "invalid option shows error" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --invalid-option
    assert_exit_code 1
    assert_contains "$output" "unrecognized option"
}

@test "--format accepts valid formats" {
    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --format table --help
    assert_exit_code 0

    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --format csv --help
    assert_exit_code 0

    run "${PROJECT_ROOT}/osu-track-az-requirement.sh" --format json --help
    assert_exit_code 0
}
