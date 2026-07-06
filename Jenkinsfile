@Library('jenkins.shared.library') _

pipeline {
  agent {
    label 'ubuntu_docker_label'
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
    stage("Push Test API Server Image") {
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
    stage("Promote Images To Harbor") {
      when {
        anyOf {
          branch 'main'
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

                # Wait for the GHA push-images.yml workflow to complete for this commit.
                # Jenkins and GHA both trigger on the same push; GHA builds the images
                # (~20-30 min), so we must wait before attempting crane copy + verify.
                COMMIT_SHA=\$(git rev-parse HEAD)
                echo "Waiting for push-images GHA workflow to complete for \${COMMIT_SHA}..."
                TIMEOUT=3600
                START=\$(date +%s)
                while true; do
                  RUN_DATA=\$(GH_TOKEN="\${GITHUB_PAT}" /tmp/gh api \
                    "/repos/infobloxopen/konk/actions/workflows/push-images.yml/runs?head_sha=\${COMMIT_SHA}&per_page=5" \
                    --jq '.workflow_runs[0] | {status: .status, conclusion: .conclusion}' 2>/dev/null || echo '{}')
                  STATUS=\$(echo "\${RUN_DATA}" | jq -r '.status // "absent"')
                  CONCLUSION=\$(echo "\${RUN_DATA}" | jq -r '.conclusion // "pending"')
                  echo "push-images workflow: status=\${STATUS} conclusion=\${CONCLUSION}"
                  if [ "\${STATUS}" = "completed" ]; then
                    if [ "\${CONCLUSION}" = "success" ]; then
                      echo "GHA push-images workflow succeeded"
                      break
                    else
                      echo "GHA push-images workflow did not succeed: conclusion=\${CONCLUSION}"
                      exit 1
                    fi
                  fi
                  NOW=\$(date +%s)
                  if (( NOW - START > TIMEOUT )); then
                    echo "Timeout waiting for GHA push-images workflow (1h)"
                    exit 1
                  fi
                  sleep 30
                done

                echo "\${GITHUB_PAT}" | /tmp/crane auth login ghcr.io -u ibciteam --password-stdin
                echo "\${HARBOR_PASSWORD}" | /tmp/crane auth login harbor.services.sdp.infoblox.com -u "\${HARBOR_USERNAME}" --password-stdin

                TAG='${env.GIT_VERSION}'
                for name in konk konk-app konk-provision konk-service; do
                  src="ghcr.io/infobloxopen/\$name:\$TAG"
                  dst="harbor.services.sdp.infoblox.com/infobloxcto/\$name:\$TAG"

                  digest=\$(/tmp/crane digest "\${src}")
                  echo "Verifying SLSA provenance for \${src}@\${digest}"
                  GH_TOKEN="\${GITHUB_PAT}" /tmp/gh attestation verify \
                    "oci://ghcr.io/infobloxopen/\$name@\${digest}" \
                    --repo 'infobloxopen/konk' \
                    --predicate-type https://slsa.dev/provenance/v1 \
                    --bundle-from-oci \
                    --cert-identity-regex '^https://github\\.com/infobloxopen/konk/\\.github/workflows/push-images\\.yml@refs/heads/(main|release/.+)\$'

                  echo "Promoting \${src} -> \${dst}"
                  /tmp/crane copy "\${src}" "\${dst}"

                  /tmp/cosign sign \
                    --key 'hashivault://harbor-cosign' \
                    --yes \
                    "harbor.services.sdp.infoblox.com/infobloxcto/\$name@\${digest}"
                done
              """
            }
        }
      }
    }
  }
  post {
    success {
      finalizeBuild('', getFileList("*.properties"))
    }
  }
}
