# Changelog

## 1.0.0

First public release.

- Two-row widget: 5-hour session limit and weekly all-models limit, with traffic-light bars, percent used and a countdown to each reset.
- Reads the limits from the Claude Code login already stored on the PC (read-only), with slow, rate-limit-friendly polling and backoff after errors.
- Signed-out state with one-click `claude auth login`.
- Status dot for token problems, network or rate-limit errors, and stale data.
- English UI. Finds `claude` at `%USERPROFILE%\.local\bin\claude.exe` or on PATH.
- `install.bat` and `uninstall.bat` work from any folder, including one with an apostrophe in its name.
