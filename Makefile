CHART_DIR	:= charts
HELM		?= helm # point to helm 3
RELEASE_NAME	?= $(USER)

deploy-%:
	$(HELM) upgrade -i $(RELEASE_NAME)-$* $(CHART_DIR)/$*

teardown-%:
	$(HELM) delete $(RELEASE_NAME)-$*
