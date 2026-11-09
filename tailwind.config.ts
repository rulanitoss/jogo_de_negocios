import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#eef6ff",
          100: "#d9eaff",
          200: "#bcdcff",
          300: "#8ec6ff",
          400: "#59a5ff",
          500: "#2f80ff",
          600: "#1a5ff5",
          700: "#144ae1",
          800: "#173eb6",
          900: "#19388f",
          950: "#142357"
        },
        surface: {
          light: "#f7f8fa",
          dark: "#0d1117"
        },
        money: {
          positive: "#16a34a",
          negative: "#dc2626",
          neutral: "#6b7280"
        }
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "-apple-system", "Segoe UI", "Roboto", "sans-serif"],
        mono: ["JetBrains Mono", "ui-monospace", "SFMono-Regular", "Menlo", "monospace"]
      }
    }
  },
  plugins: []
};

export default config;
