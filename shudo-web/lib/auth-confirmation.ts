export type EmailConfirmationState =
  | { kind: 'confirmed' }
  | { kind: 'verify'; tokenHash: string; type: 'signup' }
  | { kind: 'error' }

export function parseEmailConfirmationUrl(url: URL): EmailConfirmationState {
  const fragment = new URLSearchParams(url.hash.replace(/^#/, ''))
  const queryError = url.searchParams.get('error') ?? url.searchParams.get('error_description')
  const fragmentError = fragment.get('error') ?? fragment.get('error_description')

  if (queryError || fragmentError) return { kind: 'error' }

  const fragmentType = fragment.get('type')
  if (fragmentType === 'signup' && fragment.get('access_token')) {
    return { kind: 'confirmed' }
  }

  const tokenHash = url.searchParams.get('token_hash')
  if (url.searchParams.get('type') === 'signup' && tokenHash) {
    return { kind: 'verify', tokenHash, type: 'signup' }
  }

  return { kind: 'error' }
}

export function confirmationUrlWithoutCredentials(url: URL): string {
  return url.pathname
}
