#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in yq jq; do
	command -v "$tool" >/dev/null || {
		printf 'Missing tool: %s (run nix develop)\n' "$tool" >&2
		exit 1
	}
done
: "${GIT_HOST:?Set GIT_HOST to the Git hostname, optionally with a port}"
: "${REPO_PATH:?Set REPO_PATH to the repository path}"
: "${HELM_REGISTRY:?Set HELM_REGISTRY to the OCI registry host without a scheme}"
: "${HELM_REGISTRY_NAMESPACE:?Set HELM_REGISTRY_NAMESPACE to the repository path inside the OCI registry}"
case "$HELM_REGISTRY" in
*://*)
	printf 'HELM_REGISTRY must omit the oci:// or https:// prefix\n' >&2
	exit 1
	;;
esac
scheme="${GIT_SCHEME:-https}"
yq -o=json examples/bootstrap/bootstrap.yaml |
	jq --arg host "$GIT_HOST" --arg repo "$REPO_PATH" --arg scheme "$scheme" \
		--arg registry "$HELM_REGISTRY" --arg registryNamespace "$HELM_REGISTRY_NAMESPACE" '
		.spec.generators[0].git.repoURL = ($scheme + "://" + $host + "/" + $repo) |
		.spec.template.spec.source.repoURL = .spec.generators[0].git.repoURL |
		.spec.template.spec.source.directory.jsonnet.tlas |= map(
			if .name == "registry" then .value = $registry
			elif .name == "registryNamespace" then .value = $registryNamespace
			else . end)
	'
