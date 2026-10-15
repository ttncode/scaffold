import { defineConfig } from 'vitepress';

export default defineConfig({
  title: '@PROJECT_TITLE@',
  description: 'Project documentation',
  head: [['link', { rel: 'icon', href: '/logo.svg' }]],
  ignoreDeadLinks: false,
  themeConfig: {
    logo: '/logo.svg',
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
