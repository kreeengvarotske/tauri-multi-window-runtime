import { WINDOW_LABELS } from "../lib/runtime";
import { openSecondaryWindow, type OpenResult, type WindowIdentity } from "../lib/windows";
import { errorMessage, h, panel } from "./dom";

export function createWindowPanel(
  identity: WindowIdentity,
  openSecondary: () => Promise<OpenResult> = openSecondaryWindow,
): HTMLElement {
  const label = WINDOW_LABELS.secondary;
  const button = h("button", { class: "btn", text: "Открыть второе окно", attrs: { type: "button" } });
  const status = h("p", { class: "hint", attrs: { "aria-live": "polite" } });

  if (identity.label === label) {
    // Only the main window holds the window-management capability.
    status.textContent = "Это второе окно. Оно использует тот же фронтенд, но отдельный WebView. Открывать окна может только main.";
    return panel("Окна", status);
  }
  if (!identity.native) {
    status.textContent = "В браузере откроется обычная вкладка: это визуальный fallback, а не Tauri-окно.";
  }

  button.addEventListener("click", async () => {
    button.disabled = true;
    status.className = "hint";
    status.textContent = "Открываю…";
    try {
      const result = await openSecondary();
      status.textContent = {
        created: `Создано окно «${label}».`,
        focused: `Окно «${label}» уже открыто, переключился на него.`,
        "browser-tab": "Открыта вкладка браузера (fallback). Это не отдельное Tauri-окно.",
      }[result];
    } catch (error) {
      status.className = "hint text-error";
      status.textContent = errorMessage(error);
    } finally {
      button.disabled = false;
    }
  });

  return panel("Окна", h("div", { class: "row" }, button), status);
}
