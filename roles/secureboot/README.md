# secureboot

Self-signed Secure Boot CA + automatic kernel signing via
`kernel-hooks`. Works hand-in-hand with `grub_efi` to produce a fully-
signed boot chain that you enroll into your firmware as PK/KEK/db.

## What it does

1. `apk add sbsigntool openssl kernel-hooks`.
2. Generates `/boot/secureboot/sb.{key,crt}` (RSA 2048, 100-year
   validity, idempotent via `community.crypto.openssl_privatekey` +
   `x509_certificate`).
3. Converts `sb.crt → sb.cer` (DER format for firmware enrollment)
   and copies it to `/efi/sb.cer`.
4. Drops `/etc/kernel-hooks.d/sbsign-<flavor>` for each kernel flavor —
   the script `sbverify`s, and signs+replaces if not already signed.
5. Runs the hook(s) immediately to sign the currently-installed kernel.
6. Signs the bootloader at `/efi/EFI/boot/bootx64.efi` (idempotent
   via `sbverify`).

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `secureboot_dir` | `/boot/secureboot` | Where the CA lives. |
| `secureboot_cn` | `"Alpine SB CA"` | Override per-host (e.g. `"Example SB CA"`). |
| `secureboot_kernel_flavors` | `[lts]` | Add `edge` if you also run linux-edge. |
| `secureboot_bootloader` | `/efi/EFI/boot/bootx64.efi` | Path matches grub_efi role's fallback. |

## Dependencies

- `grub_efi` role (so the bootloader exists at the configured path).
- The host's firmware UI (manual step) — you have to enroll
  `/efi/sb.cer` as PK/KEK/db before enabling Secure Boot.

## Example

```yaml
# host_vars/desktop.yml
secureboot_cn: "Example SB CA"
secureboot_kernel_flavors:
  - lts
  - edge
```

## Enrollment workflow (one-time)

1. Run the role; it produces `/efi/sb.cer`.
2. Reboot, enter firmware setup.
3. Disable Secure Boot if it's on.
4. Clear existing PK/KEK/db (or keep Microsoft's — your choice).
5. Import `sb.cer` (from the ESP, or copy to a USB) as PK, KEK, *and*
   db.
6. Enable Secure Boot, save, reboot.

## Troubleshooting

- **`sbverify: signature verification failed`** — the kernel was
  re-installed without the hook firing. Re-run `apk fix kernel-hooks`
  on the host or just re-apply the role.
- **Boot fails with "Verification failed: Security Violation"** —
  either the bootloader or the kernel isn't signed. Check
  `sbverify --cert /boot/secureboot/sb.crt /boot/vmlinuz-lts` on the
  host.
- **Want to rotate the CA** — generate new keys, re-sign everything,
  re-enroll into firmware. Keep the old cert in db until the new one
  is verified working.
