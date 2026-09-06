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
- [ ] **Internal host addresses.** `scripts/flash.sh` and `scripts/test.sh`
      hard-code lab RFC1918 addresses and an account name. These are not
      routable from the internet, but they describe internal topology and do not
      belong in a public repository. Parameterise them via environment variables
      with sane defaults before publishing.
- [ ] **Build artifacts.** The eleven commits add ~44 MB of generated output
      (`build*/fpga.json`, `fpga.cfg`, `synth.log`). Committing them was possible
      only because this line lacked the `.gitignore` that `master` had; that file
      is now restored, which stops *new* artifacts, but the already-committed ones
      would be permanent once pushed. Either drop them from the history first or
      accept the size.
- [ ] **Absolute paths.** Those same generated files embed the build machine's
      home directory in ~170k `src:` annotations. Removing the artifacts removes
      this too.

## Not yet committed anywhere

At the time of writing the working tree also holds Phase 5 material that is in
**no** commit and on **no** remote: `rtl/fpga_phase5.v`, `rtl/uart_ila.v`,
`rtl/pll_50mhz.v`, `rtl/iobuf_test.v`, `constraints/timing_phase5.sdc`,
`constraints/iobuf_test.ccf`, `scripts/build_phase5.sh`,
`scripts/build_iobuf_test.sh`, and modifications to `rtl/mdio_controller.v`.
