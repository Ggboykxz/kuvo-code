// Tailwind v4, through its PostCSS plugin: Next's build runs it over the app's stylesheet,
// so the AI Elements' components carry their classes and the Mac's own rules ride below.

export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};
