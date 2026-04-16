import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'hive-mind',
  description: "Git-backed auto-sync for your AI coding assistant's memory and config across machines.",
  base: '/hive-mind/',
  cleanUrls: true,
  lastUpdated: true,
  head: [
    ['meta', { name: 'theme-color', content: '#646cff' }],
  ],

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'How it works', link: '/how-it-works' },
      { text: 'Reference', link: '/reference' },
      { text: 'Troubleshooting', link: '/troubleshooting' },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Home', link: '/' },
          { text: 'How it works', link: '/how-it-works' },
          { text: 'Adapters', link: '/adapters' },
          { text: 'Reference', link: '/reference' },
          { text: 'Troubleshooting', link: '/troubleshooting' },
          { text: 'Contributing adapters', link: '/CONTRIBUTING-adapters' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/tuahear/hive-mind' },
    ],

    search: {
      provider: 'local',
    },

    editLink: {
      pattern: 'https://github.com/tuahear/hive-mind/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Built for <a href="https://claude.com/claude-code">Claude Code</a>.',
    },
  },
})
