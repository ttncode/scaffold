import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // the Dockerfile copies .next/standalone, and next only emits that tree when
  // the build is told to. Without this the image build fails on a missing COPY
  // source, long after `next build` reported success.
  output: 'standalone',
};

export default nextConfig;
