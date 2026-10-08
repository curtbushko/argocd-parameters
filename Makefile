.PHONY: test cluster install repo ui lint clean help

ARGOCD_PORT ?= 18080

help:
	@printf 'make test    Create cluster, install Argo CD, and assert live parameter rendering\nmake ui      Show admin credentials and forward the Argo CD UI to localhost\nmake lint    Validate scripts and chart\nmake clean   Delete only the demo cluster and chart container\n'

test:
	bash scripts/demo.sh test

cluster:
	bash scripts/demo.sh cluster

install: cluster
	bash scripts/demo.sh install

repo: cluster
	bash scripts/demo.sh repo

ui:
	@test -f .state/kubeconfig || { printf 'Run make test first.\n' >&2; exit 1; }
	@printf 'Open https://localhost:$(ARGOCD_PORT) (accept the self-signed certificate).\nUsername: admin\nPassword: '
	@KUBECONFIG="$(CURDIR)/.state/kubeconfig" kubectl -n argocd get secret argocd-initial-admin-secret -o go-template='{{.data.password | base64decode}}{{"\n"}}'
	@printf 'Press Ctrl+C to stop forwarding.\n'
	KUBECONFIG="$(CURDIR)/.state/kubeconfig" kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server $(ARGOCD_PORT):443

lint:
	shellcheck scripts/demo.sh
	shfmt -d scripts/demo.sh
	helm lint charts/hello-world
	helm template hello-world charts/hello-world > /dev/null

clean:
	bash scripts/demo.sh clean
