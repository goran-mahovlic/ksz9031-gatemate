# Branches and publication status

Record of the branch layout decision taken on 2026-09-06 (REGOČ TASK-4729 / TASK-4737 / TASK-4738).

## Remotes

| Remote | Visibility | Role |
|---|---|---|
| `origin` — GitHub `goran-mahovlic/ksz9031-gatemate` | **public** | upstream / published history |
| internal GitLab mirror (`regoc_ai/ksz9031-gatemate`) | **private** | working mirror, agent branches, safety backups |

## Decision: the GitLab default branch stays `master`

The GitLab mirror was originally created with `master` as its default branch, while
GitHub uses `main`. Switching the GitLab default to `main` was proposed and
**declined by the repository owner** — the mirror keeps `master` as its default.
No branch was renamed, force-pushed or deleted.

Consequence to be aware of: `git clone` of the GitLab mirror checks out `master`
(`539a666`), which is an **older, superseded** line. The current line is `main`
and its descendants; see the table below.

## Branch map

| Branch | Where | Content |
|---|---|---|
| `main` | GitHub + GitLab | published upstream history |
| `master` | GitLab only | superseded early line; a strict subset of `main` in code terms (all 23 tracked files have identical blob SHAs in the initial GitHub commit). Its one genuinely unique artifact was `.gitignore`, which has since been restored onto the current line. |
| `backup/gitlab-master-539a666` | GitLab only | frozen copy of `master` |
| `backup/local-phase4-clean-TASK4737` | GitLab only | the Phase 2–5 work, secret-free (see below) |
| `backup/local-phase4-512fd20` | GitLab only | **superseded**; pre-cleanup copy of the same work. Scheduled for deletion. |

## Phase 2–5 work: where it lives

Eleven commits (`fde1de2..`, 2026-04-22/23 plus one security fix) carry the
Emard Phase 2–5 work: MDIO PHY scan, KSZ9031 skew registers, explicit
`CC_IOBUF` instantiation, UART diagnostics and PLL experiments.

They are **published on the private GitLab mirror** as
`backup/local-phase4-clean-TASK4737`. They are **not** on public GitHub.
This is deliberate, not an oversight — see the checklist below.

## Before this work is pushed to public GitHub

- [x] **No secrets.** The hard-coded sudo password is gone from the working tree
      and from the history of all eleven commits, and the credential itself was
      rotated (TASK-4737). Re-verified independently for this record: 81 new
      blobs scanned across the eleven commits for passwords, private keys, SSH
      keys, API tokens, GitHub/GitLab PATs and AWS keys — **0 hits**.
- [x] **Internal host addresses.** Done in the working tree (`f756400`).
      `scripts/flash.sh` and `scripts/test.sh` now resolve their settings from,
      in order, an environment variable, the git-ignored `scripts/lab.env`, and
      generic placeholder defaults. `flash.sh` no longer names the account, the
      udev rule or the sudoers entry. Build scripts take `OSS_CAD_SUITE` instead
      of an absolute `/home/<user>` path. Covered by `scripts/test_lab_env.sh`
      (10 pass, 0 fail) and proven not to break the build:
      `scripts/build_phase2.sh` runs end to end, exit 0.
- [x] **Absolute paths.** Removed from the tracked build scripts by the same
      commit; the ~170k `src:` annotations live only in the generated files and
      go away with them.
- [ ] **Build artifacts — owner decision outstanding.** See "The one remaining
      decision" below.

### A commit is not enough: the history still carries it

The item above fixes the *tip*. It does not fix the *history*, and a public clone
is the whole history. Every earlier revision of `flash.sh` and `test.sh` still
contains the real addresses, older build scripts still contain the absolute home
path, and two commit messages still name the flash account, the udev rule and the
NOPASSWD sudoers entry. Commit messages cannot be edited at all without rewriting.

So the address cleanup and the artifact cleanup are **not two independent
choices**. Publishing a genuinely clean repository requires a history rewrite
either way; stripping the artifacts is then almost free, because it is the same
pass.

`scripts/prepare_public_history.sh` does that pass. It clones the repository,
never touching the working copy, drops `build/` and `build_phase2..4/`, and
scrubs every value listed in `scripts/lab.env` from every blob at every revision
and from every commit message. It refuses to report success unless four checks
pass: no build path remains, no scrubbed value survives in any message, none
survives in any blob, and the published sources are byte-identical to local HEAD.

Measured on the current history:

| | before | after |
|---|---|---|
| pack size | 8.24 MiB | 872 KiB |
| tracked tree | 25.4 MB | 6.0 MB |

Independent scan of the produced repository — every blob at every revision, and
every commit message, against passwords, private keys, PATs, AWS keys, bearer
tokens, the bench addresses, the account name, the sudoers entry, the udev rule
and the developer home path — **0 hits**.

## Decision: publish the rewritten history (option A)

The owner chose **A** on 2026-10-08: GitHub `main` gets the rewritten history
produced by `scripts/prepare_public_history.sh`, not the local SHAs. The
rejected alternative was publishing as-is, which would have made ~42 MB of
generated output and the internal bench topology permanent and public,
recoverable with `git log -p` regardless of what the tip looks like.

Consequences:

- The public SHAs differ from this repository's. GitHub `main` (`fde1de2`) is
  an ancestor of local `main` and holds no commit that exists only there, so the
  force push loses no work; anyone holding an old clone has to re-clone.
- The private GitLab mirror keeps the original, unrewritten history.
- This working repository keeps its own history. After the push it no longer
  shares commits with GitHub `main`, so do not `git pull` from GitHub here:
  regenerate the public copy from this repository instead.

## Publishing (owner, from the host)

Pushing is the owner's job; the agents only add and commit. The public copy is
written to `~/app/ksz9031-gatemate-public`, which the host sees too:

    ./scripts/prepare_public_history.sh ~/app/ksz9031-gatemate-public
    git -C ~/app/ksz9031-gatemate-public log --stat | less
    git -C ~/app/ksz9031-gatemate-public remote add gh \
        https://github.com/goran-mahovlic/ksz9031-gatemate.git
    git -C ~/app/ksz9031-gatemate-public push \
        --force-with-lease=main:fde1de2710d9ec6bc677d8f2e3df286a589407b2 gh HEAD:main

`--force-with-lease` with the expected SHA refuses to overwrite `main` if
anything was pushed to GitHub after `fde1de2`; a plain `--force` would discard it
silently. Check the result with
`git ls-remote https://github.com/goran-mahovlic/ksz9031-gatemate.git main`,
which must print the HEAD of the public copy.

The script needs `git-filter-repo`; if it is not on `PATH`, `pip install
git-filter-repo` provides it.

## Phase 5 material — now committed

Previously this section recorded Phase 5 work that was in no commit and on no
remote. It is committed as of `ca35d48`: `rtl/fpga_phase5.v`, `rtl/uart_ila.v`,
`rtl/pll_50mhz.v`, `rtl/iobuf_test.v`, `constraints/timing_phase5.sdc`,
`constraints/iobuf_test.ccf`, `scripts/build_phase5.sh`,
`scripts/build_iobuf_test.sh`, `scripts/decode_ila.py`, `scripts/decode_scan.py`,
the `tristate_repro/` minimal cases, and the `rtl/mdio_controller.v` changes.

Sources only — the restored `.gitignore` keeps the generated output out,
including the nested `tristate_repro/build_min_t_*` directories.

It is still local: pushing it anywhere is blocked on the same credential
described below.

## Blocked: no GitHub push credential

Publication cannot be carried out from the `pai-advanced` container. There is no
`gh`, no credential helper, and no `GH_TOKEN`/`GITHUB_TOKEN` in any store;
`git push --dry-run origin HEAD:main` exits 128 with
`could not read Username for 'https://github.com'`. Anonymous read works, so the
remote state can be verified but not changed. The push has to be made by the
owner, or a token has to be provided to the container.
