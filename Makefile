CHART_DIR	:= helm-charts
GIT_VERSION	?= $(shell git describe --dirty=-unsupported --always --long --tags)
HELM_IMAGE	?= infoblox/helm:3.2.4-5b243a2
DOCKER_RUNNER	?= docker run --rm -i \
			--entrypoint="" \
			--network host \
			-e KUBECONFIG=/apps/.kube/$(notdir $(KUBECONFIG)) \
			-v $(dir $(KUBECONFIG)):/apps/.kube/ \
			-v $(PWD):/apps \
			$(HELM_IMAGE)
HELM		?= $(DOCKER_RUNNER) \
			helm
HELM_CMD	?= $(DOCKER_RUNNER) \
			/bin/bash -c
K8S_RELEASE	?= v1.19.0
KUBEADM		?= docker run --rm -it --entrypoint="" kindest/node:$(K8S_RELEASE) kubeadm
KUBECONFIG	?= ${HOME}/.kube/config
RELEASE_NAME	?= $(USER)

default: all

.PHONY: $(CHART_DIR)/konk/image-tag-values.yaml
$(CHART_DIR)/konk/image-tag-values.yaml:
	@IMAGES=`$(KUBEADM) config images list` && \
	APISERVER_VERSION=`echo "$$IMAGES" | grep apiserver | cut -d: -f2` && \
	ETCD_VERSION=`echo "$$IMAGES" | grep etcd | cut -d: -f2` && \
	echo "# kubernetes $(K8S_RELEASE)\napiserver:\n  image:\n    tag: $$APISERVER_VERSION\netcd:\n  image:\n    tag: $$ETCD_VERSION" | tee $@

helm-lint: helm-lint-$(notdir $(CHART_DIR)/*)

helm-lint-%:
	$(HELM) lint $(CHART_DIR)/$*

# Run this only if your cluster does not have cert-manager already deployed
deploy-cert-manager:
	$(HELM_CMD) "helm repo add jetstack https://charts.jetstack.io && helm upgrade -i --wait cert-manager --namespace cert-manager jetstack/cert-manager --version v1.0.1 \
		--create-namespace \
		--set installCRDs=true \
		--set extraArgs[0]="--enable-certificate-owner-ref=true""

%-konk-operator: HELM_FLAGS ?= --set=image.tag=$(GIT_VERSION) --set=image.pullPolicy=IfNotPresent

deploy-%: package
	$(HELM) upgrade -i --wait $(RELEASE_NAME)-$* $(CHART_DIR)/$* $(HELM_FLAGS)

test-%:
	$(HELM) test --logs $(RELEASE_NAME)-$*

teardown-%:
	$(HELM) delete $(RELEASE_NAME)-$*


# Current Operator version
VERSION ?= 0.0.1
# Default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Image URL to use all building/pushing image targets
IMG ?= infoblox/konk:$(GIT_VERSION)

all: docker-build

# Run against the configured Kubernetes cluster in ~/.kube/config
run: helm-operator
	$(HELM_OPERATOR) run

# Install CRDs into a cluster
install: kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Undeploy controller in the configured Kubernetes cluster in ~/.kube/config
undeploy: kustomize
	$(KUSTOMIZE) build config/default | kubectl delete -f -

# Build the docker image
docker-build:
	docker build . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

PATH  := $(PATH):$(PWD)/bin
SHELL := env PATH=$(PATH) /bin/sh
OS    = $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH  = $(shell uname -m | sed 's/x86_64/amd64/')
OSOPER   = $(shell uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/apple-darwin/' | sed 's/linux/linux-gnu/')
ARCHOPER = $(shell uname -m )

kustomize:
ifeq (, $(shell which kustomize 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p bin ;\
	curl -sSLo - https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.5.4/kustomize_v3.5.4_$(OS)_$(ARCH).tar.gz | tar xzf - -C bin/ ;\
	}
KUSTOMIZE=$(realpath ./bin/kustomize)
else
KUSTOMIZE=$(shell which kustomize)
endif

konk-operator-${GIT_VERSION}.tgz:
	mkdir -p helm-charts/konk-operator/crds
	cp -vR config/crd/bases/* helm-charts/konk-operator/crds/
	cp -vR config/rbac helm-charts/konk-operator/
	${HELM} package helm-charts/konk-operator --version ${GIT_VERSION} --app-version ${GIT_VERSION}

konk-${GIT_VERSION}.tgz:
	${HELM} package helm-charts/konk --version ${GIT_VERSION}

package: konk-operator-${GIT_VERSION}.tgz konk-${GIT_VERSION}.tgz

helm-operator:
ifeq (, $(shell which helm-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p bin ;\
	curl -LO https://github.com/operator-framework/operator-sdk/releases/download/v1.0.0/helm-operator-v1.0.0-$(ARCHOPER)-$(OSOPER) ;\
	mv helm-operator-v1.0.0-$(ARCHOPER)-$(OSOPER) ./bin/helm-operator ;\
	chmod +x ./bin/helm-operator ;\
	}
HELM_OPERATOR=$(realpath ./bin/helm-operator)
else
HELM_OPERATOR=$(shell which helm-operator)
endif

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: kustomize
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# TODO Replace with controller_gen
manifests: $(KUSTOMIZE)
	$(KUSTOMIZE) build config/crd/ > .tmp.konk
	mv .tmp.konk config/crd/bases/konk.infoblox.com_konks.yaml
