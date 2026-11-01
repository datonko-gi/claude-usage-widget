# Changelog

## 1.0.1

- When the API reports no 5-hour limit for an account, the widget shows one weekly row in a smaller card, switching live in both directions.
- A null percent or utilization no longer shows as a 0% row, and neither does a cached null after a restart.

## 1.0.0

First public release.

- Two-row widget: 5-hour session limit and weekly all-models limit, with traffic-light bars, percent used and a countdown to each reset.
- Reads the limits from the Claude Code login already stored on the PC (read-only), with slow, rate-limit-friendly polling and backoff after errors.
- Signed-out state with one-click `claude auth login`.
- Status dot for token problems, network or rate-limit errors, and stale data.
- Scales with Windows display scaling (100% to 200%): geometry and fonts are drawn in design pixels and multiplied by DPI/96.
- A missing or null reset time from the API shows the bar without a countdown instead of an error.
- English UI. Finds `claude` at `%USERPROFILE%\.local\bin\claude.exe` or on PATH.
- `install.bat` and `uninstall.bat` work from any folder, including one with an apostrophe in its name.
