/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: 'pjbxdeswwcrjbbzkhrvv.supabase.co',
        pathname: '/storage/v1/**',
      },
    ],
  },
}

module.exports = nextConfig



