// A fast drop-in replacement for csv-reader 1.0.0's readCsv.
//
// run(input) reads input {text, header} and returns {columns, rows, errors}
// with exactly the reference reader's broken-row policy:
//
//   - a U+FEFF at the very start of the text is dropped;
//   - a record ends at LF or CRLF; a line left with no characters is no record;
//   - a CR outside quotes that is not followed by LF is dropped (stray_cr);
//   - a field that opens with a quote runs to the next quote that is not
//     doubled; "" inside it is one quote, and each CRLF or lone CR inside it
//     is read as LF; what follows the closing quote, up to the next comma or
//     line break, is appended as it stands (quote_junk, when anything was
//     appended); a quote that never closes is a literal character and the
//     text after it is read again as unquoted (unterminated_quote);
//   - a quote inside an unquoted field is a literal character; fields stay
//     strings, never trimmed or converted;
//   - columns is the first record when header is true, else null; rows are
//     padded with "" (short_row) or cut (long_row) to the first record's
//     width;
//   - each error is {code, line, row}: line the 1-based line the record
//     starts on (every LF, CRLF and lone CR inside a quoted field counted),
//     row the record's index in rows (null for the header), in the order met.
//
// Where the reference walks one character at a time and builds every field
// character by character, this reader keeps the same single left-to-right
// pass but works in spans: it scans with charCodeAt for the next delimiter
// and cuts each field out of the text with one slice, so the common field
// costs one scan and one slice instead of one string append per character.
// Quoted fields first try a jump scan that leaps from quote to quote with
// indexOf; only a field whose content holds a carriage return (where CR and
// CRLF must be rewritten to LF) falls back to a span scan that rewrites as
// it goes.

const COMMA_END = 0;
const BREAK_END = 1;
const TEXT_END = 2;

export function run(input) {
  const text = typeof input.text === 'string' ? input.text : String(input.text);
  const header = input.header === true;
  const n = text.length;

  const errors = [];
  const rows = [];
  let columns = null;
  let width = -1;

  let pos = 0; // index of the next character to read
  let line = 1; // the line that character is on
  if (text.charCodeAt(0) === 0xfeff) pos = 1;

  // The record being read: the line it starts on, and its index in rows
  // (null while it is the header record).
  let recordLine = 1;
  let recordRow = null;

  // The field most recently read, and how it ended.
  let fv = '';
  let fEnd = TEXT_END;

  function fail(code) {
    errors.push({ code, line: recordLine, row: recordRow });
  }

  // Reads unquoted characters onto the prefix `head`, up to the next comma
  // or line break; a CR not followed by LF is dropped (stray_cr). Sets fv
  // and fEnd, and returns how many characters were appended to head.
  function readUnquoted(head) {
    let value = head;
    let added = 0;
    let seg = pos;
    let i = pos;
    for (;;) {
      // Scan to the next comma, LF or CR, carrying the character stopped at
      // (-1 at the end of the text) so it is not read twice.
      let c = -1;
      while (i < n) {
        c = text.charCodeAt(i);
        if (c === 44 || c === 10 || c === 13) break;
        i += 1;
        c = -1;
      }
      if (i > seg) {
        value += text.slice(seg, i);
        added += i - seg;
      }
      if (c === 44) {
        pos = i + 1;
        fv = value;
        fEnd = COMMA_END;
        return added;
      }
      if (c === 10) {
        pos = i + 1;
        line += 1;
        fv = value;
        fEnd = BREAK_END;
        return added;
      }
      if (c === 13 && text.charCodeAt(i + 1) === 10) {
        // CRLF: the record ends.
        pos = i + 2;
        line += 1;
        fv = value;
        fEnd = BREAK_END;
        return added;
      }
      if (c === -1) {
        pos = n;
        fv = value;
        fEnd = TEXT_END;
        return added;
      }
      // A lone CR: dropped, and the field goes on.
      fail('stray_cr');
      i += 1;
      seg = i;
      pos = i;
    }
  }

  // The reading of a quoted field once its content is known: the field ends
  // here, at a comma, at a line break, or goes on with junk appended.
  function afterQuoted(value) {
    if (pos >= n) {
      fv = value;
      fEnd = TEXT_END;
      return;
    }
    const c = text.charCodeAt(pos);
    if (c === 44) {
      pos += 1;
      fv = value;
      fEnd = COMMA_END;
      return;
    }
    if (c === 10) {
      pos += 1;
      line += 1;
      fv = value;
      fEnd = BREAK_END;
      return;
    }
    if (c === 13 && text.charCodeAt(pos + 1) === 10) {
      pos += 2;
      line += 1;
      fv = value;
      fEnd = BREAK_END;
      return;
    }
    const added = readUnquoted(value);
    if (added > 0) fail('quote_junk');
  }

  // The span scan of a quoted field whose opening quote is at `open`, used
  // when the content holds a carriage return: CR and CRLF inside quotes are
  // each read as LF, so the content is cut in spans at every CR and rejoined
  // with "\n" where a CR stood.
  function readQuotedWithReturns(open, openLine) {
    let value = '';
    let seg = open + 1;
    let i = seg;
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c === 34) {
        if (text.charCodeAt(i + 1) === 34) {
          value += text.slice(seg, i) + '"';
          i += 2;
          seg = i;
          continue;
        }
        value += text.slice(seg, i);
        pos = i + 1;
        afterQuoted(value);
        return;
      }
      if (c === 13) {
        value += text.slice(seg, i) + '\n';
        line += 1;
        i += text.charCodeAt(i + 1) === 10 ? 2 : 1;
        seg = i;
        continue;
      }
      if (c === 10) line += 1;
      i += 1;
    }
    // The quote never closes: it is a literal character, and the text after
    // it is read again as unquoted.
    line = openLine;
    pos = open + 1;
    fail('unterminated_quote');
    readUnquoted('"');
  }

  // Reads a quoted field whose opening quote is at pos.
  function readQuoted() {
    const open = pos;
    const openLine = line;
    // Jump scan: leap from quote to quote. The content is assembled from
    // the spans between doubled quotes; it is exact as long as it holds no
    // carriage return, which the span scan above is for.
    let value = null;
    let seg = open + 1;
    let i = seg;
    for (;;) {
      const q = text.indexOf('"', i);
      if (q === -1) {
        // The quote never closes.
        pos = open + 1;
        fail('unterminated_quote');
        readUnquoted('"');
        return;
      }
      if (text.charCodeAt(q + 1) === 34) {
        value = (value === null ? text.slice(seg, q) : value + text.slice(seg, q)) + '"';
        i = q + 2;
        seg = i;
        continue;
      }
      const content = value === null ? text.slice(seg, q) : value + text.slice(seg, q);
      if (content.indexOf('\r') !== -1) {
        readQuotedWithReturns(open, openLine);
        return;
      }
      // No carriage return inside: each LF in the content is one more line.
      let breaks = 0;
      for (let k = content.indexOf('\n'); k !== -1; k = content.indexOf('\n', k + 1)) breaks += 1;
      line += breaks;
      pos = q + 1;
      afterQuoted(content);
      return;
    }
  }

  for (;;) {
    // Lines with no characters are no records.
    while (pos < n) {
      const c = text.charCodeAt(pos);
      if (c === 10) {
        pos += 1;
        line += 1;
      } else if (c === 13 && text.charCodeAt(pos + 1) === 10) {
        pos += 2;
        line += 1;
      } else {
        break;
      }
    }
    if (pos >= n) break;

    recordLine = line;
    recordRow = header && columns === null ? null : rows.length;
    const fields = [];
    let lastQuoted = false;
    for (;;) {
      if (text.charCodeAt(pos) === 34) {
        lastQuoted = true;
        readQuoted();
      } else {
        lastQuoted = false;
        readUnquoted('');
      }
      fields.push(fv);
      if (fEnd !== COMMA_END) break;
    }

    // A line that held only stray CRs is left with no characters: no record
    // (its stray_cr errors stay).
    if (fields.length === 1 && fields[0] === '' && !lastQuoted) continue;

    if (width < 0) width = fields.length;
    if (header && columns === null) {
      columns = fields;
      continue;
    }
    if (fields.length < width) {
      errors.push({ code: 'short_row', line: recordLine, row: recordRow, fields: fields.length });
      while (fields.length < width) fields.push('');
    } else if (fields.length > width) {
      errors.push({ code: 'long_row', line: recordLine, row: recordRow, extra: fields.splice(width) });
    }
    rows.push(fields);
  }

  return { columns: header ? (columns ?? []) : null, rows, errors };
}
