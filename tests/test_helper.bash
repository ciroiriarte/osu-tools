# test_helper.bash - Common test utilities for bats tests

# Project root directory (works both under bats and standalone)
if [[ -n "${BATS_TEST_DIRNAME:-}" ]]; then
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
else
    export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fi

# Load a script's functions without executing main logic
# Usage: load_script_functions "osu-track-qemu-agents.sh"
load_script_functions() {
    local script="$1"
    local script_path="${PROJECT_ROOT}/${script}"

    # Source only the function definitions by extracting them
    # This avoids running the main script logic
    eval "$(sed -n '/^[a-z_]*() {/,/^}/p' "$script_path")"
}

# Create a temporary directory for test artifacts
setup_temp_dir() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d)"
}

# Cleanup temporary directory
teardown_temp_dir() {
    [[ -d "${TEST_TEMP_DIR:-}" ]] && rm -rf "$TEST_TEMP_DIR"
}

# Mock a command by creating a function
# Usage: mock_command "openstack" "echo 'mocked output'"
mock_command() {
    local cmd="$1"
    local output="$2"
    eval "${cmd}() { ${output}; }"
    export -f "$cmd"
}

# Assert that output contains a string
# Usage: assert_contains "$output" "expected"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle"
        echo "Actual output: $haystack"
        return 1
    fi
}

# Assert that output does not contain a string
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected output NOT to contain: $needle"
        echo "Actual output: $haystack"
        return 1
    fi
}

# Assert exit code
# Usage: run my_command; assert_exit_code 0
assert_exit_code() {
    local expected="$1"
    if [[ "$status" -ne "$expected" ]]; then
        echo "Expected exit code: $expected"
        echo "Actual exit code: $status"
        return 1
    fi
}
