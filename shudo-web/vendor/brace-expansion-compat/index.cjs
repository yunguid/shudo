'use strict'

// eslint-disable-next-line @typescript-eslint/no-require-imports -- Legacy consumers require a callable CommonJS export.
const patched = require('brace-expansion-patched')

module.exports = Object.assign(patched.expand, patched)
