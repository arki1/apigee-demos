# apigee-demos

Apigee API Proxy demo (`gcpreleases-v1`) showcasing how to implement and monetize data-driven APIs on Google Cloud Apigee X / Hybrid using BigQuery.

This project was inspired by the Google Cloud video on **Monetizing Data with Apigee**:
* 🎥 [Inspiration: Monetizing Data with Apigee](https://www.youtube.com/watch?v=lUDZAzSpWEw)
* 🎥 [In-depth Walkthrough: Implementation Details](https://youtu.be/58smxQu3P5k)

The demo leverages BigQuery's synchronous query execution method (`jobs.query`) to query Google Cloud public release notes and return formatted API responses, showing how enterprises can securely expose and productize their data assets through Apigee.

This proxy demonstrates:
* **Dynamic Target Routing:** Generates the BigQuery API query URL dynamically using Apigee's built-in `{organization.name}` variable (which matches your Google Cloud Project ID), avoiding hardcoded project names across environments.
* **Google Authentication:** Configures `<GoogleAccessToken>` for secure, seamless IAM impersonation without static keys in production.
* **Response Transformation:** Transforms BigQuery tabular query responses into simplified JSON or XML objects via JavaScript and XML policies.
* **Environment Configuration:** Uses Key-Value Maps (KVM) for environment-specific parameters (e.g., `echoLimit`).
* **Local Emulator Support:** Ready for local development with Cloud Code / Apigee Emulator in Docker.

> [!WARNING]
> This proxy is intended for demonstration and learning purposes. In a production environment, ensure you apply appropriate security policies (OAuth/API Keys), Spike Arrest, Quotas, and caching!

---

## Prerequisites

Ensure the following tools are installed on your workstation:

* **Google Cloud SDK (`gcloud`):** Authenticated with permissions to manage Service Accounts and BigQuery (`gcloud auth login` and `gcloud auth application-default login`).
* **Node.js (v18+) and npm:** For unit tests, linter, and integration tests.
* **GNU `make`, `zip`, `unzip`, and `jq`:** Standard CLI build tools.
* **Docker:** Required for running the Apigee Emulator, Cloud Code local runtime, and Swagger UI.
* **[apigeecli](https://github.com/apigee/apigeecli) (Optional):** Required for automated deployments via `make deploy`. Install with:
  ```bash
  curl -L https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | sh -
  export PATH=$PATH:$HOME/.apigeecli/bin
  ```

---

## Configuration & Project Selection

The provided [`Makefile`](Makefile) automatically resolves your active GCP project using:
1. `$GOOGLE_CLOUD_PROJECT` (if set)
2. `gcloud config get-value project` (active gcloud project)
3. Default fallback: `training-gcp-demos`

You can explicitly override the target organization/project on any `make` command:
```bash
make <target> ORG=my-custom-project-id
```

---

## Local Development & Testing

### 1. One-Step Local Setup

To prepare your local environment for Cloud Code / Apigee Emulator, run:

```bash
make setup-local
```

This target:
1. Generates `src/main/apigee/environments/dev/deployments.json` from the template, configuring your project's service account.
2. Checks if `./cert/service-account.json` exists; if not, it automatically provisions the GCP Service Account with `roles/bigquery.user` and `roles/iam.serviceAccountTokenCreator`, and downloads the key to `./cert/` (which is kept out of Git via `.gitignore`).

### 2. Linting & Static Analysis

Validate the API Proxy bundle against Apigee X best practices using `apigeelint`:

```bash
./ci/lint.sh
```

### 3. Unit Tests

Run unit tests for JavaScript business logic (isolated transformation of BigQuery rows):

```bash
npm test
```

### 4. Running Integration Tests (BDD / Apickli)

If you have the Apigee Emulator running locally on port 8998:

```bash
npm run integration-test
```

Or run the complete pre-commit check (detects emulator container, runs linter, unit tests, and integration tests):

```bash
./ci/pre-commit-checks.sh
```

### 5. Local OpenAPI / Swagger Preview

To preview the API specification in a local Swagger UI container:

```bash
make swagger-ui
```
Open your browser at `http://localhost:8999`.

---

## Cloud Deployment (Apigee X / Hybrid)

### Option A: Automated Deploy via `apigeecli` (Recommended)

1. Provision the Service Account and IAM roles in Google Cloud:
   ```bash
   make service-account
   ```
2. Deploy the proxy bundle to your environment (`eval` by default):
   ```bash
   make deploy
   ```
   To deploy to a specific environment (e.g., `prod`):
   ```bash
   make deploy ENV=prod
   ```

### Option B: Manual Bundle Upload via Apigee Console

1. Create a deployable `.zip` bundle:
   ```bash
   make bundle
   ```
   The bundle will be generated under `target/bundles/gcpreleases-v1_<timestamp>.zip`.
2. In the Google Cloud Console, navigate to **Apigee > Proxies > Upload Proxy Bundle**.
3. Deploy the proxy to your environment using the service account `apigee-demos@<PROJECT_ID>.iam.gserviceaccount.com`.

> [!NOTE]
> Unlike older versions of this demo, you **do not** need to edit the BigQuery target endpoint URL manually. The proxy automatically uses `{organization.name}` to route queries to your Google Cloud Project!

---

## Verifying the Deployment

### From an internal Test VM or peered VPC:

```bash
export AUTH="Authorization: Bearer $(gcloud auth print-access-token)"
export PROJECT_ID="$(gcloud config get project)"
export ENV_GROUP_HOSTNAME=$(curl -s -H "$AUTH" https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/envgroups | jq -r '.environmentGroups[0].hostnames[0]')

# Test the mock echo endpoint
curl -k https://${ENV_GROUP_HOSTNAME}/gcpreleases/v1/echo | jq .

# Query recent Google Cloud release notes from BigQuery
curl -k https://${ENV_GROUP_HOSTNAME}/gcpreleases/v1/releases | jq .

# Limit results and request XML format
curl -k -H "Accept: application/xml" "https://${ENV_GROUP_HOSTNAME}/gcpreleases/v1/releases?limit=3"
```

---

## References

* [Video: Monetizing Data with Apigee (Inspiration)](https://www.youtube.com/watch?v=lUDZAzSpWEw)
* [Video: In-depth Walkthrough & Implementation Details](https://youtu.be/58smxQu3P5k)
* [Apigee: Using Google Authentication](https://cloud.google.com/apigee/docs/api-platform/security/google-auth/overview)
* [Apigee Emulator Local Development](https://cloud.google.com/apigee/docs/api-platform/local-development/vscode/overview)
* [BDD Proxy Development with Apigee](https://github.com/apigee/devrel/blob/main/labs/bdd-proxy-development/lab.md)
* [BigQuery Public Datasets: Google Cloud Release Notes](https://console.cloud.google.com/marketplace/product/bigquery-public-data/google-cloud-release-notes)
