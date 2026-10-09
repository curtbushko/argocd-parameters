local applicationSet = import 'application-set.libsonnet';

local ENVIRONMENT = 'dev';
// Public podinfo only packages values.yaml. Your charts can select dev.yaml here.
local ENVIRONMENT_VALUES = 'values.yaml';

// Promote a release by copying its version pin to the next environment's file.
local RELEASES = [
  { name: 'child-one', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-two', chart: 'podinfo', version: '6.9.2' },
  { name: 'child-three', chart: 'podinfo', version: '6.9.2' },
];

function(registry, registryNamespace)
  [applicationSet(registry, registryNamespace, ENVIRONMENT, ENVIRONMENT_VALUES, release) for release in RELEASES]
