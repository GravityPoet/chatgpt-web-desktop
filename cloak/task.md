# Task

- Fix Cloak Picker launcher layout when account names are long.
- Rebuild and replace the installed `/Applications/Cloak Picker.app`.
- Refresh the Dock-visible installed app after replacement.

# Acceptance

- Long account names do not push launcher controls out of bounds.
- Delete confirmation modal keeps text and buttons inside the dialog.
- `npm --prefix cloak-picker run build` succeeds.
- `packaging/install-cloak-picker-app.sh` installs the rebuilt app successfully.
