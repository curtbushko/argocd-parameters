.PHONY: test bootstrap cluster install ui lint clean help

ARGOCD_PORT ?= 18080

help:
	@printf '%s\n' \
		'make test      Create cluster and test bootstrap with three dev children' \
		'make bootstrap Refresh local Git pod and test bootstrap on an existing cluster' \
		'make ui        Show admin credentials and forward the Argo CD UI to localhost' \
		'make lint      Validate shell scripts and Jsonnet/OCI chart rendering' \
		'make clean     Delete only the demo cluster'

test: install
	bash examples/bootstrap/test.sh
	bash scripts/bootstrap.sh

bootstrap:
	bash scripts/bootstrap.sh

cluster:
	bash scripts/cluster.sh cluster

install: cluster
	bash scripts/cluster.sh install

ui:
	@test -f .state/kubeconfig || { printf 'Run make test first.\n' >&2; exit 1; }
	@printf 'Open https://localhost:$(ARGOCD_PORT) (accept the self-signed certificate).\nUsername: admin\nPassword: '
	@KUBECONFIG="$(CURDIR)/.state/kubeconfig" kubectl -n argocd get secret argocd-initial-admin-secret -o go-template='{{.data.password | base64decode}}{{"\n"}}'
	@printf 'Press Ctrl+C to stop forwarding.\n'
	KUBECONFIG="$(CURDIR)/.state/kubeconfig" kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server $(ARGOCD_PORT):443

lint:
	shellcheck scripts/cluster.sh scripts/bootstrap.sh scripts/render-bootstrap.sh examples/bootstrap/test.sh
	shfmt -d scripts/cluster.sh scripts/bootstrap.sh scripts/render-bootstrap.sh examples/bootstrap/test.sh
	bash examples/bootstrap/test.sh

clean:
	bash scripts/cluster.sh clean
