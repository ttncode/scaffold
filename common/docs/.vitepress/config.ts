import { defineConfig } from 'vitepress';

export default defineConfig({
  title: '@PROJECT_TITLE@',
  description: 'Project documentation',
  head: [['link', { rel: 'icon', href: '/logo.png' }]],
  ignoreDeadLinks: false,
  themeConfig: {
    logo: '/logo.png',
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/getting-started' },
          { text: 'Deployment', link: '/deployment' },
        ],
      },
    ],
  },
});
