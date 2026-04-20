import { VersionInfo } from '@start9labs/start-sdk'

export const v_0_2_0_0 = VersionInfo.of({
  version: '0.2.0:0',
  releaseNotes: {
    en_US: 'Add StartOS 0.4.0 support',
  },
  migrations: {
    up: async ({ effects }) => {},
    down: async ({ effects }) => {},
  },
})
