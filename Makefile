CHART_DIR	:= charts
HELM		?= docker run --rm -i \
			--entrypoint="" \
			--network host \
			-e KUBECONFIG=/apps/.kube/$(notdir $(KUBECONFIG)) \
			-v $(dir $(KUBECONFIG)):/apps/.kube/ \
			-v $(PWD):/apps \
			-u $(shell id -u):$(shell id -g) \
			infoblox/helm:3.2.4-5b243a2 \
			helm
K8S_RELEASE	?= v1.19.0
KUBEADM		?= docker run --rm -it --entrypoint="" kindest/node:$(K8S_RELEASE) kubeadm
KUBECONFIG	?= ${HOME}/.kube/config
RELEASE_NAME	?= $(USER)

.PHONY: charts/konk/image-tag-values.yaml
charts/konk/image-tag-values.yaml:
	@IMAGES=`$(KUBEADM) config images list` && \
	APISERVER_VERSION=`echo "$$IMAGES" | grep apiserver | cut -d: -f2` && \
	ETCD_VERSION=`echo "$$IMAGES" | grep etcd | cut -d: -f2` && \
	echo "# kubernetes $(K8S_RELEASE)\napiserver:\n  image:\n    tag: $$APISERVER_VERSION\netcd:\n  image:\n    tag: $$ETCD_VERSION" | tee $@

helm-lint: helm-lint-$(notdir $(CHART_DIR)/*)

helm-lint-%:
	$(HELM) lint $(CHART_DIR)/$*

deploy-%:
	$(HELM) upgrade -i $(RELEASE_NAME)-$* $(CHART_DIR)/$*

test-%:
	$(HELM) test --logs $(RELEASE_NAME)-$*

teardown-%:
	$(HELM) delete $(RELEASE_NAME)-$*
	# TODO: add support for k8s or helm to clean up these secrets
	kubectl delete secrets -l app.kubernetes.io/instance=$(RELEASE_NAME)-$*
