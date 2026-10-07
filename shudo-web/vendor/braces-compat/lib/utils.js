'use strict';

const { MAX_DEPTH, MAX_EXPANSIONS, MAX_EXPANDED_LENGTH } = require('./constants');

/**
 * Resolve a caller-supplied limit. Callers may lower a limit but never raise
 * or disable it, and non-finite values fall back to the hard maximum.
 */

exports.resolveLimit = (value, max) => {
  if (typeof value !== 'number' || !Number.isFinite(value)) return max;
  return Math.min(max, Math.max(0, Math.floor(value)));
};

/**
 * Throw before a recursive walker descends past the nesting limit.
 */

exports.maxDepth = (options = {}) => {
  return exports.resolveLimit(options && options.maxDepth, MAX_DEPTH);
};

exports.assertDepth = (depth, max) => {
  if (depth > max) {
    throw new RangeError(`Brace pattern nesting depth exceeds the maximum of ${max}; refusing to process a pattern that could exhaust the call stack.`);
  }
};

/**
 * Count the strings in a (possibly nested) expansion queue, and their total
 * length, without recursion.
 */

exports.measure = list => {
  const pending = [list];
  let count = 0;
  let length = 0;

  while (pending.length > 0) {
    const value = pending.pop();

    if (Array.isArray(value)) {
      for (const item of value) pending.push(item);
      continue;
    }

    if (value !== undefined) {
      count++;
      length += String(value).length;
    }
  }

  return { count, length };
};

/**
 * Track the strings and characters one expansion generates in total and throw
 * once either exceeds its limit.
 */

exports.expansionBudget = (options = {}) => {
  const maxExpansions = exports.resolveLimit(options && options.maxExpansions, MAX_EXPANSIONS);
  const maxLength = exports.resolveLimit(options && options.maxExpandedLength, MAX_EXPANDED_LENGTH);
  let count = 0;
  let length = 0;

  return (addedCount, addedLength) => {
    count += addedCount;
    length += addedLength;

    if (count > maxExpansions) {
      throw new RangeError(`Brace expansion exceeds the maximum of ${maxExpansions} generated values; refusing to expand a pattern that could exhaust memory.`);
    }

    if (length > maxLength) {
      throw new RangeError(`Brace expansion exceeds the maximum of ${maxLength} generated characters; refusing to expand a pattern that could exhaust memory.`);
    }
  };
};

exports.isInteger = num => {
  if (typeof num === 'number') {
    return Number.isInteger(num);
  }
  if (typeof num === 'string' && num.trim() !== '') {
    return Number.isInteger(Number(num));
  }
  return false;
};

/**
 * Find a node of the given type
 */

exports.find = (node, type) => node.nodes.find(node => node.type === type);

/**
 * Find a node of the given type
 */

exports.exceedsLimit = (min, max, step = 1, limit) => {
  if (limit === false) return false;
  if (!exports.isInteger(min) || !exports.isInteger(max)) return false;
  return ((Number(max) - Number(min)) / Number(step)) >= limit;
};

/**
 * Escape the given node with '\\' before node.value
 */

exports.escapeNode = (block, n = 0, type) => {
  const node = block.nodes[n];
  if (!node) return;

  if ((type && node.type === type) || node.type === 'open' || node.type === 'close') {
    if (node.escaped !== true) {
      node.value = '\\' + node.value;
      node.escaped = true;
    }
  }
};

/**
 * Returns true if the given brace node should be enclosed in literal braces
 */

exports.encloseBrace = node => {
  if (node.type !== 'brace') return false;
  if ((node.commas >> 0 + node.ranges >> 0) === 0) {
    node.invalid = true;
    return true;
  }
  return false;
};

/**
 * Returns true if a brace node is invalid.
 */

exports.isInvalidBrace = block => {
  if (block.type !== 'brace') return false;
  if (block.invalid === true || block.dollar) return true;
  if ((block.commas >> 0 + block.ranges >> 0) === 0) {
    block.invalid = true;
    return true;
  }
  if (block.open !== true || block.close !== true) {
    block.invalid = true;
    return true;
  }
  return false;
};

/**
 * Returns true if a node is an open or close node
 */

exports.isOpenOrClose = node => {
  if (node.type === 'open' || node.type === 'close') {
    return true;
  }
  return node.open === true || node.close === true;
};

/**
 * Reduce an array of text nodes.
 */

exports.reduce = nodes => nodes.reduce((acc, node) => {
  if (node.type === 'text') acc.push(node.value);
  if (node.type === 'range') node.type = 'text';
  return acc;
}, []);

/**
 * Flatten an array
 */

exports.flatten = (...args) => {
  const result = [];

  const flat = arr => {
    for (let i = 0; i < arr.length; i++) {
      const ele = arr[i];

      if (Array.isArray(ele)) {
        flat(ele);
        continue;
      }

      if (ele !== undefined) {
        result.push(ele);
      }
    }
    return result;
  };

  flat(args);
  return result;
};
