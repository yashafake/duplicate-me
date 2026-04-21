# Contributing to DuplicateMe

Thanks for your interest in improving DuplicateMe.

## Development Setup

1. Install prerequisites:
- macOS
- Swift toolchain (Xcode Command Line Tools or Xcode)
- Node.js 20+ and npm

2. Install dependencies and verify build:

```bash
swift build
swift test
npm install
```

3. Run the desktop shell in development mode:

```bash
npm run desktop:dev
```

## Branch and Commit Guidelines

- Create focused branches from `main`.
- Keep commits small and explain intent in commit messages.
- Avoid unrelated formatting-only changes in feature commits.

## Pull Request Checklist

- [ ] Build passes: `swift build`
- [ ] Tests pass: `swift test`
- [ ] Any new behavior is documented in `README.md`
- [ ] PR description includes motivation and testing notes

## Code Style

- Follow existing Swift style and naming patterns in each module.
- Prefer small, composable functions in scan/fingerprint logic.
- Keep CLI and review-server UX messages clear and actionable.

## Reporting Issues

Please use the GitHub issue templates for bugs and feature ideas.
