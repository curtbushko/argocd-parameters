// Shared deployment behavior. Environment files own only release identity/version pins.
function(registry, registryNamespace, environment, environmentValues, release)
  local APP_NAME = environment + '-' + release.name;
  {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'ApplicationSet',
    metadata: {
      name: APP_NAME,
      namespace: 'argocd',
      labels: {
        'app.kubernetes.io/part-of': 'bootstrap-demo',
        environment: environment,
      },
    },
    spec: {
      goTemplate: true,
      goTemplateOptions: ['missingkey=error'],
      generators: [{
        clusters: {
          selector: {
            matchLabels: { 'bootstrap-demo': 'true', environment: environment },
          },
        },
      }],
      template: {
        metadata: {
          name: APP_NAME,
          labels: {
            'app.kubernetes.io/part-of': 'bootstrap-demo',
            environment: environment,
          },
          annotations: { 'demo.example/cluster': '{{.name}}' },
        },
        spec: {
          project: 'default',
          revisionHistoryLimit: 5,
          source: {
            // Argo CD's Helm OCI repoURL omits the oci:// prefix.
            repoURL: registry + '/' + registryNamespace,
            chart: release.chart,
            targetRevision: release.version,
            helm: {
              releaseName: APP_NAME,
              // Choose a file inside the packaged chart, independently of deployment identity.
              // Helm automatically loads values.yaml before this override file.
              valueFiles: [environmentValues],
            },
          },
          destination: {
            server: '{{.server}}',
            namespace: APP_NAME,
          },
          syncPolicy: {
            automated: { prune: true, selfHeal: true },
            syncOptions: ['CreateNamespace=true'],
            retry: {
              limit: 5,
              backoff: { duration: '5s', factor: 2, maxDuration: '3m' },
            },
          },
        },
      },
    },
  }
