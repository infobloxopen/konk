IMAGE_TAG  ?= $(shell git describe --tags --always)
IMAGE_REPO ?= infoblox/konk-apiserver-example
IMAGE      := $(IMAGE_REPO):$(IMAGE_TAG)

APISERVER_BOOT_VERSION := v1.18.0
APISERVER_BOOT := bin/apiserver-boot

GO_ENV ?= GO_ENABLED=0 GOOS=linux GOARCH=amd64

apiserver.tgz:
	curl -L --output $@ https://github.com/kubernetes-sigs/apiserver-builder-alpha/releases/download/${APISERVER_BOOT_VERSION}/apiserver-builder-alpha-${APISERVER_BOOT_VERSION}-linux-amd64.tar.gz

bin/apiserver-boot: apiserver.tgz
	tar -xvf apiserver.tgz
	bin/apiserver-boot version

generate: $(APISERVER_BOOT)
	GO111MODULE=off $(APISERVER_BOOT) build generated

image-apiserver-boot: APISERVER_FLAGS ?= --generate=false
image-apiserver-boot: $(APISERVER_BOOT)
	GO111MODULE=off $(APISERVER_BOOT) build container --image ${IMAGE} ${APISERVER_FLAGS}

# Must be run against latest apiserver-boot to include RBAC
config/apiserver.yaml: $(APISERVER_BOOT) image
	$(APISERVER_BOOT) build config --name contact --namespace default --image ${IMAGE}

config/konk.yaml: config/apiserver.yaml
	awk '{if (match($$0,"---")) exit; print}' config/apiserver.yaml > $@

config/infra.yaml: config/apiserver.yaml
	awk 'f;/---/{f=1}' config/apiserver.yaml > $@

config: config/konk.yaml config/infra.yaml

# deploy-infra on infra k8s
# deploy-konk on konk cluster
deploy-%: config/%.yaml
	kubectl apply -f $<

kind-load: KIND=false
kind-load: image
	$(KIND) load docker-image ${IMAGE} --name ${KIND_NAME}

kind-deploy-infra: kind-load deploy-%

.image-${IMAGE_TAG}: build
	docker build -t ${IMAGE} -f Dockerfile bin/
	touch $@

image: .image-${IMAGE_TAG}

build: bin/apiserver bin/controller-manager

# go list can build the dependency needed here
.PHONY: bin/controller-manager
bin/controller-manager:
	${GO_ENV} go build -o $@ ./cmd/manager

.PHONY: bin/apiserver
bin/apiserver:
	${GO_ENV} go build -o $@ ./cmd/apiserver

run:
	apiserver-boot run in-cluster --image ${IMAGE} --generate=false --name=contact --namespace=default
