declare namespace braces {
  interface Options {
    /** Maximum input length. Can only be lowered (default 10,000). */
    maxLength?: number
    /** Maximum brace/parenthesis nesting depth. Can only be lowered (default 100). */
    maxDepth?: number
    /** Maximum strings one expansion may generate. Can only be lowered (default 100,000). */
    maxExpansions?: number
    /** Maximum characters one expansion may generate. Can only be lowered (default 4,000,000). */
    maxExpandedLength?: number
    expand?: boolean
    nodupes?: boolean
    noempty?: boolean
    rangeLimit?: number | false
    step?: number
    keepEscaping?: boolean
    keepQuotes?: boolean
    escapeInvalid?: boolean
    [option: string]: unknown
  }

  interface Node {
    type: string
    value?: string
    nodes?: Node[]
    [key: string]: unknown
  }

  function parse(pattern: string, options?: Options): Node
  function stringify(input: string | Node, options?: Options): string
  function compile(input: string | Node, options?: Options): string
  function expand(input: string | Node, options?: Options): string[]
  function create(input: string, options?: Options): string | string[]
}

declare function braces(pattern: string | readonly string[], options?: braces.Options): string[]

export = braces
