.pragma library
// Text editing and line layout for KeyField, free of Qt so Node can test it.
// A state is {text, cursor, anchor}; the selection runs between anchor and
// cursor. Every operation returns a new state and leaves its input alone.

// The most a paste may insert, matching the byte cap on the clipboard read.
var PASTE_LIMIT = 4096;

function state(text, cursor, anchor) {
    text = String(text || "");
    cursor = clamp(cursor === undefined ? text.length : cursor, 0, text.length);
    return {text: text, cursor: cursor, anchor: anchor === undefined ? cursor : clamp(anchor, 0, text.length)};
}
function clamp(value, low, high) { return Math.max(low, Math.min(high, Number(value) || 0)); }
function selection(s) { return {start: Math.min(s.anchor, s.cursor), end: Math.max(s.anchor, s.cursor)}; }
function hasSelection(s) { return s.anchor !== s.cursor; }
function selectedText(s) { var r = selection(s); return s.text.slice(r.start, r.end); }

function isHigh(code) { return code >= 0xd800 && code <= 0xdbff; }
function isLow(code) { return code >= 0xdc00 && code <= 0xdfff; }
// Caret stops never split a surrogate pair.
function previous(text, pos) {
    if (pos <= 0) return 0;
    return pos >= 2 && isLow(text.charCodeAt(pos - 1)) && isHigh(text.charCodeAt(pos - 2)) ? pos - 2 : pos - 1;
}
function next(text, pos) {
    if (pos >= text.length) return text.length;
    return pos + 2 <= text.length && isHigh(text.charCodeAt(pos)) && isLow(text.charCodeAt(pos + 1)) ? pos + 2 : pos + 1;
}
function space(ch) { return /\s/.test(ch); }
function wordStart(text, pos) {
    while (pos > 0 && space(text[pos - 1])) pos--;
    while (pos > 0 && !space(text[pos - 1])) pos--;
    return pos;
}
function wordEnd(text, pos) {
    while (pos < text.length && space(text[pos])) pos++;
    while (pos < text.length && !space(text[pos])) pos++;
    return pos;
}

// Text from a key event or the clipboard, without control characters.
// A multi-line field keeps line breaks; a single-line field turns them into
// spaces. A paste cut at the byte cap may end in half a character, which
// decodes as U+FFFD or a lone high surrogate, so those are dropped.
function clean(value, multiline) {
    var text = String(value || "").replace(/\r\n?/g, "\n").replace(/\t/g, " ");
    text = multiline ? text.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, "") : text.replace(/\n/g, " ").replace(/[\u0000-\u001f\u007f-\u009f]/g, "");
    text = text.replace(/�+$/, "");
    if (text.length && isHigh(text.charCodeAt(text.length - 1))) text = text.slice(0, -1);
    return text;
}
function fit(value, room) {
    if (value.length <= room) return value;
    value = value.slice(0, Math.max(0, room));
    return value.length && isHigh(value.charCodeAt(value.length - 1)) ? value.slice(0, -1) : value;
}

// Replace the selection, or insert at the caret, keeping within maxLength.
function insert(s, value, maxLength) {
    var r = selection(s), limit = maxLength === undefined ? Infinity : maxLength;
    value = fit(String(value), limit - (s.text.length - (r.end - r.start)));
    var text = s.text.slice(0, r.start) + value + s.text.slice(r.end), cursor = r.start + value.length;
    return {text: text, cursor: cursor, anchor: cursor};
}
function cut(s, start, end) {
    var text = s.text.slice(0, start) + s.text.slice(end);
    return {text: text, cursor: start, anchor: start};
}
function backspace(s, word) {
    if (hasSelection(s)) { var r = selection(s); return cut(s, r.start, r.end); }
    return cut(s, word ? wordStart(s.text, s.cursor) : previous(s.text, s.cursor), s.cursor);
}
function forwardDelete(s, word) {
    if (hasSelection(s)) { var r = selection(s); return cut(s, r.start, r.end); }
    return cut(s, s.cursor, word ? wordEnd(s.text, s.cursor) : next(s.text, s.cursor));
}
function clear() { return {text: "", cursor: 0, anchor: 0}; }
function selectAll(s) { return {text: s.text, cursor: s.text.length, anchor: 0}; }
// Move the caret. Without extend, a selection collapses toward the move.
function moveTo(s, pos, extend) {
    pos = clamp(pos, 0, s.text.length);
    return {text: s.text, cursor: pos, anchor: extend ? s.anchor : pos};
}
function left(s, word, extend) {
    if (!extend && !word && hasSelection(s)) return moveTo(s, selection(s).start, false);
    return moveTo(s, word ? wordStart(s.text, s.cursor) : previous(s.text, s.cursor), extend);
}
function right(s, word, extend) {
    if (!extend && !word && hasSelection(s)) return moveTo(s, selection(s).end, false);
    return moveTo(s, word ? wordEnd(s.text, s.cursor) : next(s.text, s.cursor), extend);
}

// Break text into display lines. Each line is {start, end, hard}: end
// excludes a line break, and hard marks the last line of a paragraph.
// With wrap, lines break after a space where possible, otherwise inside the
// word, so no line is wider than width unless one character is. measure
// returns the width of a string.
function lines(text, width, measure, wrap) {
    var result = [], offset = 0, paragraphs = String(text).split("\n");
    for (var p = 0; p < paragraphs.length; p++) {
        var para = paragraphs[p], start = 0;
        while (wrap && width > 0 && start < para.length && measure(para.slice(start)) > width) {
            // Longest prefix that fits, found by bisection: widths only grow.
            var low = next(para, start), high = para.length;
            while (low < high) {
                var mid = Math.ceil((low + high) / 2);
                if (measure(para.slice(start, mid)) <= width) low = mid; else high = mid - 1;
            }
            if (low > start + 1 && isHigh(para.charCodeAt(low - 1))) low--;
            var end = low;
            if (para[end] === " ") {
                while (end < para.length && para[end] === " ") end++;
            } else {
                var gap = para.lastIndexOf(" ", end - 1);
                if (gap >= start) end = gap + 1;
            }
            result.push({start: offset + start, end: offset + end, hard: false});
            start = end;
        }
        result.push({start: offset + start, end: offset + para.length, hard: true});
        offset += para.length + 1;
    }
    return result;
}
// The line holding a caret position. At a soft wrap the caret belongs to the
// start of the next line.
function lineOf(layout, pos) {
    for (var i = 0; i < layout.length; i++) {
        var line = layout[i];
        if (pos >= line.start && (pos < line.end || pos === line.end && line.hard)) return i;
    }
    return layout.length - 1;
}
// The caret position nearest to x on a line.
function positionInLine(text, line, x, measure) {
    var best = line.start, distance = Infinity;
    for (var pos = line.start; pos <= line.end; pos = next(text, pos)) {
        var d = Math.abs(measure(text.slice(line.start, pos)) - x);
        if (d < distance) { distance = d; best = pos; }
        if (pos === line.end) break;
    }
    // A soft-wrapped line ends where the next begins; stay on this one.
    if (!line.hard && best === line.end && best > line.start) best = previous(text, best);
    return best;
}
