import { defineConfig } from "vite";

export default defineConfig({
  clearScreen: false,
  server: { port: 1450, strictPort: true },
  build: { target: "es2022" },
});
