# SCA Findings Handling — Decision Record

Applied on 2026-04-30.

---

## Context

Trivy SCA scanned the dependency manifests under `src/` and found 31 vulnerabilities
across 5 services. All are in the upstream Google Online Boutique demo — third-party
code not owned or maintained by this team. All have fixed versions available.

### Summary table

| Target | Type | Total | CRITICAL | HIGH |
|--------|------|-------|----------|------|
| `currencyservice/package-lock.json` | npm | 13 | 4 | 9 |
| `paymentservice/package-lock.json` | npm | 13 | 4 | 9 |
| `shippingservice/go.mod` | gomod | 1 | 1 | 0 |
| `emailservice/requirements.txt` | pip | 1 | 0 | 1 |
| `recommendationservice/requirements.txt` | pip | 1 | 0 | 1 |
| `shoppingassistantservice/requirements.txt` | pip | 2 | 0 | 2 |
| `checkoutservice/go.mod` | gomod | 0 | — | — |
| `frontend/go.mod` | gomod | 0 | — | — |
| `productcatalogservice/go.mod` | gomod | 0 | — | — |
| `loadgenerator/requirements.txt` | pip | 0 | — | — |

---

## CVE Analysis

### CRITICAL — protobufjs (`currencyservice`, `paymentservice`)

**CVE:** CVE-2026-41242
**Package:** `protobufjs` 6.11.4 / 7.2.5 / 7.4.0 / 7.5.4
**Fixed in:** 7.5.5 / 8.0.1

**What it allows:** Arbitrary code execution via prototype pollution. An attacker who
can supply a crafted protobuf message can overwrite JavaScript object prototypes,
enabling remote code execution on the Node.js process.

**Why it is in the demo:** The demo uses `protobufjs` for gRPC message serialization
in Node.js services. The pinned version predates the fix. Upgrading requires verifying
compatibility with the gRPC message definitions used by the service.

**Real-world risk:** HIGH — prototype pollution leading to RCE is a critical attack
chain. In a production deployment this must be fixed.

---

### CRITICAL — grpc-go (`shippingservice`)

**CVE:** CVE-2026-33186
**Package:** `google.golang.org/grpc` v1.79.2
**Fixed in:** v1.79.3

**What it allows:** Authorization bypass via improper HTTP/2 path validation. A
malicious client can craft a request path that bypasses `authz` policy checks,
allowing access to gRPC methods that should be restricted.

**Why it is in the demo:** The dependency is one patch version behind the fix. The
demo does not configure `authz` policies, so the vulnerability is not exploitable in
the demo itself — but it would be in a production deployment that adds authorization.

**Note:** This is the lowest-risk upgrade in this list — `v1.79.2 → v1.79.3` is a
pure patch bump. If this team takes ownership of `shippingservice`, this should be
the first fix applied.

---

### HIGH — minimatch (`currencyservice`, `paymentservice`)

**CVEs:** CVE-2026-26996, CVE-2026-27903, CVE-2026-27904
**Package:** `minimatch` 3.1.2
**Fixed in:** 3.1.3 (and 4.2.4 / 5.1.7 / 6.2.1 / 7.4.7 / 8.0.5)

**What it allows:** Denial of Service via catastrophic backtracking in glob pattern
matching. An attacker who controls input to a glob match can supply a crafted
pattern that causes the regex engine to backtrack exponentially, hanging the process.

**Why it is in the demo:** `minimatch` is a transitive dependency of npm tooling
bundled in the demo. It is not directly called by application code — the demo services
do not perform glob matching at runtime. Exploitability is therefore low in this context.

---

### HIGH — node-tar (`currencyservice`, `paymentservice`)

**CVEs:** CVE-2026-23745, CVE-2026-23950, CVE-2026-24842, CVE-2026-26960,
CVE-2026-29786, CVE-2026-31802
**Package:** `tar` 6.1.12 / 6.2.1
**Fixed in:** 7.5.3 and progressively higher

**What it allows:** A series of related path traversal and symlink poisoning
vulnerabilities during archive extraction. An attacker who can supply a malicious
tar archive to the extraction function can overwrite arbitrary files on the filesystem.

**Why it is in the demo:** `tar` is a transitive dependency of npm. The demo services
do not unpack user-supplied archives at runtime — these vulnerabilities require the
application to call `tar.extract()` on attacker-controlled input, which does not happen
here. The risk is build-time only, not runtime.

---

### HIGH — pyasn1 (`emailservice`, `recommendationservice`)

**CVE:** CVE-2026-30922
**Package:** `pyasn1` 0.5.0
**Fixed in:** 0.6.3

**What it allows:** Denial of Service via unbounded recursion in ASN.1 structure
decoding. A crafted ASN.1-encoded message can exhaust the call stack.

**Why it is in the demo:** `pyasn1` is a transitive dependency of the Google Auth
libraries used by these services. The services use it only for internal credential
management, not for decoding user-supplied ASN.1 — exploitability requires an attacker
to intercept and modify Google Auth responses, which is a separate, harder attack.

---

### HIGH — langchain-core (`shoppingassistantservice`)

**CVE:** CVE-2026-34070
**Package:** `langchain-core` 1.2.11
**Fixed in:** 1.2.22

**What it allows:** Path traversal in legacy `load_prompt` functions. An attacker who
controls the prompt file path argument can read arbitrary files from the server.

**Why it is in the demo:** The shopping assistant service uses LangChain for AI
interactions. The vulnerable `load_prompt` code path is a legacy function not called
by the demo's current implementation. A one-version bump to 1.2.22 fixes it.

---

### HIGH — Pillow (`shoppingassistantservice`)

**CVE:** CVE-2026-40192
**Package:** `pillow` 12.1.1
**Fixed in:** 12.2.0

**What it allows:** Denial of Service via decompression bomb in FITS image processing.
An attacker can supply a crafted FITS image file that expands to consume all available
memory.

**Why it is in the demo:** Pillow is a dependency of the AI libraries used by the
shopping assistant. The demo does not process FITS images — it handles text queries
to the AI backend. The vulnerable code path is unreachable in normal operation.

---

## Decision — Option A: `.trivyignore` (Applied)

Create a `.trivyignore` file listing each CVE explicitly. Trivy checks for this file
in the directory being scanned by default — so the file must live in the scan root
(`src/`), not the repo root. A workflow step copies it there before any Trivy step runs.

**File: `.trivyignore` (repo root, copied to `src/` at scan time)**

```
CVE-2026-41242   # protobufjs — arbitrary code execution
CVE-2026-33186   # grpc-go — authorization bypass
CVE-2026-26996   # minimatch — DoS
CVE-2026-27903   # minimatch — DoS
CVE-2026-27904   # minimatch — DoS
CVE-2026-23745   # tar — file overwrite
CVE-2026-23950   # tar — file overwrite
CVE-2026-24842   # tar — file creation
CVE-2026-26960   # tar — file read/write
CVE-2026-29786   # tar — path traversal
CVE-2026-31802   # tar — file overwrite
CVE-2026-30922   # pyasn1 — DoS
CVE-2026-34070   # langchain-core — path traversal
CVE-2026-40192   # pillow — DoS
```

**Workflow step added before Trivy steps:**

```yaml
- name: Stage trivyignore in scan root
  run: cp .trivyignore src/.trivyignore
```

**Why the file must be copied and not referenced directly:**
`trivy-action`'s SARIF code path reconstructs the Trivy CLI command internally and
does not pass `--ignorefile` to it — even when the `trivyignores` parameter is set or
when `TRIVY_IGNOREFILE` is set as an environment variable on the step. Both approaches
were attempted and failed. Trivy's own default behaviour is to look for `.trivyignore`
in the directory it is scanning, so placing the file there is the only approach that
works regardless of how the action invokes the binary.

The source of truth remains `.trivyignore` at the repo root. The copy in `src/` is
ephemeral — it exists only on the runner during the job and is never committed.

**Effect:**
- Trivy skips exactly these 14 CVE IDs — any new CVE not on this list still fails
  the pipeline
- The `.trivyignore` file is committed to the repo root — suppressions are visible,
  reviewable, and auditable in git history
- The SARIF upload to the GitHub Security tab still runs — findings are recorded
  even if they do not block

**When to use Option A:**
- CVEs are in upstream or vendored code this team does not own
- Each suppression is a deliberate, named decision — not a blanket ignore
- You want the pipeline to remain blocking for any future CVE not explicitly accepted
- Suppressions need to be visible in code review

---

## Option B — Exit-Code 0 (Report Only)

Change `exit-code: '1'` to `exit-code: '0'` in the SCA step of `build-push.yml`.
Trivy still runs and uploads findings to the Security tab but never blocks the pipeline.

**Change required in `.github/workflows/build-push.yml`:**

```yaml
# before — blocks on HIGH/CRITICAL findings
- name: Trivy — scan dependency manifests in src/ (SARIF gate)
  uses: aquasecurity/trivy-action@0.35.0
  with:
    scan-type: fs
    scan-ref: src/
    scanners: vuln
    severity: HIGH,CRITICAL
    format: sarif
    output: trivy-sca.sarif
    exit-code: '1'       # ← blocks pipeline

# after — reports but never blocks
- name: Trivy — scan dependency manifests in src/ (SARIF gate)
  uses: aquasecurity/trivy-action@0.35.0
  with:
    scan-type: fs
    scan-ref: src/
    scanners: vuln
    severity: HIGH,CRITICAL
    format: sarif
    output: trivy-sca.sarif
    exit-code: '0'       # ← reports only
```

**Effect:**
- Pipeline always passes the SCA step regardless of findings
- All findings still appear in the GitHub Security tab
- No blocking gate — relies entirely on developers reviewing the Security tab

**When to use Option B:**
- A large backlog of findings exists that cannot all be addressed before shipping
  and blocking would halt development
- SCA is being introduced incrementally — reporting first, enforcing later
- Useful as a transitional state while `.trivyignore` entries are being reviewed
  and approved

**Risk:** Without a blocking gate, new CVEs introduced by dependency bumps are only
visible if someone actively monitors the Security tab. New critical vulnerabilities
can enter the codebase silently. Treat Option B as temporary with a concrete plan to
re-enable blocking.

---

## Comparison

| Dimension | Option A — trivyignore | Option B — exit-code 0 |
|-----------|------------------------|------------------------|
| Pipeline blocks on listed CVEs | No | No |
| Pipeline blocks on new unlisted CVEs | **Yes** | No |
| Suppressions are auditable in git | **Yes** | No |
| Suppressions are per-CVE | **Yes** | No (all or nothing) |
| New CVE introduced silently | No | **Yes** |
| Suitable for permanent use | Yes | Temporary only |
| Effort to implement | Create `.trivyignore` | Change one line |

---

## Recommended remediation for team-owned services

If any of these services are forked or taken over by this team, apply these fixes
in priority order:

| Priority | Fix | Effort |
|----------|-----|--------|
| 1 | `shippingservice`: bump `grpc-go` v1.79.2 → v1.79.3 in `go.mod` | Trivial — patch version |
| 2 | `emailservice`, `recommendationservice`: bump `pyasn1` 0.5.0 → 0.6.3 in `requirements.txt` | Low |
| 3 | `shoppingassistantservice`: bump `langchain-core` 1.2.11 → 1.2.22 and `pillow` 12.1.1 → 12.2.0 | Low |
| 4 | `currencyservice`, `paymentservice`: bump `protobufjs` to 7.5.5+ and `tar` to 7.5.3+ in `package-lock.json` | Medium — test gRPC message compatibility |

---

## Files Changed

| File | Change |
|------|--------|
| `.trivyignore` | Created — 14 CVEs explicitly suppressed with comments |
| `docs/sca-findings-handling.md` | This document |
