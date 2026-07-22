export const SECURITY_HEADER_SOURCE = '/:path*'

export const SECURITY_HEADERS = Object.freeze([
  Object.freeze({
    key: 'Content-Security-Policy',
    value: "base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'",
  }),
  Object.freeze({ key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' }),
  Object.freeze({ key: 'X-Content-Type-Options', value: 'nosniff' }),
  Object.freeze({ key: 'X-Frame-Options', value: 'DENY' }),
  Object.freeze({ key: 'X-Permitted-Cross-Domain-Policies', value: 'none' }),
  Object.freeze({
    key: 'Permissions-Policy',
    value: [
      'accelerometer=()',
      'camera=()',
      'display-capture=()',
      'geolocation=()',
      'gyroscope=()',
      'magnetometer=()',
      'microphone=()',
      'payment=()',
      'usb=()',
    ].join(', '),
  }),
])
