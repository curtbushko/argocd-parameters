#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in kubectl yq tar jq; do
	command -v "$tool" >/dev/null || {
		printf 'Missing tool: %s (run nix develop)\n' "$tool" >&2
		exit 1
	}
done
export KUBECONFIG="$PWD/.state/kubeconfig"
readonly DEMO_GIT_HOST=bootstrap-git.argocd.svc.cluster.local:9418
helm_registry="${HELM_REGISTRY:-ghcr.io}"
registry_namespace="${HELM_REGISTRY_NAMESPACE:-stefanprodan/charts}"
helm_repository="$helm_registry/$registry_namespace"
mkdir -p .state
# Copy only public example files, never .git, kubeconfigs, or CLI credentials.
tar -czf .state/bootstrap-source.tgz examples/bootstrap examples/application-sets
kubectl -n argocd create configmap bootstrap-git-source \
	--from-file=source.tgz=.state/bootstrap-source.tgz --dry-run=client -o json |
	kubectl apply -f -
kubectl apply -f examples/bootstrap/git-server.yaml -f examples/bootstrap/local-cluster.yaml
# This demo uses a public registry. Private registry credentials are managed separately.
kubectl -n argocd create secret generic bootstrap-helm-repository \
	--from-literal=type=helm --from-literal=url="$helm_repository" --from-literal=enableOCI=true \
	--dry-run=client -o json |
	jq '.metadata.labels = {"argocd.argoproj.io/secret-type":"repository"}' |
	kubectl apply -f -
# Recreate the snapshot when local files change; it is not a writable Git remote.
kubectl -n argocd rollout restart deployment/bootstrap-git
kubectl -n argocd rollout status deployment/bootstrap-git --timeout=300s
snapshot_revision=$(kubectl -n argocd exec deployment/bootstrap-git -c git -- git --git-dir=/repos/demo.git rev-parse HEAD)
GIT_HOST="$DEMO_GIT_HOST" REPO_PATH=demo.git GIT_SCHEME=git \
	HELM_REGISTRY="$helm_registry" HELM_REGISTRY_NAMESPACE="$registry_namespace" \
	bash scripts/render-bootstrap.sh |
	kubectl apply -f -
kubectl -n argocd annotate applicationset bootstrap argocd.argoproj.io/application-set-refresh=true --overwrite
matched=false
refreshed=false
for ((i = 0; i < 120; i++)); do
	if [[ "$refreshed" == false ]] && kubectl -n argocd get application bootstrap >/dev/null 2>&1; then
		kubectl -n argocd annotate application bootstrap argocd.argoproj.io/refresh=hard --overwrite
		refreshed=true
	fi
	if kubectl -n argocd get application bootstrap -o json 2>/dev/null |
		jq -e --arg revision "$snapshot_revision" '.status.sync.status == "Synced" and .status.sync.revision == $revision' >/dev/null &&
		kubectl -n argocd get applicationset dev-child-one dev-child-two dev-child-three >/dev/null 2>&1; then
		matched=true
		break
	fi
	sleep 2
done
[[ "$matched" == true ]] || {
	printf 'Bootstrap did not create all three child ApplicationSets\n' >&2
	kubectl -n argocd get applicationset bootstrap -o yaml >&2 || true
	kubectl -n argocd get application bootstrap -o yaml >&2 || true
	exit 1
}
for child in dev-child-one dev-child-two dev-child-three; do
	matched=false
	refreshed=false
	for ((i = 0; i < 120; i++)); do
		if [[ "$refreshed" == false ]] && kubectl -n argocd get application "$child" >/dev/null 2>&1; then
			kubectl -n argocd annotate application "$child" argocd.argoproj.io/refresh=hard --overwrite
			refreshed=true
		fi
		if kubectl -n argocd get application "$child" -o json 2>/dev/null |
			jq -e --arg set "$child" --arg registry "$helm_repository" '
				any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and .name == $set) and
				.status.sync.status == "Synced" and .status.sync.revision == .spec.source.targetRevision and
				.status.health.status == "Healthy" and
				.spec.destination.server == "https://kubernetes.default.svc" and
				.spec.source.repoURL == $registry and .spec.source.chart == "podinfo" and
				.spec.source.helm.valueFiles == ["values.yaml"]
			' >/dev/null &&
			kubectl get --raw "/api/v1/namespaces/$child/services/$child-podinfo:9898/proxy/" |
			jq -e '.version == "6.9.2" and (.hostname | length > 0)' >/dev/null; then
			matched=true
			break
		fi
		sleep 2
	done
	[[ "$matched" == true ]] || {
		printf 'Child %s did not deploy its workload\n' "$child" >&2
		kubectl -n argocd get applications -o yaml >&2
		exit 1
	}
done
printf 'PASS: bootstrap -> dev-child-one, dev-child-two, dev-child-three -> OCI chart defaults; staging/prod not deployed\n'
