#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in docker kind kubectl helm argocd curl jq yq; do
	command -v "$tool" >/dev/null || {
		printf 'Missing tool: %s (run nix develop)\n' "$tool" >&2
		exit 1
	}
done
readonly CLUSTER=argocd-parameters
readonly REPO=argocd-parameters-charts
mkdir -p .state
chmod 700 .state
export KUBECONFIG="$PWD/.state/kubeconfig"
export ARGOCD_CONFIG_DIR="$PWD/.state/argocd"
# Do not inherit a user's server, token, or CLI options.
unset ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_OPTS
argo_pid=''
web_pid=''
cleanup() {
	if [[ -n "$web_pid" ]]; then
		kill "$web_pid" 2>/dev/null || true
		wait "$web_pid" 2>/dev/null || true
	fi
	if [[ -n "$argo_pid" ]]; then
		kill "$argo_pid" 2>/dev/null || true
		wait "$argo_pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT
argo() {
	argocd --config "$PWD/.state/argocd-config" --server "127.0.0.1:${ARGOCD_PORT:-18080}" --insecure "$@"
}
cluster() {
	docker info >/dev/null
	if ! kind get clusters | grep -qx "$CLUSTER"; then
		kind create cluster --name "$CLUSTER" --config kind.yaml --image kindest/node:v1.33.1 --wait 180s
	fi
	kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
	chmod 600 "$KUBECONFIG"
}
repo() {
	# Mount only public chart artifacts, never the kubeconfig or CLI credentials.
	mkdir -p .state/charts
	helm package charts/hello-world --destination .state/charts
	helm repo index .state/charts --url "http://$REPO"
	if ! docker container inspect "$REPO" >/dev/null 2>&1; then
		docker run -d --name "$REPO" --network kind \
			--label argocd-parameters.demo=true \
			-v "$PWD/.state/charts:/usr/share/nginx/html:ro" nginx:1.28.0-alpine
	else
		[[ "$(docker inspect -f '{{index .Config.Labels "argocd-parameters.demo"}}' "$REPO")" == true ]] || {
			printf 'Chart container name is already in use\n' >&2
			exit 1
		}
		docker start "$REPO" >/dev/null
	fi
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
login() {
	kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server "${ARGOCD_PORT:-18080}:443" >.state/argocd-port-forward.log 2>&1 &
	argo_pid=$!
	local ready=false
	for ((i = 0; i < 60; i++)); do
		if curl -kfsS "https://127.0.0.1:${ARGOCD_PORT:-18080}/healthz" >/dev/null 2>&1; then
			ready=true
			break
		fi
		kill -0 "$argo_pid" || {
			printf 'Port-forward failed; see .state/argocd-port-forward.log\n' >&2
			exit 1
		}
		sleep 1
	done
	[[ "$ready" == true ]] || {
		printf 'Argo CD API timed out\n' >&2
		exit 1
	}
	local password
	password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode)
	argo login "127.0.0.1:${ARGOCD_PORT:-18080}" --username admin --password "$password" --insecure
	chmod 600 .state/argocd-config
}
apply_set() {
	local message="$1" audience="$2"
	yq -o=json applicationset.yaml | jq --arg message "$message" --arg audience "$audience" \
		'.spec.template.spec.source.helm.parameters = [{name:"message",value:$message,forceString:true},{name:"audience",value:$audience,forceString:true}]' >.state/applicationset.json
	# This changes the ApplicationSet itself via the Argo CD API, not its child.
	argo appset create .state/applicationset.json --upsert
	local matched=false
	for ((i = 0; i < 120; i++)); do
		if kubectl -n argocd get application hello-world -o json 2>/dev/null | jq -e --arg message "$message" \
			'any(.spec.source.helm.parameters[]?; .name == "message" and .value == $message)' >/dev/null; then
			matched=true
			break
		fi
		sleep 2
	done
	[[ "$matched" == true ]] || {
		printf 'ApplicationSet did not propagate parameters\n' >&2
		exit 1
	}
	argo app get hello-world --hard-refresh >/dev/null
	argo app wait hello-world --sync --health --timeout 300
	kubectl -n hello-world rollout status deployment/hello-world --timeout=180s
}
verify() {
	local expected="$1 | audience=$2" actual='' matched=false
	kubectl -n hello-world port-forward --address 127.0.0.1 svc/hello-world "${HELLO_PORT:-18081}:80" >.state/hello-port-forward.log 2>&1 &
	web_pid=$!
	for ((i = 0; i < 60; i++)); do
		actual=$(curl -fsS "http://127.0.0.1:${HELLO_PORT:-18081}/" 2>/dev/null || true)
		if [[ "$actual" == "$expected" ]]; then
			matched=true
			break
		fi
		kill -0 "$web_pid" || {
			printf 'Port-forward failed; see .state/hello-port-forward.log\n' >&2
			exit 1
		}
		sleep 2
	done
	kill "$web_pid"
	wait "$web_pid" 2>/dev/null || true
	web_pid=''
	[[ "$matched" == true ]] || {
		printf 'FAIL: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
		exit 1
	}
	printf 'PASS: running application returned: %s\n' "$actual"
}
case "${1:-test}" in
cluster) cluster ;;
install) install ;;
repo) repo ;;
test)
	cluster
	repo
	install
	login
	argo appset create applicationset.yaml --upsert
	baseline_ready=false
	for ((i = 0; i < 120; i++)); do
		if kubectl -n argocd get application hello-world -o json 2>/dev/null | jq -e '(.spec.source.helm.parameters // [] | length) == 0' >/dev/null; then
			baseline_ready=true
			break
		fi
		sleep 2
	done
	[[ "$baseline_ready" == true ]] || {
		printf 'Baseline Application was not generated\n' >&2
		exit 1
	}
	argo app get hello-world --hard-refresh >/dev/null
	argo app wait hello-world --sync --health --timeout 300
	kubectl -n hello-world rollout status deployment/hello-world --timeout=180s
	verify 'Hello world' default
	apply_set 'Hello from Argo CD parameters' kind
	verify 'Hello from Argo CD parameters' kind
	apply_set 'Hello after a parameter update' integration-test
	verify 'Hello after a parameter update' integration-test
	argo appset get hello-world -o yaml >.state/applicationset-result.yaml
	argo app manifests hello-world >.state/rendered-manifests.yaml
	printf 'Evidence saved in .state/; cluster left running. Use make clean to delete it.\n'
	;;
clean)
	if docker container inspect "$REPO" >/dev/null 2>&1; then
		[[ "$(docker inspect -f '{{index .Config.Labels "argocd-parameters.demo"}}' "$REPO")" == true ]] || exit 1
		docker container rm -f "$REPO"
	fi
	kind delete cluster --name "$CLUSTER"
	;;
*)
	printf 'Usage: %s {test|cluster|install|repo|clean}\n' "$0" >&2
	exit 2
	;;
esac
