CHART_DIR	:= helm-charts
GIT_VERSION	:= $(shell git describe --always --long --tags)
CHART_PKG_VERSION ?= $(GIT_VERSION)
HELM_IMAGE	?= infoblox/helm:3
DOCKER_RUNNER	?= docker run --rm -i \
			--entrypoint="" \
			--network host \
			-e KUBECONFIG=/apps/.kube/$(notdir $(KUBECONFIG)) \
			-v $(dir $(KUBECONFIG)):/apps/.kube/ \
			-v $(shell pwd):/apps \
			-w /apps \
			$(HELM_IMAGE)
HELM		?= $(DOCKER_RUNNER) \
			helm
HELM_CMD	?= $(DOCKER_RUNNER) \
			/bin/bash -c
K8S_RELEASE	?= v1.25.8
ETCD_VERSION	?= v3.6.8
KUBEADM		?= docker run --rm -it --entrypoint="" ${KUBERNETES_IMG} kubeadm
KUBECONFIG	?= ${HOME}/.kube/config
RELEASE_PREFIX	?= $(USER)

CHART_READMES   ?= $(foreach chart,konk konk-service,$(CHART_DIR)/$(chart)/README.md)
HELM_DOCS       ?= docker run --rm \
			-v $(shell pwd):/helm-docs \
			-u $(shell id -u) \
			jnorwood/helm-docs:latest

# KIND env variables
KIND_NAME   	?= konk
NODE_VERSION    ?= v1.31.4
NODE_IMAGE      ?= kindest/node:${NODE_VERSION}
KIND_VERSION    ?= v0.25.0
KIND_ARCH       ?= $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
KIND 			:= $(shell pwd)/bin/kind

default: all

.PHONY: $(CHART_DIR)/konk/image-tag-values.yaml
$(CHART_DIR)/konk/image-tag-values.yaml:
	@printf "# kubernetes $(K8S_RELEASE)\napiserver:\n  image:\n    tag: $(K8S_RELEASE)-$(GIT_SHORT)\netcd:\n  image:\n    tag: $(ETCD_VERSION)\nprovision:\n  image:\n    tag: $(GIT_VERSION)\nkind:\n  image:\n    tag: $(GIT_VERSION)\n" | tee $@

CHART_NAMES := $(shell find $(CHART_DIR) -maxdepth 1 -type d | grep -v '^$(CHART_DIR)$$' | xargs -I {} basename {})

helm-lint: $(addprefix helm-lint-,$(CHART_NAMES))

helm-lint-%:
	$(HELM) lint $(CHART_DIR)/$*/ --set=isLint=true

# Run this only if your cluster does not have cert-manager already deployed
deploy-cert-manager:
	$(HELM_CMD) "helm repo add jetstack https://charts.jetstack.io && helm upgrade -i --wait cert-manager --namespace cert-manager jetstack/cert-manager --version '~v1' \
		--create-namespace \
		--set installCRDs=true \
		--set extraArgs[0]="--enable-certificate-owner-ref=true""

deploy-crds: konk-operator-${CHART_PKG_VERSION}.tgz
	# https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
	# > There is no support at this time for upgrading or deleting CRDs using Helm.
	kubectl apply -f helm-charts/konk-operator/crds

%-konk-operator: HELM_FLAGS ?=--set=image.tag=$(GIT_VERSION) --set=image.pullPolicy=IfNotPresent

deploy-%: package
	$(HELM) upgrade -i --wait $(RELEASE_PREFIX)-$* $(CHART_DIR)/$* $(HELM_FLAGS)

ifdef KONK_NAMESPACE
test-konk: HELM_FLAGS=--namespace=${KONK_NAMESPACE}
endif

test-%:
	START=`date +%s`; \
	until $(HELM) test "$(RELEASE_PREFIX)-$*" --timeout 2m --logs $(HELM_FLAGS); \
	do \
		NOW=`date +%s`; \
		[ $$(( NOW-START )) -lt 120 ] || exit 1; \
		sleep 10; \
	done; \

test-konk-local:
	kubectl delete -f test/konk.fail.yaml || true
	kubectl create -f test/konk.fail.yaml
	until kubectl wait --timeout=10s \
		--for=condition=ReleaseFailed \
		konk failstodeploy; \
	do \
		kubectl get konks; \
		kubectl get konk failstodeploy -o jsonpath='{.status.conditions[-1]}' | jq . ; \
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
IMG ?= ghcr.io/infobloxopen/konk:$(GIT_VERSION)
PROVISION_IMG ?= ghcr.io/infobloxopen/konk-provision:$(GIT_VERSION)
KONK_SERVICE_IMG ?= ghcr.io/infobloxopen/konk-service:$(GIT_VERSION)
GIT_SHORT ?= g$(shell git rev-parse --short HEAD)
KUBERNETES_IMG ?= ghcr.io/infobloxopen/konk-app:$(K8S_RELEASE)-$(GIT_SHORT)

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

.image-${GIT_VERSION}: $(CHART_DIR)/konk/image-tag-values.yaml
	DOCKER_BUILDKIT=1 docker build . -t ${IMG}
	touch $@

# Build the docker image
docker-build: .image-${GIT_VERSION}

# Push the docker image
docker-push:
	docker push ${IMG}

# Build patched kubernetes (kubeadm + kube-apiserver) from source with upgraded deps
.kubernetes-image-${K8S_RELEASE}-${GIT_SHORT}:
	DOCKER_BUILDKIT=1 docker build \
		--build-arg K8S_VERSION=$(K8S_RELEASE) \
		-t ${KUBERNETES_IMG} \
		build/kubernetes/
	touch $@

docker-build-kubernetes: .kubernetes-image-${K8S_RELEASE}-${GIT_SHORT}

# Regenerate build/kubernetes/go.mod with latest dependency versions.
# Review the diff and commit the result.
update-kubernetes-deps:
	build/kubernetes/update-deps.sh $(K8S_RELEASE) $(shell go env GOVERSION | sed 's/^go//')

# Push the kubernetes docker image
docker-push-kubernetes:
	docker push ${KUBERNETES_IMG}

# Build the provision docker image (depends on kubernetes build)
.provision-image-${GIT_VERSION}: .kubernetes-image-${K8S_RELEASE}-${GIT_SHORT}
	DOCKER_BUILDKIT=1 docker build \
		--build-arg KUBERNETES_IMG=${KUBERNETES_IMG} \
		-f Dockerfile.provision . -t ${PROVISION_IMG}
	touch $@

docker-build-provision: .provision-image-${GIT_VERSION}

# Push the provision docker image
docker-push-provision:
	docker push ${PROVISION_IMG}

# Build the konk-service docker image (Go binary replacing shell-based konk-tools for konk-service chart)
.konk-service-image-${GIT_VERSION}:
	DOCKER_BUILDKIT=1 docker build \
		-f Dockerfile.konk-service . -t ${KONK_SERVICE_IMG}
	touch $@

docker-build-konk-service: .konk-service-image-${GIT_VERSION}

# Push the konk-service docker image
docker-push-konk-service:
	docker push ${KONK_SERVICE_IMG}

PATH  := $(PATH):$(shell pwd)/bin
SHELL := env PATH="$(PATH)" /bin/sh
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

konk-operator-${CHART_PKG_VERSION}.tgz:
	mkdir -p helm-charts/konk-operator/crds
	cp -vR config/crd/bases/* helm-charts/konk-operator/crds/
	cp -vR config/rbac helm-charts/konk-operator/
	${HELM} package helm-charts/konk-operator --version ${CHART_PKG_VERSION} --app-version ${GIT_VERSION}

%-${CHART_PKG_VERSION}.tgz:
	${HELM} package helm-charts/$* --version ${CHART_PKG_VERSION}

package: konk-operator-${CHART_PKG_VERSION}.tgz konk-${CHART_PKG_VERSION}.tgz konk-service-${CHART_PKG_VERSION}.tgz example-apiserver-${CHART_PKG_VERSION}.tgz

OPERATOR_VERSION:=v1.42.0
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
	curl -Lo bin/kind-${KIND_VERSION} https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-$(shell uname | tr '[:upper:]' '[:lower:]')-${KIND_ARCH}
	chmod +x bin/kind-${KIND_VERSION}

$(shell pwd)/bin/kind: bin/kind-${KIND_VERSION}
	ln -sf $(shell pwd)/$< bin/kind

kind: $(KIND)
	$(KIND) create cluster -v 1 --name ${KIND_NAME} --image ${NODE_IMAGE} --config=test/kind.yaml
	@# Increase inotify limits to prevent "too many open files" in kube-proxy
	docker exec ${KIND_NAME}-control-plane sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=1024

kind-destroy: $(KIND)
	$(KIND) delete cluster --name ${KIND_NAME}

kind-load-konk: $(KIND) docker-build docker-build-kubernetes docker-build-provision docker-build-konk-service
	@# Tag images with the chart appVersion so the operator's embedded chart can find them
	docker tag ${KUBERNETES_IMG} ghcr.io/infobloxopen/konk-app:$(K8S_RELEASE)
	docker tag ${PROVISION_IMG} ghcr.io/infobloxopen/konk-provision:$(K8S_RELEASE)
	docker tag ${KONK_SERVICE_IMG} ghcr.io/infobloxopen/konk-service:$(K8S_RELEASE)
	$(KIND) load docker-image ${IMG} ${KUBERNETES_IMG} ${PROVISION_IMG} ${KONK_SERVICE_IMG} \
		ghcr.io/infobloxopen/konk-app:$(K8S_RELEASE) ghcr.io/infobloxopen/konk-provision:$(K8S_RELEASE) \
		ghcr.io/infobloxopen/konk-service:$(K8S_RELEASE) \
		--name ${KIND_NAME}

kind-load-apiserver: QUAY_IMG=$(shell $(HELM) template helm-charts/example-apiserver | awk '/image: quay/ {print $$2}')
kind-load-apiserver: $(KIND) .image-apiserver-${GIT_VERSION}

.image-apiserver-${GIT_VERSION}:
	$(MAKE) -C test/apiserver kind-load \
		KIND=$(KIND) KIND_NAME=${KIND_NAME} \
		IMAGE_TAG=${GIT_VERSION} \
		BUILD_FLAGS="-mod=readonly"


.PHONY: $(CHART_READMES)
$(CHART_READMES):
	$(HELM_DOCS) -c $(@D) -t ../README.md.gotmpl

chart-readmes: $(CHART_READMES)

deploy-ingress-nginx: INGRESS_VERSION = $(shell curl -sS https://api.github.com/repos/kubernetes/ingress-nginx/releases | jq '[.[] | select(.draft==false and .prerelease==false and (.tag_name | startswith("controller-"))) | .tag_name][0]' -r)
deploy-ingress-nginx:
	# avoids accidentally deploying ingress controller in shared clusters
	kubectl config current-context | grep -v -E '(^[a-z]{3}-[0-9])|(infoblox.com$$)'
	# https://kind.sigs.k8s.io/docs/user/ingress/#ingress-nginx
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml
	until kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=10s; \
	do \
		kubectl --namespace ingress-nginx describe pod -l app.kubernetes.io/component=controller; \
	done

deploy-example-apiserver: HELM_FLAGS ?=--set=image.pullPolicy=IfNotPresent
deploy-example-apiserver: kind-load-apiserver
	$(HELM) upgrade --debug -i \
	 	--wait --timeout=8m $(RELEASE_PREFIX)-apiserver \
	 	$(CHART_DIR)/example-apiserver \
		--set=image.tag=$(GIT_VERSION) \
		--set=kind.image.tag=$(K8S_RELEASE) \
	 	$(HELM_FLAGS)

upgrade-etcd:
	cd $(CHART_DIR) && \
	rm -rf etcd* && \
	helm pull --debug --untar --repo https://charts.bitnami.com/bitnami etcd

clean:
	rm -rf \
	.image-* \
	.kind-load-* \
	.kubernetes-image-* \
	.provision-image-* \
	.konk-service-image-* \
	*.tgz \
	bin/ \
	helm-charts/konk-operator/crds/ \
	helm-charts/konk-operator/rbac \
	test/apiserver/.image-*