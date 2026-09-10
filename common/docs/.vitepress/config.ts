import { defineConfig } from 'vitepress';

export default defineConfig({
  title: '@PROJECT_NAME@',
  description: 'Project documentation',
  head: [['link', { rel: 'icon', href: '/logo.png' }]],
  // a dead link is a failed build, not a warning
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
