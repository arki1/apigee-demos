# Apigee Local Emulator: Technical Guide & Reference

> [!CAUTION]
> **Disclaimer: Unofficial Documentation**
> This guide is an unofficial technical reference created and maintained by the community based on reverse engineering, container inspection, and operational practice. Google does not provide formal or comprehensive documentation for the standalone Apigee Emulator container (`gcr.io/apigee-release/hybrid/apigee-emulator`) or its internal management REST APIs. Features, internal APIs, and behaviors may vary across image versions without formal notice.

This document describes the internal workings, architecture, REST endpoints, and usage instructions for the **Apigee Emulator** (`gcr.io/apigee-release/hybrid/apigee-emulator`), used for local proxy development, testing, and CI/CD automation.

---

## 1. Architecture and Operation

The Apigee Emulator container runs a local version of the Apigee hybrid runtime packaged with an embedded local Apache Cassandra instance and the Apigee Microkernel:

* **Java Microkernel (`com.apigee.server.RuntimeEmulator`)**: Manages the lifecycle of internal services, proxy compilation, and dependency injection.
* **Apache Cassandra (local)**: Stores contract data, entities, and runtime states.
* **ConfigCompiler (`com.apigee.config.compiler.ConfigCompiler`)**: A compiler that reads XML configuration files for proxies, policies, and environments, validating and activating execution contracts in the message processor's memory.

### Ports and Communication

The container operates with two primary HTTP ports:

| Container Port | Host Port (Default) | Purpose | Description |
| :--- | :--- | :--- | :--- |
| **`8080`** | `8080` | **Management REST API** | Control endpoint for deploying proxies, loading test data (KVMs), and inspection. |
| **`8998`** | `8999` | **Proxy Runtime Traffic** | HTTP ingress for requests directed to deployed proxies (e.g., `http://localhost:8999/gcpreleases/v1/...`). |

> [!NOTE]
> The emulator does not automatically watch filesystem volumes for continuous compilation. All compilation and deployment must be triggered via HTTP calls to the management port (`8080`).

---

## 2. Management API Reference (`/v1/emulator/*`)

The management API responds under the `/v1` path prefix:

### 2.1 Information and Status

#### `GET /v1/emulator/version`
Returns the runtime version and active feature flags in the container:
```bash
curl -s http://localhost:8080/v1/emulator/version | jq .
```
Example response:
```json
{
  "releaseId": "1.11",
  "activeEnvironment": "dev",
  "emulatorFeatures": [
    "apigee-oauth",
    "google-service-accounts",
    "tls",
    "resource-references",
    "debug-trace",
    "feature-flags",
    "data-collectors",
    "analytics"
  ]
}
```

#### `GET /v1/emulator/tree`
Lists all proxies currently deployed to the emulator and their respective `basePath` configurations:
```bash
curl -s http://localhost:8080/v1/emulator/tree | jq .
```
Example response:
```json
[
  {
    "application": "gcpreleases-v1",
    "name": "default",
    "basePath": "gcpreleases/v1",
    "proxyUID": "1"
  }
]
```

---

### 2.2 Proxy & Contract Deployment

#### `POST /v1/emulator/deploy?environment={env}`
Accepts a `.zip` file containing the `src/` tree (including `src/main/apigee/apiproxies/` and `src/main/apigee/environments/{env}/deployments.json`). The emulator decompresses the archive, validates it via `ConfigCompiler`, and hot-deploys the revision.

* **Content-Type**: `application/octet-stream`
* **Query Parameter**: `environment` (e.g., `dev`)

Example deploy:
```bash
zip -r /tmp/bundle.zip src/
curl -s -X POST "http://localhost:8080/v1/emulator/deploy?environment=dev" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@/tmp/bundle.zip"
```
Expected response:
```json
{ "revision" : "1" }
```

---

### 2.3 Test Data and Mocks (KVMs, Apps, Products)

The emulator supports runtime mocks to emulate Key-Value Maps (KVMs), developers, API products, and developer applications.

#### `POST /v1/emulator/setup/tests`
Loads test data from a `.zip` archive containing one or more supported JSON definitions (`maps.json`, `products.json`, `developers.json`, `developerapps.json`):

* **Content-Type**: `application/octet-stream`

Example (loading KVMs):
```bash
cd src/tests/dev && zip -r /tmp/testdata.zip maps.json
curl -s -X POST "http://localhost:8080/v1/emulator/setup/tests" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@/tmp/testdata.zip"
```

#### `GET /v1/emulator/test/maps`
Inspects currently loaded Key-Value Maps:
```bash
curl -s http://localhost:8080/v1/emulator/test/maps | jq .
```

#### `DELETE /v1/emulator/clear/test`
Clears previously loaded test mocks:
```bash
curl -s -X DELETE http://localhost:8080/v1/emulator/clear/test
```

---

### 2.4 Local Trace & Debug

#### `POST /v1/emulator/trace?environment={env}`
Initiates a local trace/debug session for the specified environment.

#### `GET /v1/emulator/trace/transactions`
Retrieves collected transaction trace data processed during the debug session.

---

### 2.5 Emulator Reset

#### `POST /v1/emulator/reset`
Clears deployed proxies and resets the emulator to its initial state without restarting the container.

---

## 3. Google Cloud Service Account Authentication

When a policy or TargetEndpoint uses Google authentication (e.g., `<GoogleAccessToken>` to access BigQuery, Cloud Storage, or Cloud Logging):

```xml
<Authentication>
  <GoogleAccessToken>
    <Scopes>
      <Scope>https://www.googleapis.com/auth/bigquery</Scope>
    </Scopes>
  </GoogleAccessToken>
</Authentication>
```

The emulator requires:

1. **JSON Key mounted into the container**: A local directory containing the service account key (e.g., `./cert/service-account.json`) mounted at `/emulator/keys`.
2. **Environment variable set on the container**:
   ```bash
   -e GOOGLE_APPLICATION_CREDENTIALS=/emulator/keys/service-account.json
   ```
   > [!IMPORTANT]
   > During Java Microkernel initialization (`RuntimeEmulator.main`), the emulator verifies if the file path configured in `GOOGLE_APPLICATION_CREDENTIALS` exists on disk (`Files.exists`). If present, it initializes the `GoogleTokenService`. If missing, the service is not registered and authenticated calls will fail with an internal error (`NullPointerException`).
3. **Configuration mapping in `deployments.json` and KVM `maps.json`**:
   Both `deployments.json` and the KVM `maps.json` are dynamically generated from template files (`*.template`) to reflect the exact Project ID of the service account in `cert/service-account.json`:
   * `src/main/apigee/environments/<env>/deployments.json.template`
   * `src/tests/<env>/maps.json.template`

   Running `make setup-local` or `./ci/apigee-emulator.sh start` automatically generates these local files, which are excluded from Git by `.gitignore`.

---

## 4. Management via CLI (`ci/apigee-emulator.sh`)

The script [`ci/apigee-emulator.sh`](ci/apigee-emulator.sh) wraps all emulator operations into an easy-to-use CLI:

```bash
# Start emulator and wait for healthy state
./ci/apigee-emulator.sh start

# Deploy current bundle and load mock KVMs
./ci/apigee-emulator.sh deploy dev

# Inspect status and active proxies
./ci/apigee-emulator.sh status

# Execute a test request
./ci/apigee-emulator.sh test /gcpreleases/v1/echo

# Stop emulator container
./ci/apigee-emulator.sh stop
```

### Supported Configuration Variables

* `EMULATOR_IMAGE`: Docker image tag (default: `gcr.io/apigee-release/hybrid/apigee-emulator:2.0.2`)
* `EMULATOR_CONTAINER`: Docker container name (default: `apigee-localhost`)
* `EMULATOR_MGMT_PORT`: Host port for management API (default: `8080`)
* `EMULATOR_RUNTIME_PORT`: Host port for proxy runtime traffic (default: `8999`)
* `EMULATOR_KEYS_DIR`: Host directory mounted to `/emulator/keys` (default: `./cert`)
* `EMULATOR_SA_KEY`: Key filename inside the keys directory (default: `service-account.json`)
* `TIMEOUT_SECONDS`: Maximum seconds to wait during healthcheck (default: `120`)

---

## 5. Usage in CI/CD Pipelines

Example automation in CI/CD pipelines (GitHub Actions, Cloud Build, GitLab CI):

```bash
# 1. Start emulator
./ci/apigee-emulator.sh start

# 2. Deploy proxy bundle and mocks
./ci/apigee-emulator.sh deploy dev

# 3. Execute automated integration tests against local emulator
export APIGEE_PROTO=http
export APIGEE_HOST=localhost:8999/gcpreleases/v1
npm run integration-test

# 4. Stop and clean up container
./ci/apigee-emulator.sh stop
```
