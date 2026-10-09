local applicationSet = import 'application-set.libsonnet';

local ENVIRONMENT = 'prod';
local ENVIRONMENT_VALUES = 'prod.yaml';

// Example only: not selected by the demo bootstrap or tested against the registry.
local RELEASES = [
  { name: 'child-one', chart: 'podinfo', version: '6.9.0' },
  { name: 'child-two', chart: 'podinfo', version: '6.9.0' },
  { name: 'child-three', chart: 'podinfo', version: '6.9.0' },
];

function(registry, registryNamespace)
  [applicationSet(registry, registryNamespace, ENVIRONMENT, ENVIRONMENT_VALUES, release) for release in RELEASES]
