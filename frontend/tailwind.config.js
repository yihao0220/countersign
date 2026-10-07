/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        paper: 'var(--paper)',
        paper2: 'var(--paper-2)',
        field: 'var(--field)',
        sheet: 'var(--sheet)',
        ink: 'var(--ink)',
        ink2: 'var(--ink-2)',
        rule: 'var(--rule)',
        rule2: 'var(--rule-strong)',
        cinnabar: 'var(--cinnabar)',
        jade: 'var(--jade)',
      },
      fontFamily: {
        sans: ['"Geist Variable"', '"PingFang SC"', '"Noto Sans SC"', '"Microsoft YaHei"', 'system-ui', 'sans-serif'],
        mono: ['"Geist Mono Variable"', 'ui-monospace', 'SF Mono', 'monospace'],
      },
      borderRadius: { box: '8px' },
    },
  },
  plugins: [],
}
