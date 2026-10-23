import type { CachePolicy, ProjectMetadata } from "../lib/runtime";
import { cacheExpiresInMs } from "../state/stats";
import { h } from "./dom";

export interface CacheTimer {
  element: HTMLElement;
  /** Policy reported by Core stats; the timer stays hidden until it is known. */
  setPolicy(policy: CachePolicy): void;
  /** Starts tracking the result of the latest successful series. */
  track(sample: ProjectMetadata): void;
  /** Reacts to a cache-invalidated event; `null` means the whole cache. */
  invalidated(projectId: string | null): void;
}

export interface CacheTimerOptions {
  now?: () => number;
  tickMs?: number;
}

/** Shows how long the result of the latest series stays in the Core cache. */
export function createCacheTimer({ now = Date.now, tickMs = 1000 }: CacheTimerOptions = {}): CacheTimer {
  const element = h("p", { class: "hint", attrs: { "aria-live": "polite", "data-stat": "cache-timer" } });
  element.hidden = true;

  let policy: CachePolicy | null = null;
  let tracked: ProjectMetadata | null = null;
  let dropped = false;
  let ticker: ReturnType<typeof setInterval> | null = null;

  function stopTicking(): void {
    if (ticker !== null) clearInterval(ticker);
    ticker = null;
  }

  function render(): void {
    if (!policy || !tracked) {
      element.hidden = true;
      stopTicking();
      return;
    }
    element.hidden = false;
    const id = tracked.projectId;
    if (dropped) {
      element.className = "hint";
      element.textContent = `Кэш «${id}» сброшен: следующая серия снова выполнит операцию.`;
      stopTicking();
      return;
    }
    if (policy.kind === "noStore") {
      element.className = "hint";
      element.textContent = "Результаты не кэшируются (noStore): каждая серия выполняет операцию заново.";
      stopTicking();
      return;
    }
    const remaining = cacheExpiresInMs(policy, tracked.computedAtMs, now());
    if (remaining === null) {
      element.className = "hint";
      element.textContent = `Результат «${id}» хранится в кэше до сброса.`;
      stopTicking();
    } else if (remaining > 0) {
      element.className = "hint text-ok";
      element.textContent = `Кэш «${id}» истечёт через ${Math.ceil(remaining / 1000)} с.`;
      ticker ??= setInterval(render, tickMs);
    } else {
      element.className = "hint";
      element.textContent = `Кэш «${id}» истёк: следующая серия снова выполнит операцию.`;
      stopTicking();
    }
  }

  return {
    element,
    setPolicy(next) {
      policy = next;
      render();
    },
    track(sample) {
      tracked = sample;
      dropped = false;
      render();
    },
    invalidated(projectId) {
      if (!tracked || (projectId !== null && projectId !== tracked.projectId)) return;
      dropped = true;
      render();
    },
  };
}
