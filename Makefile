# Can be set from command line, like `make deploy ENV=prod`
GCP_PROJECT := $(shell gcloud config get-value project 2>/dev/null)
ifeq ($(strip $(GCP_PROJECT)),)
  GCP_PROJECT := training-gcp-demos
endif

ifdef GOOGLE_CLOUD_PROJECT
  ORG ?= $(GOOGLE_CLOUD_PROJECT)
else
  ORG ?= $(GCP_PROJECT)
endif
ENV=eval
SA=apigee-demos@$(ORG).iam.gserviceaccount.com
SKIP_BUNDLE_UPLOAD=false

# Global configuration
PROXY=gcpreleases-v1
PROXY_DIR=src/main/apigee/apiproxies/$(PROXY)
TARGET=$(PWD)/target
BUNDLE_ZIP_DIR=$(TARGET)/bundles
BUNDLE_ZIP_FILE:=$(BUNDLE_ZIP_DIR)/$(PROXY)_$(shell date +%Y%m%d%H%M%S).zip

all: bundle

# Ref https://cloud.google.com/apigee/docs/api-platform/fundamentals/download-api-proxies#upload
bundle:
	mkdir -p $(BUNDLE_ZIP_DIR)
	cd $(PROXY_DIR) && zip $(BUNDLE_ZIP_FILE) -r ./

clean:
	rm -rvf $(BUNDLE_ZIP_DIR)

deploy-with-script: clean bundle
	ci/deploy-proxy-bundle.sh "$(BUNDLE_ZIP_FILE)"

# Ref: https://github.com/apigee/apigeecli/blob/main/docs/apigeecli_apis_deploy.md
.apigeecli-setup:
	apigeecli prefs set -o $(ORG)
	apigeecli token cache --token $$(gcloud auth print-access-token) 2>/dev/null >/dev/null

deploy: clean bundle .apigeecli-setup
	if [ "$(SKIP_BUNDLE_UPLOAD)" = "false" ] ; then \
		apigeecli apis create bundle --name $(PROXY) --proxy-zip $(BUNDLE_ZIP_FILE) ;\
	fi
	apigeecli apis deploy --env $(ENV) --ovr --name $(PROXY) --sa $(SA) --wait

clean-revisions: .apigeecli-setup
	apigeecli apis clean --name $(PROXY) --report=false

# Local API client helper
swagger-ui:
	docker run --rm --name swagger-ui -p 8999:8080 \
		-v $(PWD)/src/main/apigee/apiproxies:/specs \
		-e SWAGGER_JSON=/specs/blogposts-v1/apiproxy/resources/oas/apispec.yaml \
		swaggerapi/swagger-ui

# Service account setup
service-account:
	gcloud iam service-accounts describe $(SA) >/dev/null 2>&1 || gcloud iam service-accounts create apigee-demos
	PROJECT_NUMBER="$$(gcloud projects describe $(ORG) --format='value(projectNumber)')" ; \
	gcloud iam service-accounts add-iam-policy-binding $(SA) \
		--member="serviceAccount:service-$$PROJECT_NUMBER@gcp-sa-apigee.iam.gserviceaccount.com" \
		--role="roles/iam.serviceAccountTokenCreator"
	gcloud projects add-iam-policy-binding $(ORG) --member=serviceAccount:$(SA) --role="roles/bigquery.user"
	gcloud projects add-iam-policy-binding $(ORG) --member=serviceAccount:$(SA) --role="roles/iam.serviceAccountTokenCreator"

cert/service-account.json:
	mkdir -p cert
	$(MAKE) service-account
	gcloud iam service-accounts keys create --iam-account=$(SA) cert/service-account.json

service-account-key: cert/service-account.json

# Local emulator configuration from template and service account key setup
setup-local: cert/service-account.json
	mkdir -p cert
	sed "s/PROJECT_ID/$(ORG)/g" src/main/apigee/environments/dev/deployments.json.template > src/main/apigee/environments/dev/deployments.json