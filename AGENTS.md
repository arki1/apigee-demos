# Agent Guidelines & Best Practices

This document provides guidelines, architectural standards, quality gates, and local validation procedures for AI agents and automated coding assistants working on the `apigee-demos` repository.

---

## 1. Repository Layout & Architecture

```
.
├── src/
│   ├── main/apigee/
│   │   ├── apiproxies/gcpreleases-v1/apiproxy/
│   │   │   ├── gcpreleases-v1.xml          # Proxy definition bundle root
│   │   │   ├── proxies/                    # ProxyEndpoints (ingress flows, routing, CORS)
│   │   │   ├── targets/                    # TargetEndpoints (BigQuery, Mock/Echo)
│   │   │   ├── policies/                   # Apigee XML policies (AM, EV, JS, KVM, etc.)
│   │   │   └── resources/
│   │   │       ├── jsc/                    # JavaScript policy scripts (evaluated in runtime)
│   │   │       └── oas/                    # OpenAPI specifications (apispec.yaml)
│   │   └── environments/                   # Environment manifests & deployments.json templates
│   └── tests/                              # Emulator mock data & maps.json KVM templates
├── test/
│   ├── unit-tests/                         # Mocha unit tests for JS policies
│   └── integration-tests/                  # Cucumber / Apickli BDD feature definitions
├── ci/                                     # Automation, linting, and emulator scripts
│   ├── apigee-emulator.sh                  # Apigee Emulator CLI wrapper
│   ├── detect-project-id.sh                # Project ID resolution helper
│   ├── lint.sh                             # ApigeeLint runner
│   └── pre-commit-checks.sh                # End-to-end local validation script
├── Makefile                                # Developer and build automation targets
├── CICD.md                                 # CI/CD and deployment pipeline documentation
└── EMULATOR.md                             # Emulator architecture and REST API documentation
```

---

## 2. Code Standards & Conventions

### Policy Naming Conventions
Always prefix policy names by their Apigee policy type, separated by a hyphen:
* `AM-*`: AssignMessage (e.g., `AM-CreateQuery.xml`, `AM-FormatResponse.xml`)
* `EV-*`: ExtractVariables (e.g., `EV-ExtractQueryResults.xml`)
* `JS-*`: JavaScript (e.g., `JS-FormatResponse.xml`)
* `KVM-*`: KeyValueMapOperations (e.g., `KVM-GetConfigurations.xml`)
* `CORS-*`: CORS policy (e.g., `CORS-AddCORS.xml`)
* `XML-*`: XMLToJSON / JSONToXML

> [!IMPORTANT]
> The policy XML file name must match the `<* name="...">` root attribute exactly (e.g., `AM-CreateQuery.xml` must define `<AssignMessage name="AM-CreateQuery">`).

### Dynamic Routing & Target URLs
* **Never hardcode Google Cloud Project IDs or Apigee organization names** in proxy or target endpoints.
* Always leverage built-in context variables such as `{organization.name}` (which maps to the GCP project ID in Apigee X/Hybrid):
  ```xml
  <URL>https://bigquery.googleapis.com/bigquery/v2/projects/{organization.name}/queries</URL>
  ```
* For GCP services, authenticate using dynamic Google access tokens:
  ```xml
  <Authentication>
    <GoogleAccessToken>
      <Scopes>
        <Scope>https://www.googleapis.com/auth/bigquery</Scope>
      </Scopes>
    </GoogleAccessToken>
  </Authentication>
  ```

### JavaScript Policy Best Practices (`resources/jsc/*.js`)
* JavaScript policies run within the Apigee Rhino runtime. Do **not** use Node.js-specific modules or APIs (`require`, `process`, `Buffer`, ES modules).
* Keep transformations deterministic, pure, and safe against null/undefined values.
* Write or update unit tests under `test/unit-tests/` whenever changing JavaScript policy scripts.

### OpenAPI Specification Sync
* When adding or modifying endpoints, query parameters, or responses in the proxy, update the OpenAPI specification file:
  `src/main/apigee/apiproxies/gcpreleases-v1/apiproxy/resources/oas/apispec.yaml`

---

## 3. Mandatory Quality Gates for Agents

Before completing any task or proposing changes, AI agents must run the following verification steps in sequence:

### Gate 1: Run Apigee Linter (Mandatory on Policy/XML Changes)

Whenever modifying policies, targets, proxies, or configuration files, run the linter:

```bash
npm run lint
```
Or directly:
```bash
./ci/lint.sh
```

**Expectations:**
* **0 Errors**: The linter must pass with zero errors.
* **Review Warnings**: Do not introduce new lint warnings (e.g., unused variables, missing conditions, or unnecessary `AssignTo` elements).

### Gate 2: Run Unit Tests

Whenever JavaScript policies or transformation logic are created or edited:

```bash
npm test
```

Unit tests run in isolation using Mocha and mock Apigee runtime objects (`context`, `request`, `response`).

### Gate 3: Local Testing with Apigee Emulator

To validate end-to-end proxy behavior locally without deploying to Google Cloud, execute the emulator workflow:

#### Step 1: Pre-flight & Configuration Setup
Ensure Docker is running on the host. Generate local environment configurations from templates:
```bash
make setup-local
```
This generates:
* `src/main/apigee/environments/dev/deployments.json`
* `src/tests/dev/maps.json`

#### Step 2: Start the Emulator Container
```bash
./ci/apigee-emulator.sh start
# or: make emulator-start
```
Wait until the healthcheck confirms the emulator management API is healthy at `http://localhost:8080`.

#### Step 3: Deploy the Proxy Bundle
Deploy the proxy and load mock KVMs into the emulator's `dev` environment:
```bash
./ci/apigee-emulator.sh deploy dev
# or: make emulator-deploy
```

#### Step 4: Verify Emulator Status
Confirm the proxy is deployed and registered:
```bash
./ci/apigee-emulator.sh status
# or: make emulator-status
```

#### Step 5: Test Endpoints Locally
Perform quick sanity checks against the local runtime ingress (`http://localhost:8999`):
```bash
# Test mock echo endpoint
./ci/apigee-emulator.sh test /gcpreleases/v1/echo

# Test OpenAPI discovery endpoint
curl -s http://localhost:8999/gcpreleases/v1/openapi.json | jq .
```

To run the automated BDD integration test suite:
```bash
export APIGEE_PROTO=http
export APIGEE_HOST=localhost:8999/gcpreleases/v1

# If a GCP Service Account key is present in cert/service-account.json:
npm run integration-test

# If running without GCP credentials (offline / mock tests only):
./node_modules/.bin/cucumber-js \
  test/integration-tests/echo.feature \
  test/integration-tests/oas.feature \
  test/integration-tests/errors.feature \
  -f @cucumber/pretty-formatter
```

Or run the complete pre-commit suite:
```bash
./ci/pre-commit-checks.sh
```

#### Step 6: Stop the Emulator
Always terminate the emulator container after testing:
```bash
./ci/apigee-emulator.sh stop
# or: make emulator-stop
```

---

## 4. Credentials & Security Safety

> [!CAUTION]
> * **Never commit private keys, secrets, or tokens.**
> * The `cert/` directory and `*.key` / `*.json` credential files are explicitly ignored in `.gitignore`.
> * The service account key `cert/service-account.json` is strictly for local emulator volume mounting. Never upload or embed it into proxy bundles or git commits.

---

## 5. Summary Reference Checklist

When editing the codebase:
- [ ] Modified XML policy or proxy flow? -> Run `npm run lint`.
- [ ] Modified JavaScript transformation? -> Run `npm test`.
- [ ] Added or updated an endpoint? -> Update `apispec.yaml`.
- [ ] Tested end-to-end locally? -> Run `./ci/apigee-emulator.sh deploy dev && ./ci/apigee-emulator.sh test`.
- [ ] Stopped the emulator container? -> Run `./ci/apigee-emulator.sh stop`.
- [ ] Ensured no secrets or generated `.json` files are committed.

