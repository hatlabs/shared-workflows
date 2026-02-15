# Hat Labs Shared Workflows

Reusable GitHub Actions workflows for the pr-main-release strategy used across Hat Labs repositories.

## Overview

These workflows implement a standardized release process:

1. **PR** → Run tests
2. **Merge to main** → Build .deb, create pre-release, dispatch to APT unstable
3. **Publish release** → Dispatch to APT stable

## Workflows

### pr-checks.yml

Runs tests and lintian checks on pull requests.

```yaml
# .github/workflows/pr.yml
name: Pull Request Checks

on:
  pull_request:
    branches: [main]

jobs:
  checks:
    uses: hatlabs/shared-workflows/.github/workflows/pr-checks.yml@main
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `runs-on` | `ubuntu-latest` | Runner to use for tests |
| `skip-lintian` | `false` | Skip lintian checks |

**Jobs:**
1. **tests**: Runs `.github/actions/run-tests/action.yml`
2. **version-check**: Runs `.github/actions/check-versions/action.yml` (if exists)
3. **lintian**: Builds package and runs lintian (if `.github/actions/build-deb/action.yml` exists)

**Version Checks:**
- Automatically runs if `.github/actions/check-versions/action.yml` exists
- Use to verify VERSION file stays in sync with language-specific version files
- Each repo implements its own version checking logic

**Lintian Checks:**
- Automatically runs if `.github/actions/build-deb/action.yml` exists
- Fails on errors and warnings
- To suppress specific tags, create `debian/<package>.lintian-overrides`
- Set `skip-lintian: true` to disable

**Required local action**: `.github/actions/run-tests/action.yml`

**Optional local actions**:
- `.github/actions/build-deb/action.yml` (enables lintian checks)
- `.github/actions/check-versions/action.yml` (enables version consistency checks)

### build-release.yml

Main branch CI/CD: test, build, release, dispatch.

```yaml
# .github/workflows/main.yml
name: Main Branch CI/CD

on:
  push:
    branches: [main]

jobs:
  build-release:
    uses: hatlabs/shared-workflows/.github/workflows/build-release.yml@main
    with:
      package-name: my-package
      package-description: 'Description for release notes'
    secrets:
      APT_REPO_PAT: ${{ secrets.APT_REPO_PAT }}
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `package-name` | *required* | Debian package name |
| `package-description` | `Debian package` | Short description |
| `apt-distro` | `trixie` | APT distribution |
| `apt-component` | `main` | APT component |
| `apt-repository` | `hatlabs/apt.hatlabs.fi` | APT repo to dispatch to |
| `version-file` | `VERSION` | Path to version file |
| `maintainer-name` | `Hat Labs` | Changelog maintainer |
| `maintainer-email` | `info@hatlabs.fi` | Changelog email |
| `skip-tests` | `false` | Skip test job |

**Required local actions** (hardcoded paths):
- `.github/actions/run-tests/action.yml` - Test action
- `.github/actions/build-deb/action.yml` - Build action

**Optional local script overrides** (for multi-package or custom repos):
- `.github/scripts/generate-changelog.sh` - Custom changelog generation
- `.github/scripts/rename-packages.sh` - Custom package renaming
- `.github/scripts/generate-release-notes.sh` - Custom release notes

If these scripts exist, they will be called instead of the default inlined logic.
See [Local Script Overrides](#local-script-overrides) for details.

**Secrets:**
| Secret | Description |
|--------|-------------|
| `APT_REPO_PAT` | PAT for dispatching to APT repository |

### publish-stable.yml

Handles stable release publishing.

```yaml
# .github/workflows/release.yml
name: Release Published

on:
  release:
    types: [published]

jobs:
  publish:
    uses: hatlabs/shared-workflows/.github/workflows/publish-stable.yml@main
    secrets:
      APT_REPO_PAT: ${{ secrets.APT_REPO_PAT }}
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `apt-distro` | `trixie` | APT distribution |
| `apt-component` | `main` | APT component |
| `apt-repository` | `hatlabs/apt.hatlabs.fi` | APT repo to dispatch to |
| `version-pattern` | `^v([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$` | Tag validation regex |

## Repository Requirements

Each repository using these workflows must have:

### 1. VERSION file

```
0.2.0
```

Plain version number, no `v` prefix.

### 2. Test action (`.github/actions/run-tests/action.yml`)

```yaml
name: 'Run Tests'
description: 'Run all tests'
runs:
  using: 'composite'
  steps:
    - name: Run tests
      run: ./run test
      shell: bash
```

### 3. Build action (`.github/actions/build-deb/action.yml`)

```yaml
name: 'Build Debian Package'
description: 'Build .deb package'
runs:
  using: 'composite'
  steps:
    - name: Build
      run: dpkg-buildpackage -us -uc -b
      shell: bash
```

### 4. debian/ directory

Standard Debian packaging files. The `debian/changelog` will be auto-generated.

### 5. Repository secret: `APT_REPO_PAT`

Personal Access Token with permission to trigger repository dispatch on the APT repository.

## Version Management

- **VERSION file**: Contains upstream version (e.g., `0.2.0`)
- **Git tags**: Auto-generated as `v{version}+{N}` or `v{version}+{N}_pre`
- **Revision (N)**: Auto-incremented based on existing tags

### Version Progression Example

```
Push to main (VERSION=0.2.0, first time):
  → Creates v0.2.0+1_pre (pre-release)
  → Creates v0.2.0+1 (draft)

Push to main again (same VERSION):
  → Creates v0.2.0+2_pre (pre-release)
  → Creates v0.2.0+2 (draft)

Bump VERSION to 0.3.0, push to main:
  → Creates v0.3.0+1_pre (pre-release)
  → Creates v0.3.0+1 (draft)
```

## Migration Guide

To migrate an existing repository:

1. **Create local actions** if not present:
   - `.github/actions/run-tests/action.yml`
   - `.github/actions/build-deb/action.yml`

2. **Replace workflow files**:
   ```bash
   # Backup existing workflows
   mv .github/workflows/pr.yml .github/workflows/pr.yml.bak
   mv .github/workflows/main.yml .github/workflows/main.yml.bak
   mv .github/workflows/release.yml .github/workflows/release.yml.bak
   ```

3. **Copy caller templates** from `examples/` and customize.

4. **Scripts**: For simple single-package repos, you can remove old scripts (now inlined).
   For multi-package repos, keep the scripts - they'll be used as overrides.

5. **Test** with a PR before merging.

## Local Script Overrides

For repos with non-standard structures (e.g., multiple packages, subdirectories), provide local scripts that the shared workflow will call instead of the default inlined logic.

### generate-changelog.sh

Called with: `--upstream <version> --revision <N>`

Example for multi-package repo:
```bash
#!/bin/bash
# Generate changelogs for multiple packages
for pkg in halos halos-marine; do
  cat > ${pkg}/debian/changelog <<EOF
${pkg} (${UPSTREAM}-${REVISION}) unstable; urgency=medium
  * Build ${REVISION}
 -- Maintainer <email>  $(date -R)
EOF
done
```

### rename-packages.sh

Called with: `--version <debian-version> --distro <distro> --component <component>`

Example:
```bash
#!/bin/bash
# Rename multiple packages
for pkg in halos halos-marine; do
  OLD="${pkg}_${VERSION}_all.deb"
  NEW="${pkg}_${VERSION}_all+${DISTRO}+${COMPONENT}.deb"
  [ -f "$OLD" ] && mv "$OLD" "$NEW"
done
```

### generate-release-notes.sh

Called with: `<debian-version> <tag-version> <release-type>`

Where `release-type` is `prerelease` or `draft`. Must write to `release_notes.md`.

## Examples

See `examples/` directory for complete caller workflow examples.
