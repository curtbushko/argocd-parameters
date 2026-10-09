local applicationSet = import 'application-set.libsonnet';

// Demo identity/cluster targeting, selecting a packaged dev.yaml in your own chart.
local ENVIRONMENT = 'demo';
local ENVIRONMENT_VALUES = 'dev.yaml';

// Example only: not selected by the bootstrap or tested against the registry.
local RELEASES = [
  { name: 'child-one', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-two', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-three', chart: 'podinfo', version: '6.9.2' },
];

function(registry, registryNamespace)
  [applicationSet(registry, registryNamespace, ENVIRONMENT, ENVIRONMENT_VALUES, release) for release in RELEASES]
