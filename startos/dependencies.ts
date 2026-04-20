import { sdk } from './sdk'

export const setDependencies = sdk.setupDependencies(async ({ effects }) => {
  return {
    datum: {
      kind: 'running',
      versionRange: '>=0.4.1:3',
      healthChecks: ['stratum-interface'],
    },
  }
})
