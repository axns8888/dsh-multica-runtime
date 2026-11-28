# Compatibility contract

| Surface | Contract / evidence boundary |
| --- | --- |
| Identity | `@multica-ai/dsh-runtime`, profile `multica`, private package under the repository MIT License |
| Protocol | JSONL v1 over stdio; `--probe`, `--list-models`, `--stdio` |
| Node release build | exactly 24.21.0; runtime engines inherited from upstream |
| pnpm release build | exactly 12.5.1, frozen pnpm-lock.yaml |
| PowerShell tools | PowerShell >=7.4, tar, Git; installation also requires DSH/pnpm |
| Compile/test DSH family | locked 0.2.1-rc.2; Cordis 4.0.5, loader 1.0.6 |
| Declared DSH engine | upstream `>=0.2.1-rc.2 <0.3.0`; not a test of every version |
| Local target | DSH 0.2.2-rc.5, Multica 0.13.0 (35b54a374), Windows x64 |
| Other OS | Baseline 7e90bdb CI passed Windows/Ubuntu build + fixture checks; Linux/macOS daemon installation and live tasks remain unverified |

Check `docs/VALIDATION.zh-CN.md` for actual results of this build. Unit tests
cover protocol/env/lifecycle behavior; they do not prove a successful model API
request. Nonempty model discovery does not establish provider credentials.
Probe success does not establish discovery by an already-running daemon.
Cancellation, resume and tool results require live end-to-end testing, including
Multica's task-token environment, before claiming AXNS-5 integration is complete.

The maintenance installer never restarts a daemon and only manages profile
`multica`. It serializes its own profile transactions, not arbitrary concurrent
DSH plugin edits; close other profile package-manager operations first.
Profile backups remain private under DSH_HOME/.axns-runtime and can contain
local credentials/configuration. They must never be packed, uploaded or committed.
SHA256 checks protect integrity relative to a trusted checksum; downloading both
files from one Release is not independent proof of publisher authenticity.
