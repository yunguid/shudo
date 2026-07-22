import { SECURITY_HEADERS, SECURITY_HEADER_SOURCE } from './security-headers.mjs'

/** @type {import('next').NextConfig} */
const nextConfig = {
  async headers() {
    return [
      {
        source: SECURITY_HEADER_SOURCE,
        headers: SECURITY_HEADERS,
      },
    ]
  },
}

export default nextConfig
