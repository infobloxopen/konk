IMAGE_TAG  ?= $(shell git describe --tags --always)
IMAGE_REPO ?= infobloxopen/konk-apiserver-test
IMAGE      := $(IMAGE_REPO):$(IMAGE_TAG)

image: APISERVER_FLAGS ?= --generate=false
image:
	apiserver-boot build container --image ${IMAGE} ${APISERVER_FLAGS}

config/apiserver.yaml: image
	apiserver-boot build config --name contact --namespace default --image ${IMAGE}

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
