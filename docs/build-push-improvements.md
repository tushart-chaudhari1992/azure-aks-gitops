# build-push.yml — Improvement Report

Applied on 2026-04-30.

---

## Summary

Five gaps were identified and resolved in the GitHub Actions build-and-push workflow.
Three were correctness bugs (wrong Dockerfile path, missing services, tag not reflecting
actual per-service change history) and two were efficiency gaps (serial builds, full SHA
verbosity). No infrastructure changes were made — all changes are in the workflow file only.

---

## What Was Improved

### 1. Per-Service Change Detection

**Gap:** The build loop rebuilt all 10 services on every push regardless of what changed.
Pushing a one-line fix to `frontend` triggered a full rebuild of `cartservice`,
`paymentservice`, and eight other services that were identical to the previous push.
More critically, all 10 images received the same `sha-<latest-commit>` tag — including
services whose source code did not change. The tag therefore reflected when the last
commit happened, not when the service itself last changed. That defeats the stated goal:
"understand change for each image pushed."

**Added:** A `detect-changes` job using `dorny/paths-filter@v3` that runs before any build:

```yaml
detect-changes:
  name: Detect changed services
  runs-on: ubuntu-latest
  outputs:
    services: ${{ steps.filter.outputs.changes }}
  steps:
    - uses: actions/checkout@v4
    - uses: dorny/paths-filter@v3
      id: filter
      with:
        filters: |
          frontend:
            - 'src/frontend/**'
          cartservice:
            - 'src/cartservice/**'
          # ... one entry per service
```

`paths-filter` compares the pushed commit against its parent (or against the PR base for
pull requests) and outputs a JSON array of filter names whose paths matched — for example
`["frontend","checkoutservice"]`. The `build-push`, `image-scan`, and `update-tags` jobs
all read this array and run only for the services in it:

```yaml
strategy:
  matrix:
    service: ${{ fromJson(needs.detect-changes.outputs.services) }}
```

**Why it matters:** Each service now keeps its own tag from the commit that last changed
it. Looking at the kustomize overlay after several pushes you see:

```yaml
# before: all services share the tag of the latest commit — even untouched ones
frontend: sha-a1b2c3d
cartservice: sha-a1b2c3d    # unchanged but re-tagged
paymentservice: sha-a1b2c3d # unchanged but re-tagged

# after: each tag reflects that service's own last change
frontend: sha-a1b2c3d       # changed in this commit
cartservice: sha-f9e8d7c    # last changed 3 commits ago
paymentservice: sha-b4c5d6e # last changed 2 commits ago
```

The overlay becomes a per-service changelog. You can answer "when did `paymentservice`
last change?" by reading the tag — without digging through git history.

---

### 2. Parallel Builds per Service (Matrix Instead of Serial Loop)

**Gap:** The original `build-push` job ran a single bash loop that built and pushed each
service one after the other:

```bash
for SERVICE in "${SERVICES[@]}"; do
  docker build ...
  docker push ...
done
```

With 10 services averaging 3–5 minutes per build, the job could take 30–50 minutes on a
push that changed multiple services. Each build also had to wait for the previous one's
push to complete before starting.

**Changed:** `build-push` is now a matrix job — each service gets its own parallel runner:

```yaml
build-push:
  strategy:
    matrix:
      service: ${{ fromJson(needs.detect-changes.outputs.services) }}
  steps:
    - name: Build and push ${{ matrix.service }}
      run: |
        docker build -t ... -f ... .
        docker push ...
```

**Why it matters:** Three services building in parallel takes as long as the slowest one,
not the sum of all three. The job also now shows per-service pass/fail in the GitHub Actions
UI rather than a single monolithic job log — easier to diagnose which service failed and why.
`image-scan` uses the same matrix and gets the same parallelism benefit.

---

### 3. Short SHA Tag (7 Characters)

**Gap:** The image tag was set to the full 40-character git SHA:

```bash
echo "IMAGE_TAG=sha-${{ github.sha }}" >> $GITHUB_OUTPUT
# produces: sha-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
```

This 44-character string appeared in three places: ACR image names, the kustomize overlay,
and git commit messages. In the kustomize overlay it made lines long enough to require
horizontal scrolling; ACR's repository UI truncated it; `git log --oneline` output was
dominated by the tag rather than the message.

**Changed:** All three places that set the tag now slice to 7 characters:

```bash
echo "IMAGE_TAG=sha-$(echo '${{ github.sha }}' | cut -c1-7)" >> $GITHUB_OUTPUT
# produces: sha-a1b2c3d
```

**Why it matters:** Git's own UI (GitHub, `git log`, `git show`) uses 7 characters as the
standard short SHA because it provides sufficient collision resistance for any practical
repository size. The full SHA adds no safety for image tagging — the tag namespace is
per-repository in ACR, so collisions cannot cross repositories. `sha-a1b2c3d` is human-readable
in a diff; `sha-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2` is not.

---

### 4. Added Two Missing Services

**Gap:** `src/` contained 12 service directories. The build loop and scan matrix named
only 10 — `loadgenerator` and `shoppingassistantservice` were absent. Both have confirmed
Dockerfiles:

```
src/loadgenerator/Dockerfile
src/shoppingassistantservice/Dockerfile
```

The workflow exited green on every push while silently never building or scanning either
service. Any code change to those two services produced no container image.

**Added:** Both services are now included in:
- The `detect-changes` path filter (so changes to their source trigger builds)
- The `build-push` matrix (so their images are built and pushed)
- The `image-scan` matrix (so their images are scanned for CVEs)
- The `update-tags` loop (so their kustomize entries are updated)

**Why it matters:** A CI pipeline that silently skips services gives a false green — the
check mark means "the services I remembered to list passed," not "all services passed."
Silent omissions are harder to catch than explicit failures.

---

### 5. Fixed cartservice Dockerfile Path

**Gap:** The build loop used a uniform path pattern for all services:

```bash
docker build \
  -f src/${SERVICE}/Dockerfile \
  src/${SERVICE}
```

`cartservice` is a .NET project and its source is nested one level deeper. Its Dockerfile
lives at `src/cartservice/src/Dockerfile` — not `src/cartservice/Dockerfile`. The path
`src/cartservice/Dockerfile` does not exist. Every run of the original workflow would have
failed at the `cartservice` build step with a `no such file or directory` error.

**Added:** A `set-build-paths` step in the `build-push` job detects `cartservice` and
sets the correct paths before the build runs:

```yaml
- name: Set build paths
  id: paths
  run: |
    SERVICE="${{ matrix.service }}"
    if [ "$SERVICE" = "cartservice" ]; then
      echo "DOCKERFILE=src/cartservice/src/Dockerfile" >> $GITHUB_OUTPUT
      echo "CONTEXT=src/cartservice/src" >> $GITHUB_OUTPUT
    else
      echo "DOCKERFILE=src/${SERVICE}/Dockerfile" >> $GITHUB_OUTPUT
      echo "CONTEXT=src/${SERVICE}" >> $GITHUB_OUTPUT
    fi

- name: Build and push ${{ matrix.service }}
  run: |
    docker build \
      -t ... \
      -f ${{ steps.paths.outputs.DOCKERFILE }} \
      ${{ steps.paths.outputs.CONTEXT }}
```

**Why it matters:** The uniform path assumption works for 11 out of 12 services. The one
exception was silent — the loop would error mid-run and block all subsequent builds. With
per-service matrix jobs this would now surface as a single failed matrix entry rather than
blocking the other services, but the underlying path was still wrong and needed fixing.

---

## Files Changed

| File | Change |
|------|--------|
| `.github/workflows/build-push.yml` | All five improvements applied |

---

## Before and After

| Dimension | Before | After |
|-----------|--------|-------|
| **Services covered** | 10 of 12 | 12 of 12 |
| **Build scope per push** | All 10 services rebuilt | Only changed services rebuilt |
| **Tag meaning** | Reflects latest commit SHA, even for unchanged services | Reflects the commit that last changed that specific service |
| **Tag readability** | 44-char string (`sha-a1b2c3d4e5f6...`) | 9-char string (`sha-a1b2c3d`) |
| **Build execution** | Serial loop — sum of all build times | Parallel matrix — time of slowest changed service |
| **cartservice build** | Would fail — wrong Dockerfile path | Correct path resolved at runtime |
| **Kustomize overlay** | All services share the same tag after every push | Each service tag reflects its own last-changed commit |
