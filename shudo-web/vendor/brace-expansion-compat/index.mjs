import * as patched from 'brace-expansion-patched'

export * from 'brace-expansion-patched'
export default Object.assign(patched.expand, patched)
