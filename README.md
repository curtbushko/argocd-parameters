# Argo CD ApplicationSet parameters: live integration test

A local kind cluster runs Argo CD and a Helm-based hello-world application. The
application serves a greeting rendered by Helm, not a hard-coded response.
No external Git repository or chart publication is needed: a Docker container
on kind's network serves the packaged local chart to Argo CD.

## Prerequisites

- Nix with `nix-command` and `flakes` enabled.
- A running Docker daemon, accessible without sudo (see macOS setup below).
- Internet access for Nix packages, container images, and Argo CD manifests.
- Enough resources for a Kubernetes node and Argo CD (roughly 4 CPUs / 6 GiB RAM).

The flake installs kind, kubectl, Helm, Argo CD CLI, Docker client, make, and
validation tools. On macOS it also installs Colima to run Docker in a Linux VM.
On macOS, cluster/test startup automatically starts Colima if Docker is unavailable.
An already-running Docker daemon (including Docker Desktop) is used as-is.
The locked nixpkgs version also selects the matching Argo CD server version.

### macOS Docker setup

Inside `nix develop` (or after `direnv allow`), `make test` starts Colima when
needed, with 4 CPUs, 6 GiB RAM, and a 30 GiB disk. It selects Colima only for the
test process, without changing your saved Docker context.

To start Colima manually and select it for other Docker commands:

```bash
colima start --runtime docker --cpu 4 --memory 6 --disk 30
docker context use colima
docker info
make test
```

Alternatively, start Docker Desktop and use its Docker context instead.
If `DOCKER_HOST` or `DOCKER_CONTEXT` is set in your shell, it may override the
selected context; unset it if Docker connects to the wrong daemon.
Use `colima stop` when finished; `make clean` only removes the demo resources.
On Linux, install and start Docker through your host system configuration.

## Run

```bash
nix develop
make test
```

Or enable direnv in your host shell, with nix-direnv integration, then:

```bash
direnv allow
make test
```

For example, a Nix Home Manager setup can enable both:

```nix
programs.direnv.enable = true;
programs.direnv.nix-direnv.enable = true;
```

The `.envrc` uses `use flake`; direnv must already be hooked into your host shell.
Installing it inside the development shell does not configure that host hook.

## What the test proves

1. Creates the `argocd-parameters` cluster with a private `.state/kubeconfig`.
2. Packages `charts/hello-world` and starts the local HTTP Helm repository.
3. Installs Argo CD and waits for its controllers and API.
4. Adds `applicationset.yaml` with `argocd appset create`.
5. Asserts the default response from the actual running application.
6. Adds `message` and `audience` Helm parameters to the ApplicationSet template
   using `argocd appset create .state/applicationset.json --upsert`.
7. Waits for those parameters to reach the generated Application, deployment,
   and HTTP response.
8. Changes the parameters again and checks the updated response.

Expected successful assertions:

```text
PASS: running application returned: Hello world | audience=default
PASS: running application returned: Hello from Argo CD parameters | audience=kind
PASS: running application returned: Hello after a parameter update | audience=integration-test
```

Argo CD has no `appset set --parameter` command. The supported CLI operation is
an ApplicationSet upsert with `spec.template.spec.source.helm.parameters`.
Using `argocd app set hello-world -p ...` instead would change only the generated
Application, which the ApplicationSet controller may overwrite.

The chart renders these values into a ConfigMap. A checksum annotation changes
the pod template when either parameter changes, so verification includes a
real rollout. `curl` verifies the served content, not just the Kubernetes spec.

## Argo CD UI

Run `make ui` to display the admin credentials and forward the UI to
**https://localhost:18080**. Accept the self-signed certificate warning.
Keep the command running; press Ctrl+C to stop forwarding.
Use `make ui ARGOCD_PORT=28080` to choose another port.

## Inspect the running application

The cluster stays running after the test; temporary port forwards stop.
In the development shell:

```bash
export KUBECONFIG="$PWD/.state/kubeconfig"
kubectl -n argocd get applicationset hello-world -o yaml
kubectl -n argocd get application hello-world -o yaml
kubectl -n hello-world get configmap hello-world -o yaml
kubectl -n hello-world port-forward svc/hello-world 18081:80
```

From another terminal:

```bash
curl http://127.0.0.1:18081/
```

Saved evidence:

- `.state/applicationset-result.yaml`: final ApplicationSet from the Argo CD API.
- `.state/rendered-manifests.yaml`: final Helm-rendered manifests from Argo CD.
- `.state/*port-forward.log`: port-forward diagnostics.

Use `ARGOCD_PORT=28080 HELLO_PORT=28081 make test` if default ports are occupied.
Re-running `make test` resets the baseline and repeats both parameter changes.

## Other targets

```bash
make ui        # Show admin credentials and forward the UI to localhost
make lint      # ShellCheck, shfmt, Helm lint and template
make cluster   # Only create/export the kind cluster
make repo      # Create cluster and serve the local chart
make install   # Create cluster and install Argo CD
make clean     # Delete the demo cluster and owned chart container
```

This is a disposable local test, not a production configuration: it uses the
initial admin credential, accepts Argo CD's self-signed certificate, and serves
the chart over HTTP on Docker's kind network. Port forwards bind only localhost.
Credentials stay under the ignored, restricted `.state/` directory; do not
publish that directory. `make clean` preserves local evidence and credentials.
