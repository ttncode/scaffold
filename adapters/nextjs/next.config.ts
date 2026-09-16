import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // the Dockerfile copies .next/standalone, which next emits only when asked
  output: 'standalone',
};

export default nextConfig;
