# flatpak

Flatpak runtime + system + per-user remotes.

## What it does

1. `apk add flatpak`.
2. Adds each `flatpak_system_remotes` entry as a `system` remote
   (idempotent via `community.general.flatpak_remote`).
3. Adds each `flatpak_user_remotes` entry as a `user` remote, run as
   `desktop_user` via `become_user`.

## Variables

```yaml
flatpak_system_remotes:
  - { name: flathub,      url: "https://dl.flathub.org/repo/flathub.flatpakrepo" }
  - { name: flathub-beta, url: "https://dl.flathub.org/beta-repo/flathub-beta.flatpakrepo" }

flatpak_user_remotes:    # default empty
  - { name: my-remote, url: "https://example.com/remote.flatpakrepo" }
```

## Dependencies

- `community.general` collection.
- `users` role for `desktop_user` (when adding user remotes).

## Troubleshooting

- **`flatpak remote-add` fails: GPG verification failed** — for
  remotes that don't ship a GPG key, add `--no-gpg-verify` via the
  `flatpak_init_options` module argument. Edit the role to pass it.
- **User-scope remote not visible** — confirm `become: true` +
  `become_user: <desktop_user>` ran cleanly. Check
  `flatpak --user remotes` as that user.
