@Library('jenkins.shared.library') _

pipeline {
  agent {
    label 'ubuntu_docker_label'
  }
  parameters {
    booleanParam(
      name: 'HARBOR_PROMOTION_DRY_RUN',
      defaultValue: true,
      description: 'If true, only print planned GHCR->Harbor promotions; no copy/sign is performed.'
    )
  }
  environment {
    HELM_IMAGE = "infoblox/helm:3.2.4-5b243a2"
    HELM="""docker run --rm \
      -e AWS_REGION \
      -e AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY \
      -v ${env.WORKSPACE}:/pkg \
      -w /pkg \
      ${env.HELM_IMAGE}"""
    GIT_VERSION = sh(script: "git describe --always --long --tags", returnStdout: true).trim()
    CHART_VERSION = "${env.GIT_VERSION}-j${env.BUILD_NUMBER}"
  }
  stages {
    stage("Prepare Build") {
      steps {
        prepareBuild()
      }
    }
    stage("Push Images") {
      when {
        anyOf {
          branch 'main'
          branch 'ci'
          branch 'release/*'
        }
      }
      steps {
        withDockerRegistry([credentialsId: "dockerhub-bloxcicd", url: ""]) {
          sh '''
            make -C test/apiserver push
          '''
        }
      }
    }
    stage("Promote Images To Harbor") {
      when {
        anyOf {
          branch 'main'
          branch 'ci'
          branch 'release/*'
        }
      }
      steps {
        sh '''#!/bin/bash
          set -euo pipefail

          CRANE_VERSION=v0.20.3
          curl -sL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
            | tar xz -C /tmp crane
          chmod +x /tmp/crane

          COSIGN_VERSION=v2.4.3
          curl -sL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" -o /tmp/cosign
          chmod +x /tmp/cosign

          GH_VERSION=2.67.0
          curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
            | tar xz -C /tmp --strip-components=2 "gh_${GH_VERSION}_linux_amd64/bin/gh"
          chmod +x /tmp/gh
        '''

        script {
          def ghcrPrefix = 'ghcr.io/infobloxopen'
          def harborPrefix = 'harbor.services.sdp.infoblox.com/infobloxcto'
          def images = ['konk', 'konk-app', 'konk-provision', 'konk-service']

          if (params.HARBOR_PROMOTION_DRY_RUN) {
            // Dry-run is non-blocking for first rollout.
            catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
              sh """#!/bin/bash
                set -euo pipefail
                TAG='${env.GIT_VERSION}'
                echo 'Harbor promotion dry-run enabled; no copy/sign will be performed.'
                for name in ${images.join(' ')}; do
                  src='${ghcrPrefix}/'"\${name}"':"\${TAG}"'
                  dst='${harborPrefix}/'"\${name}"':"\${TAG}"'
                  digest=$(/tmp/crane digest "\${src}" 2>/dev/null || true)
                  if [[ -n "\${digest}" ]]; then
                    echo "DRY-RUN: would promote \${src} -> \${dst} (digest=\${digest})"
                  else
                    echo "DRY-RUN: would promote \${src} -> \${dst} (digest lookup failed)"
                  fi
                done
              """
            }
          } else {
            withCredentials([
              string(credentialsId: 'GITHUB_TOKEN', variable: 'GITHUB_PAT'),
              usernamePassword(credentialsId: 'harbor-services-prod',
                               usernameVariable: 'HARBOR_USERNAME',
                               passwordVariable: 'HARBOR_PASSWORD'),
              [$class: 'VaultTokenCredentialBinding',
               credentialsId: 'vault-services-prod-cosign',
               vaultAddr: 'https://vault.services.sdp.infoblox.com:8200'],
            ]) {
              sh """#!/bin/bash
                set -euo pipefail

                echo "\${GITHUB_PAT}" | /tmp/crane auth login ghcr.io -u ibciteam --password-stdin
                echo "\${HARBOR_PASSWORD}" | /tmp/crane auth login harbor.services.sdp.infoblox.com -u "\${HARBOR_USERNAME}" --password-stdin

                TAG='${env.GIT_VERSION}'
                for name in ${images.join(' ')}; do
                  src='${ghcrPrefix}/'"\${name}"':"\${TAG}"'
                  dst='${harborPrefix}/'"\${name}"':"\${TAG}"'

                  digest=$(/tmp/crane digest "\${src}")
                  echo "Verifying SLSA provenance for \${src}@\${digest}"
                  GH_TOKEN="\${GITHUB_PAT}" /tmp/gh attestation verify \
                    "oci://${ghcrPrefix}/\${name}@\${digest}" \
                    --repo 'infobloxopen/konk' \
                    --predicate-type https://slsa.dev/provenance/v1 \
                    --bundle-from-oci \
                    --cert-identity-regex '^https://github\\.com/infobloxopen/konk/\\.github/workflows/push-images\\.yml@refs/heads/(main|release/.+)\$'

                  echo "Promoting \${src} -> \${dst}"
                  /tmp/crane copy "\${src}" "\${dst}"

                  /tmp/cosign sign \
                    --key 'hashivault://harbor-cosign' \
                    --yes \
                    '${harborPrefix}/'"\${name}"'@'"\${digest}"
                done
              """
            }
          }
        }
      }
    }
    stage("Package Charts") {
      steps {
        withAWS(credentials: "CICD_HELM", region: "us-east-1") {
          sh 'make CHART_PKG_VERSION=$CHART_VERSION package'
        }
      }
    }
    stage("Push Chart") {
      when {
        anyOf {
          branch 'main'
          branch 'ci'
          branch 'release/*'
        }
      }
      steps {
        dir("helm-charts") {
          withAWS(credentials: "CICD_HELM", region: "us-east-1") {
            sh '''\
              for chart in konk*
              do

              chart_file=$chart-$CHART_VERSION.tgz

              $HELM s3 push /pkg/$chart_file infobloxcto

              cat << EOF > $WORKSPACE/$chart.properties
              repo=infoblox-helm-dev
              chart=$chart_file
              messageFormat=s3-artifact
              customFormat=true
              EOF

              done
            '''.stripIndent()
          }
        }
        archiveArtifacts artifacts: '*.properties'
        archiveArtifacts artifacts: '*.tgz'
      }
    }
  }
  post {
    success {
      finalizeBuild('', getFileList("*.properties"))
    }
  }
}
