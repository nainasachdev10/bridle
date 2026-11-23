import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

/** Static export: the app only reads public chain data, so it can be hosted anywhere. */
export default {
  output: "export",
  images: { unoptimized: true },
  outputFileTracingRoot: dirname(fileURLToPath(import.meta.url)), // not the stray lockfile in $HOME
};
