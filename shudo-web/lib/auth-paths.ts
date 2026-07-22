// Keep the removed privacy route outside the auth redirect so Next.js can
// return a real 404 instead of making the deleted page look sign-in protected.
const PUBLIC_INFORMATION_PATHS = new Set(['/privacy', '/terms', '/support'])

export function isPublicAuthPath(pathname: string): boolean {
  return pathname === '/reset-password' || pathname.startsWith('/auth/')
}

export function isPublicInformationPath(pathname: string): boolean {
  return PUBLIC_INFORMATION_PATHS.has(pathname)
}
