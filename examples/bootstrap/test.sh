#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for tool in jsonnet jq helm yq tar; do
	command -v "$tool" >/dev/null || {
		printf 'Missing tool: %s\n' "$tool" >&2
		exit 1
	}
done
readonly HOST=fixture.invalid
readonly REPO=team/repo.git
readonly REGISTRY=ghcr.io
readonly NAMESPACE=stefanprodan/charts
readonly CHART=podinfo
readonly VERSION=6.9.2
mkdir -p .state/oci-test
helm pull "oci://$REGISTRY/$NAMESPACE/$CHART" --version "$VERSION" --destination .state/oci-test
for scheme in https git; do
	bootstrap=$(GIT_HOST="$HOST" REPO_PATH="$REPO" GIT_SCHEME="$scheme" HELM_REGISTRY="$REGISTRY" HELM_REGISTRY_NAMESPACE="$NAMESPACE" bash scripts/render-bootstrap.sh)
	jq -e --arg url "$scheme://$HOST/$REPO" --arg registry "$REGISTRY" --arg registryNamespace "$NAMESPACE" '
		.kind == "ApplicationSet" and .metadata.name == "bootstrap" and
		.spec.generators[0].git.repoURL == $url and
		.spec.generators[0].git.directories[0].path == "examples/application-sets" and
		.spec.template.metadata.name == "bootstrap" and
		.spec.template.spec.source.repoURL == $url and
		.spec.template.spec.source.path == "examples/application-sets" and
		.spec.template.spec.source.directory.include == "dev.jsonnet" and
		(.spec.template.spec.source.directory.jsonnet |
			has("extVars") == false and .tlas == [{name:"registry",value:$registry,code:false},{name:"registryNamespace",value:$registryNamespace,code:false}])
	' <<<"$bootstrap" >/dev/null
done
# Only dev is rendered/tested. staging.jsonnet and prod.jsonnet are reference examples.
file=examples/application-sets/dev.jsonnet
children=$(jsonnet --tla-str registry="$REGISTRY" --tla-str registryNamespace="$NAMESPACE" "$file")
jq -e 'length == 3 and ([.[].metadata.name] | sort) == ["dev-child-one","dev-child-three","dev-child-two"]' <<<"$children" >/dev/null
for child_name in dev-child-one dev-child-two dev-child-three; do
	child=$(jq --arg name "$child_name" '.[] | select(.metadata.name == $name)' <<<"$children")
	jq -e --arg name "$child_name" --arg registry "$REGISTRY/$NAMESPACE" '
		.kind == "ApplicationSet" and .metadata.name == $name and
		.spec.template.metadata.name == $name and .metadata.labels.environment == "dev" and
		.spec.generators[0].clusters.selector.matchLabels == {"bootstrap-demo":"true",environment:"dev"} and
		.spec.template.spec.source.repoURL == $registry and
		.spec.template.spec.source.chart == "podinfo" and
		.spec.template.spec.source.targetRevision == "6.9.2" and
		(.spec.template.spec.source | has("path") == false and has("directory") == false) and
		.spec.template.spec.source.helm == {releaseName:$name,valueFiles:["values.yaml"]} and
		.spec.template.spec.destination.server == "{{.server}}" and
		.spec.template.spec.destination.namespace == $name
	' <<<"$child" >/dev/null
	# Verify image/replicas/resources come from the packaged chart, not per-child overrides.
	helm template "$child_name" ".state/oci-test/$CHART-$VERSION.tgz" \
		--values <(tar -xOf ".state/oci-test/$CHART-$VERSION.tgz" "podinfo/values.yaml") |
		yq -o=json -I=0 |
		jq -s -e --arg name "$child_name-podinfo" '
			any(.[]; .kind == "Deployment" and .metadata.name == $name and
				.spec.replicas == 1 and
				.spec.template.spec.containers[0].image == "ghcr.io/stefanprodan/podinfo:6.9.2" and
				.spec.template.spec.containers[0].resources.requests == {cpu:"1m",memory:"16Mi"})
		' >/dev/null
done
# Unit-check that the helper keeps dev identity while selecting an unrelated filename.
selection=$(jsonnet -e '(import "examples/application-sets/application-set.libsonnet")("registry.example.invalid", "team", "dev", "custom.yaml", {name:"sample",chart:"example",version:"1.2.3"})')
jq -e '.metadata.name == "dev-sample" and .spec.generators[0].clusters.selector.matchLabels.environment == "dev" and .spec.template.spec.source.helm.valueFiles == ["custom.yaml"]' <<<"$selection" >/dev/null
if jsonnet "$file" >/dev/null 2>&1; then
	printf 'Expected missing registry to fail\n' >&2
	exit 1
fi
if jsonnet --tla-str registry="$REGISTRY" "$file" >/dev/null 2>&1; then
	printf 'Expected missing registryNamespace to fail\n' >&2
	exit 1
fi
custom=$(jsonnet --tla-str registry=registry.example.invalid --tla-str registryNamespace=team "$file")
jq -e 'all(.[]; .spec.template.spec.source | .repoURL == "registry.example.invalid/team" and .chart == "podinfo" and .targetRevision == "6.9.2")' <<<"$custom" >/dev/null
if GIT_HOST="$HOST" REPO_PATH="$REPO" HELM_REGISTRY='oci://invalid' HELM_REGISTRY_NAMESPACE="$NAMESPACE" bash scripts/render-bootstrap.sh >/dev/null 2>&1; then
	printf 'Expected registry with scheme to fail\n' >&2
	exit 1
fi
if GIT_HOST='' REPO_PATH='' HELM_REGISTRY='' HELM_REGISTRY_NAMESPACE='' bash scripts/render-bootstrap.sh >/dev/null 2>&1; then
	printf 'Expected missing bootstrap inputs to fail\n' >&2
	exit 1
fi
printf 'PASS: dev release list, shared ApplicationSet template, OCI chart defaults; other environments not tested\n'
