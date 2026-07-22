type AuthErrorLike = {
  code?: unknown
  message?: unknown
  status?: unknown
}

function authErrorLike(error: unknown): AuthErrorLike {
  return typeof error === 'object' && error !== null ? (error as AuthErrorLike) : {}
}

export function magicLinkRequestErrorMessage(error: unknown): string {
  const candidate = authErrorLike(error)
  const status = typeof candidate.status === 'number' ? candidate.status : null
  const code = typeof candidate.code === 'string' ? candidate.code.toLowerCase() : ''
  const message = typeof candidate.message === 'string' ? candidate.message.toLowerCase() : ''

  if (
    status === 429 ||
    code.includes('rate_limit') ||
    message.includes('rate limit') ||
    message.includes('too many requests')
  ) {
    return 'Too many links requested. Wait a minute, then try again.'
  }

  return 'Sign-in link unavailable. Check the address and try again.'
}

export function authCallbackErrorReason(error: unknown): 'browser' | 'expired' {
  const candidate = authErrorLike(error)
  const code = typeof candidate.code === 'string' ? candidate.code.toLowerCase() : ''
  const message = typeof candidate.message === 'string' ? candidate.message.toLowerCase() : ''

  if (
    code.includes('flow_state') ||
    code.includes('code_verifier') ||
    message.includes('code verifier') ||
    message.includes('flow state')
  ) {
    return 'browser'
  }

  return 'expired'
}

export function initialMagicLinkErrorMessage(reason?: string): string {
  if (reason === 'browser') {
    return 'Open the newest sign-in link in the same browser where you requested it.'
  }

  return 'This sign-in link is invalid or expired. Request a new link.'
}
