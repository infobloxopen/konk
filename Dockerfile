# Build the manager binary
FROM quay.io/operator-framework/helm-operator:v1.34.1

ENV HOME=/opt/helm
COPY --chmod=555 watches.yaml ${HOME}/watches.yaml
COPY --chmod=555 helm-charts ${HOME}/helm-charts
WORKDIR ${HOME}
