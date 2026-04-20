import { compat, types as T } from "../deps.ts";

export const migration: T.ExpectedExports.migration =
  compat.migrations.fromMapping(
    {
      "0.1.0": {
        up: compat.migrations.updateConfig(
          (config) => {
            return config;
          },
          false,
          { version: "0.1.0", type: "up" }
        ),
        down: compat.migrations.updateConfig(
          (config) => {
            return config;
          },
          false,
          { version: "0.1.0", type: "down" }
        ),
      },
      "0.2.0": {
        up: compat.migrations.updateConfig(
          (config) => {
            return config;
          },
          false,
          { version: "0.2.0", type: "up" }
        ),
        down: compat.migrations.updateConfig(
          (config) => {
            return config;
          },
          false,
          { version: "0.2.0", type: "down" }
        ),
      },
    },
    "0.2.0.0"
  );
