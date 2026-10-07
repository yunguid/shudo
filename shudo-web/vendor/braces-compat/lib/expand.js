'use strict';

const fill = require('fill-range');
const stringify = require('./stringify');
const utils = require('./utils');

// `charge` is the expansion budget. It is checked once, before the product is
// built, from the exact number of strings (and characters) the product will
// hold; the recursive calls below build parts of that same product.
const append = (queue = '', stash = '', enclose = false, charge) => {
  const result = [];

  queue = [].concat(queue);
  stash = [].concat(stash);

  if (!stash.length) return queue;
  if (!queue.length) {
    if (!enclose) return stash;
    const values = utils.flatten(stash);
    if (charge) {
      const size = utils.measure(values);
      charge(size.count, size.length + 2 * size.count);
    }
    return values.map(ele => `{${ele}}`);
  }

  if (charge) {
    const q = utils.measure(queue);
    const s = utils.measure(stash);
    const count = q.count * s.count;
    charge(count, q.count * s.length + s.count * q.length + (enclose ? 2 * count : 0));
  }

  for (const item of queue) {
    if (Array.isArray(item)) {
      for (const value of item) {
        result.push(append(value, stash, enclose));
      }
    } else {
      for (let ele of stash) {
        if (enclose === true && typeof ele === 'string') ele = `{${ele}}`;
        result.push(Array.isArray(ele) ? append(item, ele, enclose) : item + ele);
      }
    }
  }
  return utils.flatten(result);
};

const expand = (ast, options = {}) => {
  const rangeLimit = options.rangeLimit === undefined ? 1000 : options.rangeLimit;
  const maxDepth = utils.maxDepth(options);
  const charge = utils.expansionBudget(options);

  const walk = (node, parent = {}, depth = 0) => {
    utils.assertDepth(depth, maxDepth);
    node.queue = [];

    let p = parent;
    let q = parent.queue;

    while (p.type !== 'brace' && p.type !== 'root' && p.parent) {
      p = p.parent;
      q = p.queue;
    }

    if (node.invalid || node.dollar) {
      q.push(append(q.pop(), stringify(node, options), false, charge));
      return;
    }

    if (node.type === 'brace' && node.invalid !== true && node.nodes.length === 2) {
      q.push(append(q.pop(), ['{}'], false, charge));
      return;
    }

    if (node.nodes && node.ranges > 0) {
      const args = utils.reduce(node.nodes);

      if (utils.exceedsLimit(...args, options.step, rangeLimit)) {
        throw new RangeError('expanded array length exceeds range limit. Use options.rangeLimit to increase or disable the limit.');
      }

      let range = fill(...args, options);
      if (range.length === 0) {
        range = stringify(node, options);
      }

      q.push(append(q.pop(), range, false, charge));
      node.nodes = [];
      return;
    }

    const enclose = utils.encloseBrace(node);
    let queue = node.queue;
    let block = node;

    while (block.type !== 'brace' && block.type !== 'root' && block.parent) {
      block = block.parent;
      queue = block.queue;
    }

    for (let i = 0; i < node.nodes.length; i++) {
      const child = node.nodes[i];

      if (child.type === 'comma' && node.type === 'brace') {
        if (i === 1) queue.push('');
        queue.push('');
        continue;
      }

      if (child.type === 'close') {
        q.push(append(q.pop(), queue, enclose, charge));
        continue;
      }

      if (child.value && child.type !== 'open') {
        queue.push(append(queue.pop(), child.value, false, charge));
        continue;
      }

      if (child.nodes) {
        walk(child, node, depth + 1);
      }
    }

    return queue;
  };

  return utils.flatten(walk(ast));
};

module.exports = expand;
