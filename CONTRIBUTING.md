# How to Contribute

- Fork the repository
- Create a feature branch
- Submit a pull request explaining what are you improving
- Include tests for the new features
- Update documentation

## Development Requirements

The following tools are required for development and testing:

| Tool | Purpose | Installation |
|------|---------|--------------|
| **make** | Build automation | `sudo apt install make` or `sudo zypper install make` |
| **shellcheck** | Static analysis / linting | `sudo apt install shellcheck` or `sudo zypper install ShellCheck` |
| **bats-core** | Unit testing framework | `sudo apt install bats` or `npm install -g bats` |

## Running Quality Checks

```bash
# Run static analysis (shellcheck)
make lint

# Run unit tests (bats)
make test

# Run both
make check
```

## Writing Tests

Tests are located in `tests/` using the [bats-core](https://github.com/bats-core/bats-core) framework.

- Each script should have a corresponding `.bats` test file
- Use `tests/test_helper.bash` for common utilities
- Focus on testing: version/help flags, argument parsing, pure functions
