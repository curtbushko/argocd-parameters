# Shared ApplicationSet template, independent environment releases

```text
examples/application-sets/
├── application-set.libsonnet    # Common deployment behavior
├── dev.jsonnet                 # Deployed and tested
├── staging.jsonnet             # Example only
├── prod.jsonnet                # Example only
└── demo.jsonnet                # Demo identity, dev values profile; example only
```

Each environment file returns an array of ApplicationSets using the same shared
template. There are no per-child template directories or deployment overrides.

## Run dev

```bash
nix develop
make test
make ui
```

The live hierarchy is:

```text
bootstrap (ApplicationSet → parent Application, sourced from Git)
├── dev-child-one (ApplicationSet → Application → OCI podinfo chart)
├── dev-child-two (ApplicationSet → Application → OCI podinfo chart)
└── dev-child-three (ApplicationSet → Application → OCI podinfo chart)
```

All workloads run in the local cluster, each in its matching namespace.
The parent manages only ApplicationSets. Each child pulls the public **podinfo
6.9.2** chart from GHCR; no publishing or registry credentials are needed.

Bootstrap points at `examples/application-sets` with **`directory.include:
dev.jsonnet`**. It does not render staging or prod. `.libsonnet` is imported by
dev, not rendered as another resource. No recursive discovery is needed.

Run `make bootstrap` after local edits to refresh the Git pod's source snapshot.

## Release lists and promotion

`dev.jsonnet` defines releases declaratively:

```jsonnet
local applicationSet = import 'application-set.libsonnet';
local ENVIRONMENT = 'dev';
local ENVIRONMENT_VALUES = 'values.yaml'; // Public podinfo has no dev.yaml.
local RELEASES = [
  { name: 'child-one', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-two', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-three', chart: 'podinfo', version: '6.9.2' },
];
function(registry, registryNamespace)
  [applicationSet(registry, registryNamespace, ENVIRONMENT, ENVIRONMENT_VALUES, release) for release in RELEASES]
```

Staging and prod independently pin illustrative older versions. These reference
files and their chart versions are **not tested or deployed** by the demo.
Promote a release by changing its version pin in the next environment's file.
No shared-template change or bootstrap TLA change is needed.

Chart name and version are explicit Git configuration, not runtime arguments.
**`registry` and `registryNamespace` are the TLAs.** The bootstrap injects both into the
selected file, which passes them to each shared-template invocation. For example,
`registry=ghcr.io` and `registryNamespace=stefanprodan/charts` form the Helm repository
`ghcr.io/stefanprodan/charts`. This is an OCI repository namespace, not the
Kubernetes destination namespace.

## Deployment settings belong in charts

The generic helper takes independent identity and file-selection arguments:

```jsonnet
applicationSet(registry, registryNamespace, environment, environmentValues, release)
```

`environment` controls names, namespaces, and cluster selection.
`environmentValues` is the exact filename inside the packaged chart:

```jsonnet
helm: {
  releaseName: APP_NAME,
  valueFiles: [environmentValues],
},
```

No environment fields are injected into Helm values. Helm automatically loads
`values.yaml`, then merges the selected file. Deployment differences—image,
replicas, CPU/memory, and application settings—remain in the chart package.

`demo.jsonnet` uses `ENVIRONMENT='demo'` and `ENVIRONMENT_VALUES='dev.yaml'`:
resource names and clusters are demo, while configuration comes from dev.yaml.
It remains an undeployed reference example.

The live dev example selects `values.yaml` because the existing public podinfo
chart has no dev.yaml. This uses the chart defaults without extra overrides.
The other reference environments select dev.yaml, staging.yaml, or prod.yaml;
they require your own chart containing those files before they can be deployed.
Missing values files fail rendering; they are not silently ignored.

There is no additional registry or chart repackaging. Version pins and file
selection remain explicit in environment files, independent of the shared
ApplicationSet's deployment behavior.

## Environment targeting and names

Names and namespaces include the environment, such as `dev-child-one`.
The cluster generator requires **both** `bootstrap-demo=true` and the matching
`environment` label. `local-cluster.yaml` registers the local cluster as dev.
Staging/prod registrations would need their respective environment labels.
These singleton names assume one selected cluster per environment.

To deploy another environment later, give it its own bootstrap or deliberately
change `directory.include` and provision its cluster registration. The current
bootstrap and all test commands remain dev-only.

## Registry and manual bootstrap

```bash
make bootstrap HELM_REGISTRY=ghcr.io HELM_REGISTRY_NAMESPACE=stefanprodan/charts
```

Argo CD's classic Helm OCI source omits a URI scheme:

```yaml
source:
  repoURL: ghcr.io/stefanprodan/charts
  chart: podinfo
  targetRevision: "6.9.2"
```

The demo registers a public Helm repository Secret with `enableOCI=true`.
Private registry credentials must be managed separately. Changing registry
alone doesn't change the pinned chart versions in environment files.

The bootstrap is plain YAML at `examples/bootstrap/bootstrap.yaml`. For manual
creation, fill its two Git `repoURL` fields and its `registry` and `registryNamespace` TLAs; keep
`include: dev.jsonnet` to deploy only dev. The checked-in runtime fields are
blank, so the YAML must be filled in before applying.

```bash
read -r -p 'Git hostname: ' GIT_HOST
read -r -p 'Repository path: ' REPO_PATH
GIT_HOST="$GIT_HOST" REPO_PATH="$REPO_PATH" \
  HELM_REGISTRY=ghcr.io HELM_REGISTRY_NAMESPACE=stefanprodan/charts \
  bash scripts/render-bootstrap.sh | kubectl apply -f -
```

The Git URL defaults to HTTPS; the local Git pod uses `git://`. Your AppProject
must permit both Git and OCI sources and destinations. Only trusted users should
control ApplicationSets in `argocd`. TLA inputs are not secret storage; URLs are
visible in live resources. Update the parent, not a generated Application, for
durable input changes.

## Local Git server and tests

The Git pod serves ApplicationSet files, not charts. A ConfigMap mounts a source
snapshot; an init container commits it into a disposable repository. Git daemon
serves read-only traffic through port 9418. Startup requires Alpine mirror access.
Private `.state` files are never copied. This server is only for the local demo.

Rendering tests load only dev, verify its array of three ApplicationSets, pull
podinfo 6.9.2 once, and check packaged image/replica/resource defaults. Live tests
check the Git parent's revision, dev child chart versions, and their HTTP services.
Staging, prod, and demo remain reference files; the tests do not render or deploy them.
