# dev_stack

Developer toolchain for the desktop: compilers (gcc/clang/rust/crystal),
build tools, editors, container runtimes, qemu/virt-manager,
miscellaneous CLI tooling.

## What it does

1. `apk add` the package list in `defaults/main.yml` (~100 packages).
2. Enables `docker` and `libvirtd` at the `default` runlevel.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `dev_packages` | full list | Override to trim. |

## Dependencies

None beyond apk, but heavy. Don't apply to a server.

## Example

```yaml
# host_vars/lite-laptop.yml
dev_packages:
  - git
  - neovim
  - htop
  - ripgrep
  - fd
```

## Troubleshooting

- **`apk: package linux-headers required by ...`** — some kernel-module
  packages (zfs, etc.) want headers. Either install them on this host
  via `kernel_packages` in group_vars, or skip the offending package.
- **`libvirtd` won't start** — confirm the user is in the `libvirt`
  group (the `users` role's `desktop_user_groups` should include it).
- **Conflicts between rust toolchains** — Alpine ships both `rust`
  (the compiler+std) and `rustup` (a multi-toolchain manager); they
  can both be installed, but `rustup` is what `cargo install`s use.
