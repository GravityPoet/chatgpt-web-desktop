# Walkthrough

## 2026-06-22

- Inspected `cloak-picker/src/App.tsx`, `cloak-picker/src/styles.css`, and the existing installer `packaging/install-cloak-picker-app.sh`.
- Found the launcher UI was rendering long account names as unbroken text in the detail header and delete dialog.
- Updated account display text to use bounded middle truncation in the sidebar and header while preserving full names in `title` attributes.
- Updated modal titles to use bounded middle truncation and CSS containment so action buttons cannot overflow outside the dialog.
- Added a long account to the development mock data to keep the regression easy to reproduce in browser verification.
