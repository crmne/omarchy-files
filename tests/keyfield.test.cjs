const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const edit = vm.createContext({});
vm.runInContext(fs.readFileSync('ui/KeyEdit.js', 'utf8').replace(/^\.pragma.*$/m, ''), edit);
const at = (text, cursor, anchor) => edit.state(text, cursor, anchor);
const measure = value => value.length * 10;

test('Typing inserts at the caret and replaces a selection', () => {
  assert.deepEqual({...edit.insert(at('helo', 3), 'l')}, {text: 'hello', cursor: 4, anchor: 4});
  assert.deepEqual({...edit.insert(edit.selectAll(at('old text')), 'new')}, {text: 'new', cursor: 3, anchor: 3});
  assert.equal(edit.insert(at('abc', 3), 'defg', 5).text, 'abcde');
  assert.equal(edit.insert(at('a', 1), 'b\u{1F600}', 3).text, 'ab', 'a length cap never splits a surrogate pair');
});

test('Backspace, Delete and their word forms remove the right span', () => {
  assert.equal(edit.backspace(at('hello world', 11)).text, 'hello worl');
  assert.equal(edit.backspace(at('hello big world', 10), true).text, 'hello world');
  assert.equal(edit.backspace(at('hello world  ', 13), true).text, 'hello ');
  assert.equal(edit.forwardDelete(at('hello world', 0)).text, 'ello world');
  assert.equal(edit.forwardDelete(at('hello world', 5), true).text, 'hello');
  assert.equal(edit.backspace(at('a\u{1F600}', 3)).text, 'a', 'one Backspace removes a whole emoji');
  assert.equal(edit.backspace(at('select me', 9, 0)).text, '');
  assert.deepEqual({...edit.clear()}, {text: '', cursor: 0, anchor: 0});
});

test('Arrow keys move by character or word and collapse a selection', () => {
  assert.equal(edit.left(at('hello world', 11), true).cursor, 6);
  assert.equal(edit.right(at('hello world', 0), true).cursor, 5);
  assert.equal(edit.left(at('a\u{1F600}', 3)).cursor, 1);
  assert.equal(edit.left(at('hello', 5, 0)).cursor, 0);
  assert.equal(edit.right(at('hello', 0, 5)).cursor, 5);
  const extended = edit.left(at('hello', 5), false, true);
  assert.equal(extended.anchor, 5); assert.equal(extended.cursor, 4);
});

test('Pasted and typed text loses control characters', () => {
  assert.equal(edit.clean('Line one\r\nline\ttwo\u0007\u001b[31m', false), 'Line one line two[31m');
  assert.equal(edit.clean('Line one\r\nline two\rthree', true), 'Line one\nline two\nthree');
  assert.equal(edit.clean('cut mid-character �', false), 'cut mid-character ');
  assert.equal(edit.clean('ends in half a pair \ud83d', false), 'ends in half a pair ');
});

test('Lines wrap after spaces, inside long words, and at hard breaks', () => {
  const text = 'aaa bbb ccc\ndddddddddddd';
  const lines = edit.lines(text, 80, measure, true).map(l => text.slice(l.start, l.end));
  assert.deepEqual(Array.from(lines), ['aaa bbb ', 'ccc', 'dddddddd', 'dddd']);
  assert.deepEqual(Array.from(edit.lines(text, 80, measure, false), l => text.slice(l.start, l.end)), ['aaa bbb ccc', 'dddddddddddd']);
  const layout = edit.lines('aaa bbb ccc', 80, measure, true);
  assert.equal(edit.lineOf(layout, 8), 1, 'a caret at a soft wrap starts the next line');
  assert.equal(edit.lineOf(layout, 11), 1);
  assert.equal(edit.positionInLine('aaa bbb ccc', layout[1], 14, measure), 9);
  assert.equal(edit.positionInLine('aaa bbb ccc', layout[0], 500, measure), 7, 'the end of a wrapped line stays on it');
  assert.deepEqual(Array.from(edit.lines("", 80, measure, true), l => [l.start, l.end]), [[0, 0]]);
});
