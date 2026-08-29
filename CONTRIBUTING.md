# Contributing to oc-model-manager

Thank you for your interest in contributing to oc-model-manager! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to abide by our Code of Conduct:
- Be respectful and inclusive
- Welcome newcomers and help them get started
- Focus on constructive feedback
- Respect differing opinions and experiences

## Getting Started

### Prerequisites

- Bash 4.0+
- Python 3.8+ with PyYAML and jsonschema
- jq
- sqlite3
- bats (for testing)

### Development Setup

```bash
git clone https://github.com/SunnyJayaRaju/oc-model-manager.git
cd oc-model-manager
make dev-install
```

This will:
1. Build the package
2. Install to `~/.local/bin/ocm`
3. Run tests to verify everything works

### Running Tests

```bash
# Run all tests
make test

# Run unit tests only
make test-unit

# Run integration tests only
make test-integration

# Run linting
make lint
```

## Code Style

### Bash Guidelines

- Use `set -euo pipefail` at the top of all scripts
- Use `shellcheck` for linting (run `make lint`)
- Follow Google Shell Style Guide where applicable
- Use meaningful variable names
- Add comments for complex logic
- Use `local` for function-scoped variables
- Use `declare -A` for associative arrays
- Prefer `printf` over `echo` for formatted output

### Python Guidelines

- Use type hints where possible
- Follow PEP 8
- Use `json` module for JSON handling
- Handle exceptions explicitly

### Testing

- Write tests for new features
- Include edge cases
- Test error paths
- Use descriptive test names

## Pull Request Process

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests: `make test`
5. Run linting: `make lint`
6. **Update documentation:** Any PR that adds a feature, changes a command's behavior, or changes a flag MUST update `README.md` and `CHANGELOG.md` in the same PR.
7. Commit with descriptive messages
8. Push to your fork
9. Open a Pull Request

### Commit Message Format

```
type(scope): short description

Longer description if needed

Fixes #issue-number
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Test additions/changes
- `chore`: Maintenance tasks

## Release Process

1. Update VERSION file
2. Update CHANGELOG.md
3. Create git tag: `git tag v2.0.1`
4. Push tag: `git push origin v2.0.1`
5. GitHub Actions will build and release automatically

## Architecture

See [ARCHITECTURE.md](docs/architecture.md) for detailed architecture documentation.

## Security

- Report security vulnerabilities privately to security@oc-model-manager.org
- Do not commit secrets or credentials
- Follow secure coding practices

## License

By contributing, you agree that your contributions will be licensed under the MIT License.