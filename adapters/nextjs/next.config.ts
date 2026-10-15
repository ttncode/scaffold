import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // the Dockerfile copies .next/standalone, which next emits only when asked
  output: 'standalone',
  // create-next-app --tailwind wires Tailwind in the file this one replaces
  turbopack: {
    rules: {
      '*.css': { loaders: ['@tailwindcss/turbopack'], as: '*.css' },
    },
  },
};

export default nextConfig;
