CHART_DIR	:= charts
HELM		?= helm # point to helm 3
K8S_RELEASE	?= v1.19.0
KUBEADM		?= docker run --rm -it --entrypoint="" kindest/node:$(K8S_RELEASE) kubeadm
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

teardown-%:
	$(HELM) delete $(RELEASE_NAME)-$*
