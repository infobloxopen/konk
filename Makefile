CHART_DIR	:= helm-charts
GIT_VERSION	?= $(shell git describe --dirty=-unsupported --always --long --tags)
HELM_IMAGE	?= infoblox/helm:3.2.4-5b243a2
DOCKER_RUNNER	?= docker run --rm -i \
			--entrypoint="" \
			--network host \
			-e KUBECONFIG=/apps/.kube/$(notdir $(KUBECONFIG)) \
			-v $(dir $(KUBECONFIG)):/apps/.kube/ \
			-v $(shell pwd):/apps \
			$(HELM_IMAGE)
HELM		?= $(DOCKER_RUNNER) \
			helm
HELM_CMD	?= $(DOCKER_RUNNER) \
			/bin/bash -c
K8S_RELEASE	?= v1.19.0
KUBEADM		?= docker run --rm -it --entrypoint="" kindest/node:$(K8S_RELEASE) kubeadm
KUBECONFIG	?= ${HOME}/.kube/config
RELEASE_PREFIX	?= $(USER)

# KIND env variables
KIND_NAME   	?= konk
NODE_VERSION    ?= v1.19.0
NODE_IMAGE      ?= kindest/node:${NODE_VERSION}
KIND_VERSION    ?= v0.8.1
KIND 			:= $(shell pwd)/bin/kind

default: all

.PHONY: $(CHART_DIR)/konk/image-tag-values.yaml
$(CHART_DIR)/konk/image-tag-values.yaml:
	@IMAGES=`$(KUBEADM) config images list` && \
	APISERVER_VERSION=`echo "$$IMAGES" | grep apiserver | cut -d: -f2` && \
	ETCD_VERSION=`echo "$$IMAGES" | grep etcd | cut -d: -f2` && \
	echo "# kubernetes $(K8S_RELEASE)\napiserver:\n  image:\n    tag: $$APISERVER_VERSION\netcd:\n  image:\n    tag: $$ETCD_VERSION" | tee $@

helm-lint: helm-lint-$(notdir $(CHART_DIR)/*)

helm-lint-%:
	$(HELM) lint $(CHART_DIR)/$* --set=isLint=true

# Run this only if your cluster does not have cert-manager already deployed
deploy-cert-manager:
	$(HELM_CMD) "helm repo add jetstack https://charts.jetstack.io && helm upgrade -i --wait cert-manager --namespace cert-manager jetstack/cert-manager --version v1.0.1 \
		--create-namespace \
		--set installCRDs=true \
		--set extraArgs[0]="--enable-certificate-owner-ref=true""

%-konk-operator: HELM_FLAGS ?=--set=image.tag=$(GIT_VERSION) --set=image.pullPolicy=IfNotPresent

deploy-%: package
	$(HELM) upgrade -i --wait $(RELEASE_PREFIX)-$* $(CHART_DIR)/$* $(HELM_FLAGS)

test-%:
	$(HELM) test "$(RELEASE_PREFIX)-$*" --timeout 2m --logs

test-konk-local:
	kubectl delete -f test/konk.fail.yaml || true
	kubectl create -f test/konk.fail.yaml
	until kubectl wait --timeout=1s \
		--for=condition=ReleaseFailed \
		konk failstodeploy; \
    do \
      sleep 1s; \
    done

teardown-%:
	$(HELM) delete $(RELEASE_PREFIX)-$*

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
run: $(HELM_OPERATOR) $(OPERATOR_SDK)
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

.image-${GIT_VERSION}:
	docker build . -t ${IMG}
	touch $@

# Build the docker image
docker-build: .image-${GIT_VERSION}

# Push the docker image
docker-push:
	docker push ${IMG}

PATH  := $(PATH):$(shell pwd)/bin
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

%-${GIT_VERSION}.tgz:
	${HELM} package helm-charts/$* --version ${GIT_VERSION}

package: konk-operator-${GIT_VERSION}.tgz konk-${GIT_VERSION}.tgz konk-service-${GIT_VERSION}.tgz example-apiserver-${GIT_VERSION}.tgz

OPERATOR_VERSION:=v1.1.0
./bin/%: ./bin/%-$(OPERATOR_VERSION)
	ln -sf $(^F) $@

./bin/%-$(OPERATOR_VERSION):
	mkdir -p bin
	curl -L -o ./$@ https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_VERSION)/$*-$(OPERATOR_VERSION)-$(ARCHOPER)-$(OSOPER)
	chmod +x $@

# prevent make from deleting intermediate files
not_intermediates: ./bin/helm-operator-$(OPERATOR_VERSION) ./bin/operator-sdk-$(OPERATOR_VERSION)

HELM_OPERATOR:=./bin/helm-operator
OPERATOR_SDK:=./bin/operator-sdk

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: kustomize $(OPERATOR_SDK)
	$(OPERATOR_SDK) generate kustomize manifests
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(OPERATOR_SDK) bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# TODO Replace with controller_gen
manifests: $(KUSTOMIZE)
	$(KUSTOMIZE) build config/crd/ > .tmp.konk
	mv .tmp.konk config/crd/bases/konk.infoblox.com_konks.yaml

# kind
bin/kind-${KIND_VERSION}:
	mkdir -p bin
	curl -Lo bin/kind-${KIND_VERSION} https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-$(shell uname)-amd64
	chmod +x bin/kind-${KIND_VERSION}

$(shell pwd)/bin/kind: bin/kind-${KIND_VERSION}
	ln -sf $(shell pwd)/$< bin/kind

kind: $(KIND)
	$(KIND) create cluster -v 1 --name ${KIND_NAME} --config=test/kind.yaml

kind-destroy: $(KIND)
	$(KIND) delete cluster --name ${KIND_NAME}

kind-load-konk: $(KIND) docker-build
	$(KIND) load docker-image ${IMG} --name ${KIND_NAME}

kind-load-apiserver: QUAY_IMG=$(shell $(HELM) template helm-charts/example-apiserver | awk '/image: quay/ {print $$2}')
kind-load-apiserver: $(KIND)
	$(MAKE) -C test/apiserver kind-load \
		KIND=$(KIND) KIND_NAME=${KIND_NAME} \
		IMAGE_TAG=${GIT_VERSION} \
		BUILD_FLAGS="-mod=readonly"

deploy-ingress-nginx:
	# avoids accidentally deploying ingress controller in shared clusters
	kubectl config current-context | grep -v -E '(^[a-z]{3}-[0-9])|(infoblox.com$$)'
	# https://kind.sigs.k8s.io/docs/user/ingress/#ingress-nginx
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
	until kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=10s; \
	do \
		kubectl --namespace ingress-nginx describe pod -l app.kubernetes.io/component=controller; \
	done

deploy-apiserver: HELM_FLAGS ?=--set=image.tag=$(GIT_VERSION) --set=image.pullPolicy=IfNotPresent --set=konk.name=${KONK_NAME}
deploy-apiserver: kind-load-apiserver
	$(HELM) upgrade --debug -i \
	 	--wait $(RELEASE_PREFIX)-apiserver \
	 	$(CHART_DIR)/example-apiserver \
	 	$(HELM_FLAGS)
