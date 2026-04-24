#!/usr/bin/env bats

# Tests for osu-track-qemu-agents.sh

load 'test_helper'

setup() {
    # Disable colors for consistent test output
    export C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''

    # Source the script's functions
    load_script_functions "osu-track-qemu-agents.sh"
}

# --- Version and Help ---

@test "script exists and is executable" {
    [[ -x "${PROJECT_ROOT}/osu-track-qemu-agents.sh" ]]
}

@test "--version outputs version number" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --version
    assert_exit_code 0
    assert_contains "$output" "osu-track-qemu-agents.sh"
    # Version should match semver pattern
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "--help outputs usage information" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --help
    assert_exit_code 0
    assert_contains "$output" "Usage:"
    assert_contains "$output" "Options:"
    assert_contains "$output" "Examples:"
}

@test "-h is equivalent to --help" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" -h
    assert_exit_code 0
    assert_contains "$output" "Usage:"
}

@test "-v is equivalent to --version" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" -v
    assert_exit_code 0
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

# --- format_bool_status function ---

@test "format_bool_status returns checkmark for true" {
    result=$(format_bool_status "true" 1)
    [[ "$result" == "✓" ]]
}

@test "format_bool_status returns cross for false" {
    result=$(format_bool_status "false" 1)
    [[ "$result" == "✗" ]]
}

@test "format_bool_status returns question mark for unknown" {
    result=$(format_bool_status "" 1)
    [[ "$result" == "?" ]]
}

@test "format_bool_status pads output to specified width" {
    result=$(format_bool_status "true" 5)
    # Should be symbol + 4 spaces = 5 chars total
    [[ ${#result} -eq 5 ]]
    [[ "$result" == "✓"* ]]
}

# --- Argument parsing ---

@test "invalid option shows error" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --invalid-option
    assert_exit_code 1
    assert_contains "$output" "unrecognized option"
}

@test "--format accepts valid formats" {
    # These will fail due to missing openstack, but should pass arg parsing
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --format table --help
    assert_exit_code 0

    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --format csv --help
    assert_exit_code 0

    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --format json --help
    assert_exit_code 0
}

@test "--format rejects invalid formats" {
    run "${PROJECT_ROOT}/osu-track-qemu-agents.sh" --format xml
    assert_exit_code 1
    assert_contains "$output" "Invalid format"
}
