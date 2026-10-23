import "./styles.css";
import { mountApp } from "./app";
import { createRuntimeFromEnv, type RuntimeSetup } from "./lib/runtime";
import { getWindowIdentity } from "./lib/windows";

const identity = getWindowIdentity();
let setup: RuntimeSetup | { error: unknown };
try {
  setup = createRuntimeFromEnv(undefined, { windowLabel: identity.label });
} catch (error) {
  setup = { error };
}

mountApp(document.querySelector<HTMLElement>("#app")!, { setup, identity });
