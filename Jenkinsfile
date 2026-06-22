@Library('jenkins.shared.library') _

pipeline {
  agent {
    label 'ubuntu_docker_label'
  }
  environment {
    HELM_IMAGE = "infoblox/helm:3.2.4-5b243a2"
    HELM="""docker run --rm \
      --entrypoint=helm \
      -e AWS_REGION \
      -e AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY \
      -v ${env.WORKSPACE}:/pkg \
      -w /pkg \
      ${env.HELM_IMAGE}"""
    GIT_DESCRIBE = sh(script: "git describe --always --long --tags", returnStdout: true).trim()
    GIT_VERSION = "${env.GIT_DESCRIBE}-j${env.BUILD_NUMBER}"
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
            sudo add-apt-repository ppa:longsleep/golang-backports
            sudo apt-get update
            sudo apt-get install -y golang-go
            make docker-build docker-push
            make -C test/apiserver push
          '''
        }
      }
    }
    stage("Package Charts") {
      steps {
        withAWS(credentials: "CICD_HELM", region: "us-east-1") {
          sh 'make package'
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
            sh '''
              docker run --rm \
                --entrypoint=/bin/sh \
                -e AWS_REGION \
                -e AWS_ACCESS_KEY_ID \
                -e AWS_SECRET_ACCESS_KEY \
                -v $WORKSPACE:/pkg \
                -w /pkg \
                $HELM_IMAGE -c "
                  helm s3 init s3://infoblox-helm-dev/charts 2>/dev/null || true
                  helm repo add infobloxcto s3://infoblox-helm-dev/charts
                  helm s3 push /pkg/konk-$GIT_VERSION.tgz infobloxcto
                  helm s3 push /pkg/konk-operator-$GIT_VERSION.tgz infobloxcto
                  helm s3 push /pkg/konk-service-$GIT_VERSION.tgz infobloxcto
                  helm s3 push /pkg/example-apiserver-$GIT_VERSION.tgz infobloxcto
                "

              for chart in konk konk-operator konk-service example-apiserver
              do
                chart_file=$chart-$GIT_VERSION.tgz
                printf 'repo=infoblox-helm-dev\nchart=%s\nmessageFormat=s3-artifact\ncustomFormat=true\n' "$chart_file" > $WORKSPACE/$chart.properties
              done
            '''
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
