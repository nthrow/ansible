# Conventions

How roles are structured, named, and composed. Follow these when
adding a new role.

## Role directory layout

```
roles/<name>/
├── README.md              # always
├── defaults/main.yml      # always, even if just `---`
├── tasks/main.yml         # always
├── handlers/main.yml      # if any task uses `notify:`
├── templates/             # j2 files
└── files/                 # static files
```

Optional but encouraged: `vars/main.yml` for derived constants the
role uses internally (NOT user-facing config — that goes in defaults).

## Naming

- **Role names**: lowercase, snake_case, descriptive. `cdn_varnish`,
  `monitoring_agent`, `docker_host`. Avoid generic names like
  `nginx` — we have nginx in three contexts (edge, varnish-side,
  origin) and a single `nginx` role would be a mess.
- **Variable names**: prefix with the role's name to avoid collisions
  in the global var namespace. `cdn_edge_anycast_v4`,
  `monitoring_bind_addr`. Exceptions:
  - Vars in `group_vars/all.yml` that are genuinely fleet-wide can
    skip the prefix (`base_packages`, `apk_repositories`).
  - The firewall DSL (`firewall_allow_tcp` etc.) is the firewall
    role's "API" and intentionally reads cleanly without a prefix.
- **Handler names**: lowercase verb phrase. `restart docker`,
  `reload nginx`, `re-export nfs`. Match the verb to the action's
  blast radius (`reload` = SIGHUP, `restart` = full daemon cycle).

## Idempotency

Every task should be safely re-runnable. Specifically:

- `apk` package installs: `state: present` not `state: latest` (don't
  silently upgrade between runs unless that's the explicit goal).
- File renders: use `copy:`/`template:` modules, not shell `echo >`.
- Config validation: prefer `validate:` on `template:` — it runs the
  syntax check before swapping the file. nginx, sshd, varnish all
  support this pattern.
- Side-effecting commands: gate with `creates:`/`removes:` so they
  only run when the target file is missing/present.

If you find yourself reaching for `command:` or `shell:`, ask whether
there's a module for it. If you do use shell, add `changed_when:` so
Ansible's "changed" reporting stays accurate.

## Validate: pattern

Wherever possible, render with a config-syntax validator:

```yaml
- name: Render nginx.conf
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    validate: "/usr/sbin/nginx -t -c %s"
  notify: reload nginx
```

If validation fails, the file is never moved into place. The old
config keeps running.

This is especially important for sshd (locks you out otherwise),
nginx, varnish, and bird. Prometheus has `promtool check config`
but the openrc service doesn't make it easy to integrate; we skip
validation there.

## Handlers

- One handler per "thing that gets restarted/reloaded." Don't define
  multiple handlers for the same operation.
- `notify:` from tasks; never call handlers directly via `command:
  service ... restart`.
- For cross-role coordination (e.g. firewall handler should fire
  before docker handler), use `meta: flush_handlers` between role
  inclusions in the play, or make the dependency explicit in the
  later role.

## What goes in `defaults/main.yml`

The role's *user-facing knobs*, all listed with sensible defaults.
Reading `defaults/main.yml` should answer "what can I configure?"

```yaml
# Good:
docker_log_max_size: "10m"
docker_log_max_files: "5"

# Bad — internal, doesn't belong here:
_docker_systemd_unit_path: /etc/init.d/docker
```

Internal constants belong in `vars/main.yml`. Some roles have none.

## What goes in `tasks/main.yml`

The "happy path" of the role, in execution order. Each task should:

- Have a descriptive `name:` (shows up in playbook output).
- Use the smallest module that works.
- Be the same on re-run as on first run (idempotent).
- Notify a handler if something downstream needs to react.

If `tasks/main.yml` exceeds ~80 lines, split into included files:

```yaml
# tasks/main.yml
- include_tasks: install.yml
- include_tasks: config.yml
- include_tasks: swarm.yml
  when: docker_swarm_role != "none"
```

## Cross-role dependencies

There's no `meta/main.yml` `dependencies:` in this repo. Roles compose
via *playbooks*, not auto-loading. This makes the role list explicit
and avoids hidden ordering surprises.

If role A genuinely cannot run without role B, fail loudly:

```yaml
- name: Ensure varnish is installed (cdn_varnish prerequisite)
  ansible.builtin.fail:
    msg: "this role requires varnish to be installed first"
  when: ansible_facts.packages is defined and 'varnish' not in ansible_facts.packages
```

In practice we don't do this much — the playbook's role order is
the ordering contract.

## When to split a role

Split when:

- A subset of the role's tasks is reusable elsewhere, but the rest
  isn't (e.g. `desktop_storage` could be split out of `users` but
  isn't because no other role needs that fstab template).
- The role has two distinct lifecycles (install once + ongoing config
  vs always-runs).

Don't split for "this file is getting long." Use included tasks files.

## Variables you can rely on

Always available (gathered by `gather_facts: true`, on by default):

- `inventory_hostname` — the host's name in inventory.
- `ansible_host` — the IP/hostname Ansible connects to.
- `ansible_facts` — full system inventory:
  - `ansible_facts.hostname` — actual `/etc/hostname`.
  - `ansible_facts['<iface>']` — IP info per network interface
    (e.g. `ansible_facts.wg0.ipv4.address`).
  - `ansible_facts.os_family` — `Alpine` here.
  - `ansible_facts.packages` — package list (only after a
    `community.general.apk` query fact-gather).
- `groups` — dict of group name → list of hostnames in that group.
- `hostvars[<host>]` — every host's full var dict.

These are stable; relying on them makes templates portable across
hosts.

## Adding a new role checklist

1. Create the directory layout (above).
2. Write `defaults/main.yml` with every user-facing var documented.
3. Write `tasks/main.yml` (idempotent, validate where possible,
   notify handlers).
4. Write `handlers/main.yml` if you have any notifies.
5. Write `templates/*.j2` for non-trivial config files.
6. Write `README.md` matching the existing template (purpose,
   variables, dependencies, example, troubleshooting).
7. If the role applies to a new host class, add an inventory group
   and `group_vars/<group>.yml`.
8. Add it to the appropriate playbook's `roles:` list — never invoke
   roles standalone via `ansible -m import_role`.
9. Run `ansible-playbook --check --diff` against a target to verify
   no surprises.
