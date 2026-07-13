# Athena — Onboarding Guide

> **For onboarding agents:** This guide is self-contained for onboarding a new engineer to the `athena` repo. Walk through each phase in order. Verify each step before proceeding.

**Repo:** [`IDme/athena`](https://github.com/IDme/athena) — Legal ID Inspection API (orchestrates identity verification via Veriff)
**Stack:** Java 25, GraalVM, Maven, SPUDS (internal HTTP framework), PostgreSQL, jOOQ, Docker
**Jira board:** [IGAV project](https://idmeinc.atlassian.net/jira/software/projects/IGAV/boards)
**Team Slack:** #face-core · #profiles-private
**Team page:** [Biometric and Credential API Platform](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/3605169310)
**New hire buddy:** Ask your team lead on Day 1. They will help with repo access via a Terraform PR.

---

## Terminology Glossary

| Term | Meaning |
|------|---------|
| SPUDS | ID.me's internal Java HTTP microservice framework |
| Anaconda | Internal graph database service |
| Veriff | Third-party identity verification provider (primary integration) |
| Consul | Production key-value store |
| Vault | Production secrets manager |
| Nomad | Production server instance orchestrator |
| Harness | Production deployment pipeline |
| Network Transaction | A member successfully gaining access to a resource (North Star KPI) |
| IGAV | Identity Graph and Attribute Validation (this team) |
| PRR | Production Readiness Review |
| ARB | Architecture Review Board |
| ADR | Architectural Decision Record |
| PRE_CAPTURED | SDK mode — returns sessionToken for client to use with Veriff SDK |
| UPLOAD | API mode — client sends media bytes directly |

---

## Phase 0: Day 1 — Company Onboarding

> **Goal:** Complete all required company-level logins and training in Week 1.

**Complete in order (security training must be done first to unlock other tools):**

- [ ] Log in to **Okta** (SSO) — [Activating your Okta account](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/1468465193/New+Hire+Accounts+Access+Checklist) · [Enroll a YubiKey](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/1468465193)
- [ ] Log in to **Slack**
- [ ] Log in to **UKG (Ultipro)** — HR, payroll, org chart (login via Okta)
- [ ] Log in to **Jira** — [IGAV board](https://idmeinc.atlassian.net/jira/software/projects/IGAV/boards)
- [ ] Log in to **Google Workspace** — Gmail, Drive, Calendar, Meet
- [ ] Complete **Week 1 Orientation Training** in ID.me University (via Okta) — legally required, must finish within first two weeks
- [ ] **Benefits Enrollment** — UKG → Myself → Life Events → "I am a new employee". You have 30 days from hire date.

**HR resources:**
- [Role Success Docs](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/2498691654/Engineer+Role+Success+Docs)
- [Engineering levels matrix](https://docs.google.com/spreadsheets/d/1Tj1kIB-nd1hiL0s0wyDxgEvXJOaz8NSqohVt3sILVOM)

---

## Phase 1: Access Requests

> **Goal:** All tools accessible before writing any code. Submit all on Day 1 — many take 1–2 days.

Use the [IT Service Desk](https://idmeinc.atlassian.net/servicedesk/customer/portals). Full list: [New Hire Accounts Access Checklist](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/1468465193/New+Hire+Accounts+Access+Checklist).

| Tool | Purpose |
|------|---------|
| GitHub (IDme org) | Source code — buddy opens Terraform PR to add you to repos |
| Jira | Issue tracking |
| IntelliJ IDEA | IDE (create IT ticket to request license) |
| Claude Code | AI coding assistant |
| GCP Console | Cloud infrastructure |
| Harness | CI/CD deployments |
| Nomad | Service orchestration |
| Vault | Secrets management |
| Sentry | Error tracking |
| Honeycomb | Observability / distributed traces |
| Grafana | Metrics dashboards (request Edit role) |
| Snyk | Security scanning |
| ChatGPT Enterprise | AI tooling — [setup guide](https://idmeinc.atlassian.net/wiki/spaces/AI/pages/3039068178/ChatGPT+Enterprise) (complete AI basic training first) |
| Artifactory | Internal Maven artifact registry |
| Glean | [Unified search](https://app.glean.com) |
| Postman | API testing |

**Checkpoint:** Confirm you can view [IDme/athena](https://github.com/IDme/athena) before continuing.

---

## Phase 2: Mac Setup

### Automated setup (recommended)

```bash
# Part 1 — GitHub SSH key setup (one-time)
# Copy script from: https://github.com/IDme/idme-local-dev/blob/master/setup-keys-for-github
pbpaste > /tmp/setup-keys
chmod +x /tmp/setup-keys
/tmp/setup-keys

# Part 2 — Full machine setup
mkdir ~/workspace
cd ~/workspace
git clone git@github.com:IDme/idme-local-dev.git
$HOME/workspace/idme-local-dev/dev-setup
```

> For manual setup, follow the [Developer Environment Setup Playbook](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/1752334518/Developer+Environment+Setup+Playbook). Key steps below.

### Manual setup (summary)

```bash
xcode-select --install

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Apple Silicon only — add to ~/.zshrc:
eval "$(/opt/homebrew/bin/brew shellenv)"

brew install git
git config --global user.name "Your Name"
git config --global user.email "yourname@id.me"
```

Add to `~/.zshrc`:
```bash
ulimit -n 10240
autoload -Uz compinit && compinit
autoload -U promptinit; promptinit
```

**Optional: Jira githook** — auto-prepends ticket ID to commit messages:
```bash
# Download prepare-commit-msg from https://github.com/IDme/idme-local-dev, place in ~/githooks/
chmod +x ~/githooks/prepare-commit-msg
git config --global core.hooksPath ~/githooks
```

### SSH Key Setup

SSH key security is **mandatory**: strong passphrase required, never save to keychain, never share private key.

```bash
mkdir ~/.ssh && chmod 700 ~/.ssh && cd ~/.ssh
ssh-keygen -t ed25519 -C "$USER@id.me" -f gh_ed25519
touch config && chmod 600 config
```

Add to `~/.ssh/config`:
```
Host github github.com
  User git
  IdentityFile ~/.ssh/gh_ed25519
  AddKeysToAgent yes
```

**Add to GitHub:**
1. `cat ~/.ssh/gh_ed25519.pub` → GitHub → Settings → SSH keys → New key (type: **Authentication**)
2. Click **Configure SSO** → authorize for IDme org
3. Add the same key again as type: **Signing**

**Verify:** `ssh -vv git@github.com` — look for "successfully authenticated"

**Commit signing (required):**
```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/gh_ed25519
git config --global commit.gpgsign true
```

**GitHub repo access:** Open an [IT Service Desk ticket](https://idmeinc.atlassian.net/servicedesk/customer/portal/7/group/83/create/240) with your GitHub username, or ask your buddy for the Terraform PR.

---

## Phase 3: Java Toolchain

```bash
# Java via SDKman (recommended)
curl -s "https://get.sdkman.io" | bash
source ~/.sdkman/bin/sdkman-init.sh
sdk install java 25-graalce    # GraalVM CE 25

# Maven and Docker
brew install maven              # 3.9.9+
brew install --cask docker
```

**Verify:**
```bash
java --version    # Java 25+
mvn --version     # 3.9.9+
docker ps         # Docker must be running
```

**Artifactory credentials:**
```bash
export ARTIFACTORY_USER=yourname@id.me
export ARTIFACTORY_TOKEN=<token>    # ask your team lead or buddy
# Add both to ~/.zshrc to persist
```

---

## Phase 4: Athena Local Setup

```bash
cd ~/workspace
git clone git@github.com:IDme/athena.git
cd athena

# Build all modules
mvn clean install -DskipTests

# Start local environment with synthetic data
cd local-app-instance
mvn clean install -P synthetic-data
docker-compose up
```

**Verify:**
- `verifications-legal-ids` → http://localhost:8083
- `credentials-legal-ids` → http://localhost:8085

**Mock mode** (no backend deps — useful for API-only work):
```bash
cd local-app-instance
./scripts/start-mock.sh        # foreground
./scripts/start-mock.sh -d     # background
```

**Test mock endpoints:**
```bash
# Create a verification
curl -s -X POST http://localhost:8083/v1/verifications/legal-ids \
  -H "Content-Type: application/json" \
  -d '{"providers":["veriff"],"submissionMode":"PRE_CAPTURED"}' | jq .

# Get a credential
curl -s http://localhost:8085/v1/credentials/legal-ids/b2c3d4e5-f6a7-8901-bcde-f23456789012 | jq .

# Trigger a specific mock scenario
curl -s -H "Prefer: example=failed" \
  http://localhost:8083/v1/verifications/legal-ids/a1b2c3d4-e5f6-7890-abcd-ef1234567890 | jq .
```

**Return to real services:**
```bash
docker compose -f docker-compose.yml -f docker-compose.mock.yml down
docker compose up
```

**Key modules:**

| Module | Purpose |
|--------|---------|
| `verifications-legal-ids` | Primary REST API — creates/retrieves verification sessions |
| `veriff-decision-webhook` | Webhook receiver for Veriff callbacks (HMAC-validated) |
| `credentials-legal-ids` | REST API for retrieving stored, decrypted legal ID credentials |
| `persistence` | DB schema, Liquibase migrations, jOOQ records |
| `e2e-tests` | Full system E2E (JUnit 5 + TestContainers) |
| `api-e2e-tests` | BDD API tests (Cucumber 7.x) |

---

## Phase 5: Architecture & Context Reading

**Internal framework (start here):**
- [Spuds overview](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/3672244225)
- [Spuds dev workflow](https://github.com/IDme/spuds/blob/master/dev_workflow.md)
- [Spuds repo](https://github.com/IDme/spuds) · [Hermes repo](https://github.com/IDme/hermes) · [Anaconda repo](https://github.com/IDme/anaconda)

**Athena docs:**
- [CLAUDE.md](https://github.com/IDme/athena/blob/master/CLAUDE.md) — AI-assisted development guide, module overview, tech stack

**CI/CD:**
- Harness: [IDIG services](https://app.harness.io/ng/account/0J5OMwyEQ1Gjs91VARtemA/all/orgs/engineering/projects/idig/settings/services)
- Nomad: [nonprod jobs](https://nomad.idig.nonprod.platform.idme.co)
- Vault: [nonprod secrets](https://vault.nonprod.platform.idme.co)

**Week 2 — set up syncs with upstream/downstream teams:** IVA · Org API · Auth Foundation · Support

---

## Phase 6: First PR

**Commit convention (mandatory):** Every commit must end with:
```
Co-Authored-By: Claude Code <noreply@anthropic.com>
```

```bash
git checkout -b your-name/IGAV-XXXX-short-description
mvn clean verify
git push -u origin HEAD
gh pr create --fill
```

**PR readiness checklist:**
- [ ] All tests pass locally (`mvn clean verify`)
- [ ] No new Snyk vulnerabilities introduced
- [ ] PR description links the Jira ticket
- [ ] Commits are signed (`git log --show-signature`)
