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
        }
      }
      steps {
        dir("helm-charts") {
          withAWS(credentials: "CICD_HELM", region: "us-east-1") {
            sh '''\
              for chart in konk*
              do

              chart_file=$chart-$GIT_VERSION.tgz

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
