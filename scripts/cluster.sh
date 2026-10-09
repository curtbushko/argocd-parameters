#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in docker kind kubectl curl; do
	command -v "$tool" >/dev/null || {
		printf 'Missing tool: %s (run nix develop)\n' "$tool" >&2
		exit 1
	}
done
readonly CLUSTER=argocd-parameters
mkdir -p .state
chmod 700 .state
export KUBECONFIG="$PWD/.state/kubeconfig"
cluster() {
	if ! docker info >/dev/null 2>&1 && [[ "$(uname -s)" == Darwin ]]; then
		if command -v colima >/dev/null; then
			printf 'Starting Colima for Docker...\n'
			colima start --runtime docker --cpu 4 --memory 6 --disk 30
			# Select Colima for this process without changing the user's Docker context.
			unset DOCKER_HOST
			export DOCKER_CONTEXT=colima
		fi
	fi
	if ! docker info >/dev/null; then
		printf '%s\n' 'Docker daemon is unavailable. On macOS, start Colima or Docker Desktop.' \
			'On Linux, start your host Docker service. Check DOCKER_HOST/DOCKER_CONTEXT if needed.' >&2
		exit 1
	fi
	if ! kind get clusters | grep -qx "$CLUSTER"; then
		kind create cluster --name "$CLUSTER" --config kind.yaml --image kindest/node:v1.33.1 --wait 180s
	fi
	kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
	chmod 600 "$KUBECONFIG"
}
install() {
	local version="${ARGOCD_VERSION:-v3.1.8}"
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	curl --fail --location --retry 3 "https://raw.githubusercontent.com/argoproj/argo-cd/$version/manifests/install.yaml" -o .state/argocd-install.yaml
	kubectl apply --server-side -n argocd -f .state/argocd-install.yaml
	kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
	kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
	kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
	kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
}
case "${1:-cluster}" in
cluster) cluster ;;
install) install ;;
clean) kind delete cluster --name "$CLUSTER" ;;
*)
	printf 'Usage: %s {cluster|install|clean}\n' "$0" >&2
	exit 2
	;;
esac
