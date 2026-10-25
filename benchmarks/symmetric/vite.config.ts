import { defineConfig } from "vite";

export default defineConfig({
  clearScreen: false,
  server: { port: 1440, strictPort: true },
  build: { target: "es2022" },
});
