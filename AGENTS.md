# Tayfa iPhone app — working notes

- Keep the existing Stoat/Access/LiveKit backend and protocol. The app adds no account system or backend of its own; server changes belong in the desktop and server repository.
- The main agent implements the work. Do not delegate it to other agents without the owner's explicit permission.
- Interface copy is Turkish for now; code, comments and documentation are English. README and contributing documents are English first, then Turkish.
- Never commit tokens, passwords, server addresses, provisioning profiles, certificates or signing credentials. The server origin lives in the gitignored `Configuration/Local.xcconfig`.
- Test on a physical iPhone; do not download simulator runtimes.
- Never equate a successful build, unit tests, fixtures or synthetic media with acceptance between a real desktop and a real iPhone.
- No push, merge, release or App Store Connect upload without explicit authorization.
