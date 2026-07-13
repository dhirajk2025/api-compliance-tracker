# Consent API — Onboarding Guide

> **For onboarding agents:** This guide is self-contained for onboarding a new engineer to the `idme-consent-api` repo. Walk through each phase in order. Verify each step before proceeding.

**Repo:** [`IDme/idme-consent-api`](https://github.com/IDme/idme-consent-api) — Consent definitions and user consent acceptance for ID.me's Super App
**Stack:** Java 23, Spring Boot 3.5, Maven, PostgreSQL, jOOQ, Docker
**Note:** Unlike hydra and athena, this service uses **Spring Boot** (not SPUDS).
**Jira board:** [IGAV project](https://idmeinc.atlassian.net/jira/software/projects/IGAV/boards)
**Team Slack:** #face-core · #profiles-private
**Team page:** [Biometric and Credential API Platform](https://idmeinc.atlassian.net/wiki/spaces/EN/pages/3605169310)
**New hire buddy:** Ask your team lead on Day 1. They will help with repo access via a Terraform PR.

---

## Terminology Glossary

| Term | Meaning |
|------|---------|
| Anaconda / core-anaconda | Internal graph database — consent-api uses its Liquibase schema for local dev |
| Consul | Production key-value store |
| Vault | Production secrets manager |
| Nomad | Production server instance orchestrator |
| Harness | Production deployment pipeline |
| Network Transaction | A member successfully gaining access to a resource (North Star KPI) |
| IGAV | Identity Graph and Attribute Validation (this team) |
| PRR | Production Readiness Review |
| ARB | Architecture Review Board |
| ADR | Architectural Decision Record |
| Spotless | Code formatter enforced by this repo (Google Java Format) |

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

**Checkpoint:** Confirm you can view [IDme/idme-consent-api](https://github.com/IDme/idme-consent-api) before continuing.

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

This repo uses **Java 23** (not 25).

```bash
# Java via SDKman (recommended)
curl -s "https://get.sdkman.io" | bash
source ~/.sdkman/bin/sdkman-init.sh
sdk install java 23-graalce    # GraalVM CE 23

# Maven and Docker
brew install maven              # 3.8+
brew install --cask docker
```

**Verify:**
```bash
java --version    # Java 23+
mvn --version     # 3.8+
docker ps         # Docker must be running
```

**Artifactory credentials:**
```bash
export ARTIFACTORY_USER=yourname@id.me
export ARTIFACTORY_TOKEN=<token>    # ask your team lead or buddy
# Add both to ~/.zshrc to persist
```

---

## Phase 4: Consent API Local Setup

### Prerequisite: clone core-anaconda

The local DB setup pulls its full Liquibase schema from `core-anaconda`. Clone it first:

```bash
cd ~/workspace
git clone git@github.com:IDme/core-anaconda.git
```

> **Important:** `local-dev/start.sh` currently has a hardcoded path to core-anaconda (`/Users/mitesh.pant/workspace/core-anaconda/`). Before running, update the volume mount in `local-dev/start.sh` (or the docker-compose file) to point to your own path, e.g. `~/workspace/core-anaconda/`.

### Setup

```bash
cd ~/workspace
git clone git@github.com:IDme/idme-consent-api.git
cd idme-consent-api

# Start local DB (PostgreSQL on port 5433 — avoids conflict with local pg)
./local-dev/start.sh

# In another terminal, start the app
mvn spring-boot:run -pl consent-api -Dspring-boot.run.profiles=local
```

**Local DB connection:**

| Setting | Value |
|---------|-------|
| Host | localhost |
| Port | **5433** (not 5432 — avoids conflicts) |
| Database | consents_db |
| Username | postgres |
| Password | postgres |

**Verify:**
```bash
# DB health
docker exec consents-db psql -U postgres -d consents_db -c "SELECT COUNT(*) FROM legal_documents;"

# App health
curl "http://localhost:8080/v1/consents/definitions?flow=biometric_consent&language=en"
```

### Test the API

**Generate a JWT:**
```bash
JWT=$(./local-dev/jwt-generator.py)
# With specific user: ./local-dev/jwt-generator.py --uid 67890
# Pretty print: ./local-dev/jwt-generator.py --pretty
```

**List consent definitions:**
```bash
curl -X GET "http://localhost:8080/v1/consents/definitions?flow=biometric_consent&language=en" \
  -H "Authorization: Bearer $JWT"
```

**Accept a consent:**
```bash
curl -X POST "http://localhost:8080/v1/consents" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"definitionId": 168, "consentScope": [10, 20]}'
```

**Other flows:**
```bash
# Privacy policy
curl "http://localhost:8080/v1/consents/definitions?flow=privacy_policy&language=en" \
  -H "Authorization: Bearer $JWT"

# Spanish
curl "http://localhost:8080/v1/consents/definitions?flow=biometric_consent&language=es" \
  -H "Authorization: Bearer $JWT"
```

### Stop local environment

```bash
./local-dev/stop.sh
```

### Code formatting (enforced)

This repo uses **Spotless** with Google Java Format. Run before every commit:

```bash
mvn spotless:apply      # auto-format
mvn spotless:check      # verify without changing
```

Formatting also runs automatically during `mvn clean install`.

**Formatting rules:** 2-space indentation, 100-char line length, Google Java Style Guide.

### Troubleshooting

| Problem | Fix |
|---------|-----|
| Port 5433 in use | `./local-dev/stop.sh` then `./local-dev/start.sh` |
| Port 8080 in use | `lsof -i :8080`, kill the process |
| DB volume mount fails | Update `core-anaconda` path in `local-dev/start.sh` to your `~/workspace/core-anaconda/` |
| jOOQ `NoSuchMethodError` | Check `jooq.version` in pom.xml matches `core-anaconda:core-db` (should be 3.19.14) |
| JWT decode issues | Set `me.id.consents.config.JwtLoggingFilter: DEBUG` in `application-local.yml` |
| DB connection error | `docker logs consents-db` · `docker exec -it consents-db psql -U postgres -d consents_db` |

---

## Phase 5: Architecture & Context Reading

**Design document:**
- [Consent API Design Document](https://docs.google.com/document/d/1JDOKWBy8BEUL5ncO3C_PEipI_C6U1gvDSKz5k4JxISo)
- [local-dev/README.md](https://github.com/IDme/idme-consent-api/blob/master/local-dev/README.md)

**Key tables:**

| Table | Purpose |
|-------|---------|
| `legal_documents` | Versions of consent types |
| `legal_contents` | Language-specific content per legal document |
| `agreements` | Records of user consent acceptance |
| `languages` | Supported language/locale configurations |

**Architecture notes:**
- Uses **Spring MVC** (not SPUDS abstract controller) — better Spring Security integration
- JWT extracted via `RequestContextInterceptor` → passed to service layer as `RequestContext`
- Security is permissive in Phase 1; will tighten in later phases

**Roadmap:**
- Phase 1 (Jan 2026, done): GET consent definitions, POST accept consent
- Phase 2 (Feb 2026): consent retrieval, revoke, trigger reconsent
- Phase 3+: migrate to person model, pre-person binding, data share

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

# Format code before committing
mvn spotless:apply

mvn clean verify
git push -u origin HEAD
gh pr create --fill
```

**PR readiness checklist:**
- [ ] All tests pass locally (`mvn clean verify`)
- [ ] Code formatted (`mvn spotless:check` passes)
- [ ] No new Snyk vulnerabilities introduced
- [ ] PR description links the Jira ticket
- [ ] Commits are signed (`git log --show-signature`)
