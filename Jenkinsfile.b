pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    environment {
        // Maven 配置
        MAVEN_OPTS     = '-Dmaven.repo.local=.m2/repository -Xms512m -Xmx1024m'
        MAVEN_SETTINGS = '-s settings.xml'

        // 应用元信息
        APP_NAME    = 'demo-app'
        APP_VERSION = sh(script: "mvn help:evaluate -Dexpression=project.version -q -DforceStdout ${MAVEN_SETTINGS}", returnStdout: true).trim()

        // 镜像仓库
        DOCKER_REGISTRY = 'registry.example.com'
        IMAGE_NAME      = "${DOCKER_REGISTRY}/${APP_NAME}"
        IMAGE_TAG       = "${APP_VERSION}-${BUILD_NUMBER}"
    }

    parameters {
        choice(name: 'DEPLOY_ENV',
               choices: ['dev', 'staging', 'prod'],
               description: '选择部署环境')
        booleanParam(name: 'SKIP_TESTS', defaultValue: false, description: '是否跳过单元测试')
        booleanParam(name: 'FORCE_DEPLOY', defaultValue: false, description: '是否强制部署（跳过确认）')
    }

    triggers {
        // 每天凌晨 2 点构建一次
        cron('H 2 * * *')
        // Git 变更触发（按需启用）
        // pollSCM('H/5 * * * *')
    }

    stages {

        stage('Checkout') {
            steps {
                echo "分支: ${env.GIT_BRANCH}"
                echo "提交: ${env.GIT_COMMIT}"
                checkout scm
            }
        }

        stage('Build') {
            steps {
                sh """
                    mvn clean compile \
                        ${MAVEN_SETTINGS} \
                        -DskipTests
                """
            }
        }

        stage('Test') {
            when {
                not { expression { return params.SKIP_TESTS } }
            }
            steps {
                sh """
                    mvn test \
                        ${MAVEN_SETTINGS} \
                        -Dmaven.test.failure.ignore=false
                """
            }
            post {
                always {
                    // 发布 JUnit 测试报告
                    junit allowEmptyResults: true,
                          testResults: '**/target/surefire-reports/*.xml'
                }
            }
        }

        stage('Package') {
            steps {
                sh """
                    mvn package \
                        ${MAVEN_SETTINGS} \
                        -DskipTests
                """
            }
            post {
                success {
                    // 归档构建产物
                    archiveArtifacts artifacts: 'target/*.jar,target/*.war',
                                     fingerprint: true,
                                     onlyIfSuccessful: true

                    // 归档源码与依赖（用于后续部署）
                    stash name: 'app-artifacts',
                          includes: 'target/**,pom.xml'
                }
            }
        }

        stage('Code Quality') {
            when {
                branch 'main'
            }
            steps {
                // 按需启用 SonarQube 静态分析
                // withSonarQubeEnv('sonar-server') {
                //     sh "mvn sonar:sonar ${MAVEN_SETTINGS}"
                // }
                echo '跳过代码质量分析（按需取消注释启用 SonarQube）'
            }
        }

        stage('Deploy') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                    expression { return params.FORCE_DEPLOY }
                }
            }
            steps {
                script {
                    echo "准备部署到环境: ${params.DEPLOY_ENV}"

                    // 示例 1: 拷贝制品到远程服务器
                    // sshPublisher(publishers: [
                    //     sshPublisherDesc(configName: "${params.DEPLOY_ENV}-server",
                    //                      transfers: [
                    //                          sshTransfer(cleanRemote: false,
                    //                                      excludes: '',
                    //                                      execCommand: """
                    //                                          systemctl stop ${APP_NAME} || true
                    //                                          mv /opt/${APP_NAME}/app.jar /opt/${APP_NAME}/app.jar.bak
                    //                                          systemctl start ${APP_NAME}
                    //                                      """,
                    //                                      remoteDirectory: "/opt/${APP_NAME}",
                    //                                      remoteDirectorySDF: false,
                    //                                      removePrefix: 'target',
                    //                                      sourceFiles: 'target/*.jar')
                    //                      ],
                    //                      usePromotionTimestamp: false,
                    //                      useWorkspaceInPromotion: false,
                    //                      verbose: true)
                    // ])

                    // 示例 2: 构建并推送 Docker 镜像
                    // unstash 'app-artifacts'
                    // sh """
                    //     docker build -t ${IMAGE_NAME}:${IMAGE_TAG} \
                    //                  -t ${IMAGE_NAME}:latest .
                    //     docker push ${IMAGE_NAME}:${IMAGE_TAG}
                    //     docker push ${IMAGE_NAME}:latest
                    // """

                    // 示例 3: 通过 Kubernetes 部署
                    // sh """
                    //     sed -e 's|__IMAGE__|${IMAGE_NAME}:${IMAGE_TAG}|g' \
                    //         -e 's|__ENV__|${params.DEPLOY_ENV}|g' \
                    //         k8s/deployment.yaml | kubectl apply -f -
                    // """

                    echo "[占位] 在此执行真实部署逻辑：${params.DEPLOY_ENV}"
                }
            }
        }
    }

    post {
        success {
            echo "构建成功: ${env.JOB_NAME} #${env.BUILD_NUMBER}"
        }
        failure {
            echo "构建失败: ${env.JOB_NAME} #${env.BUILD_NUMBER}"
        }
        unstable {
            echo "构建不稳定: ${env.JOB_NAME} #${env.BUILD_NUMBER}"
        }
        always {
            // 清理工作区
            cleanWs()
        }
    }
}
