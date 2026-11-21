;; transduce.wat — zero-JSON CSV transducer for the csv-reader-speed-01 entry.
;;
;; transduce(inPtr, inLen, headerFlag) reads the raw ESCAPED bytes of one
;; case's JSON string body (the bytes between the quotes of "text":"..."),
;; decodes them (JSON string escapes -> the case's real text bytes), parses
;; the text with exactly csv-reader 1.0.0's semantics (as solve.js defines
;; them), and serializes the answer's pieces into fixed memory regions:
;;
;;   results block at 0:  [0]=status (0 ok, 1 overflow -> driver falls back)
;;                        [4]=record count        [8]=errors byte length
;;                        [12]=decoded byte length
;;   record table at 4096: recordCount pairs (offset, length) of each
;;                        record's serialized JSON array text in REC region
;;   errors region: the case's error objects, comma-joined, no brackets
;;
;; The driver assembles {"columns":...,"rows":[...],"errors":[...]} from
;; these regions with Buffer copies only. Memory is one fixed block; any
;; region overflow sets status=1 and the driver answers that case with the
;; JS path (solve.js) instead, so output is never wrong for size reasons.
;;
;; Surrogates: \uXXXX decoding combines a surrogate pair into its astral
;; codepoint (UTF-8); a lone surrogate is carried as WTF-8 bytes and the
;; output escaper turns those back into the \uXXXX escape JSON.stringify
;; would emit, so field bytes match the reference exactly either way.

(module
  (memory (export "memory") 1120 1120)

  ;; ---- static strings -------------------------------------------------
  (data (i32.const 2048) "stray_cr")
  (data (i32.const 2080) "quote_junk")
  (data (i32.const 2112) "unterminated_quote")
  (data (i32.const 2144) "short_row")
  (data (i32.const 2176) "long_row")
  (data (i32.const 2208) "{\"code\":\"")
  (data (i32.const 2240) "\",\"line\":")
  (data (i32.const 2272) ",\"row\":")
  (data (i32.const 2304) "null")
  (data (i32.const 2336) ",\"fields\":")
  (data (i32.const 2368) ",\"extra\":[")
  (data (i32.const 2400) ",\"\"")

  ;; ---- globals ----------------------------------------------------------
  (global $g_failed (mut i32) (i32.const 0))
  (global $g_pos (mut i32) (i32.const 0))        ;; absolute addr in DEC region
  (global $g_line (mut i32) (i32.const 1))
  (global $g_decEnd (mut i32) (i32.const 0))     ;; absolute end of decoded text
  (global $g_inEnd (mut i32) (i32.const 0))      ;; absolute end of escaped input
  (global $g_out (mut i32) (i32.const 35651584)) ;; REC write pointer
  (global $g_err (mut i32) (i32.const 69206016)) ;; ERR write pointer
  (global $g_errCount (mut i32) (i32.const 0))
  (global $g_recCount (mut i32) (i32.const 0))
  (global $g_rows (mut i32) (i32.const 0))
  (global $g_width (mut i32) (i32.const -1))
  (global $g_header (mut i32) (i32.const 0))
  (global $g_recLine (mut i32) (i32.const 1))
  (global $g_recRow (mut i32) (i32.const 0))
  (global $g_recRowNull (mut i32) (i32.const 0))
  (global $g_fEnd (mut i32) (i32.const 2))       ;; 0 comma, 1 break, 2 text end
  (global $g_valChars (mut i32) (i32.const 0))   ;; value chars emitted (zero-test only)
  (global $g_lastQuoted (mut i32) (i32.const 0))
  (global $g_endWidth (mut i32) (i32.const 0))   ;; REC addr just past field #width
  (global $g_extraStart (mut i32) (i32.const 0)) ;; REC addr of field #width+1 start
  (global $g_fmtPtr (mut i32) (i32.const 0))

  ;; ---- region writers ---------------------------------------------------
  (func $rec_put (param $b i32)
    (if (i32.ge_u (global.get $g_out) (i32.const 69206016))
      (then (global.set $g_failed (i32.const 1)) (return)))
    (i32.store8 (global.get $g_out) (local.get $b))
    (global.set $g_out (i32.add (global.get $g_out) (i32.const 1))))

  (func $rec_putn (param $p i32) (param $l i32)
    (if (i32.eqz (local.get $l)) (then (return)))
    (if (i32.gt_u (i32.add (global.get $g_out) (local.get $l)) (i32.const 69206016))
      (then (global.set $g_failed (i32.const 1)) (return)))
    (memory.copy (global.get $g_out) (local.get $p) (local.get $l))
    (global.set $g_out (i32.add (global.get $g_out) (local.get $l))))

  (func $err_put (param $b i32)
    (if (i32.ge_u (global.get $g_err) (i32.const 73400320))
      (then (global.set $g_failed (i32.const 1)) (return)))
    (i32.store8 (global.get $g_err) (local.get $b))
    (global.set $g_err (i32.add (global.get $g_err) (i32.const 1))))

  (func $err_putn (param $p i32) (param $l i32)
    (if (i32.eqz (local.get $l)) (then (return)))
    (if (i32.gt_u (i32.add (global.get $g_err) (local.get $l)) (i32.const 73400320))
      (then (global.set $g_failed (i32.const 1)) (return)))
    (memory.copy (global.get $g_err) (local.get $p) (local.get $l))
    (global.set $g_err (i32.add (global.get $g_err) (local.get $l))))

  ;; ---- small helpers ------------------------------------------------------
  (func $hex_digit (param $v i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $v) (i32.const 10))
      (then (i32.add (i32.const 48) (local.get $v)))
      (else (i32.add (i32.const 87) (local.get $v)))))

  ;; SWAR hasbyte mask: 0x80 bit set in each byte lane equal to $v (the mask
  ;; may over-report a lane by borrow effects, but never misses a match, so
  ;; callers use it to skip clean chunks and verify candidates exactly).
  (func $hb (param $x i64) (param $v i64) (result i64)
    (local $t i64)
    (local.set $t (i64.xor (local.get $x)
      (i64.mul (local.get $v) (i64.const 0x0101010101010101))))
    (i64.and
      (i64.sub (local.get $t) (i64.const 0x0101010101010101))
      (i64.and (i64.xor (local.get $t) (i64.const -1))
               (i64.const 0x8080808080808080))))

  ;; Mask of bytes that cannot be copied raw into a JSON string:
  ;; < 0x20, quote, backslash, or 0xED (possible WTF-8 surrogate lead).
  (func $spcl (param $x i64) (result i64)
    (i64.or
      (i64.or
        (i64.and
          (i64.sub (local.get $x) (i64.const 0x2020202020202020))
          (i64.and (i64.xor (local.get $x) (i64.const -1))
                   (i64.const 0x8080808080808080)))
        (call $hb (local.get $x) (i64.const 34)))
      (i64.or
        (call $hb (local.get $x) (i64.const 92))
        (call $hb (local.get $x) (i64.const 237)))))

  (func $is_safe (param $b i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $b) (i32.const 32))
      (i32.and
        (i32.ne (local.get $b) (i32.const 34))
        (i32.and
          (i32.ne (local.get $b) (i32.const 92))
          (i32.ne (local.get $b) (i32.const 237))))))

  ;; Format u32 decimal into scratch at 64..74; sets $g_fmtPtr, returns length.
  (func $fmt_dec (param $v i32) (result i32)
    (local $p i32)
    (local.set $p (i32.const 74))
    (block $done
      (loop $lp
        (local.set $p (i32.sub (local.get $p) (i32.const 1)))
        (i32.store8 (local.get $p)
          (i32.add (i32.const 48) (i32.rem_u (local.get $v) (i32.const 10))))
        (local.set $v (i32.div_u (local.get $v) (i32.const 10)))
        (br_if $done (i32.eqz (local.get $v)))
        (br $lp)))
    (global.set $g_fmtPtr (local.get $p))
    (i32.sub (i32.const 74) (local.get $p)))

  ;; Escape-write one value byte exactly as JSON.stringify would.
  (func $esc_byte (param $b i32)
    (if (i32.eq (local.get $b) (i32.const 34))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 34)) (return)))
    (if (i32.eq (local.get $b) (i32.const 92))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 92)) (return)))
    (if (i32.eq (local.get $b) (i32.const 8))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 98)) (return)))
    (if (i32.eq (local.get $b) (i32.const 9))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 116)) (return)))
    (if (i32.eq (local.get $b) (i32.const 10))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 110)) (return)))
    (if (i32.eq (local.get $b) (i32.const 12))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 102)) (return)))
    (if (i32.eq (local.get $b) (i32.const 13))
      (then (call $rec_put (i32.const 92)) (call $rec_put (i32.const 114)) (return)))
    (if (i32.lt_u (local.get $b) (i32.const 32))
      (then
        (call $rec_put (i32.const 92)) (call $rec_put (i32.const 117))
        (call $rec_put (i32.const 48)) (call $rec_put (i32.const 48))
        (call $rec_put (call $hex_digit (i32.shr_u (local.get $b) (i32.const 4))))
        (call $rec_put (call $hex_digit (i32.and (local.get $b) (i32.const 15))))
        (return)))
    (call $rec_put (local.get $b)))

  ;; Escape-copy DEC[$s..$e) into REC as field-value bytes.
  (func $span (param $s i32) (param $e i32)
    (local $i i32) (local $j i32) (local $b i32)
    (local $b2 i32) (local $b3 i32) (local $cp i32) (local $x i64)
    (if (i32.gt_u (local.get $e) (local.get $s))
      (then (global.set $g_valChars
        (i32.add (global.get $g_valChars) (i32.sub (local.get $e) (local.get $s))))))
    (local.set $i (local.get $s))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (local.get $e)))
        ;; SWAR fast path: a clean 8-byte chunk is stored wholesale
        (if (i32.le_u (i32.add (local.get $i) (i32.const 8)) (local.get $e))
          (then
            (local.set $x (i64.load (local.get $i)))
            (if (i64.eqz (call $spcl (local.get $x)))
              (then
                (if (i32.gt_u (i32.add (global.get $g_out) (i32.const 8)) (i32.const 69206016))
                  (then (global.set $g_failed (i32.const 1)))
                  (else
                    (i64.store (global.get $g_out) (local.get $x))
                    (global.set $g_out (i32.add (global.get $g_out) (i32.const 8)))))
                (local.set $i (i32.add (local.get $i) (i32.const 8)))
                (br $lp)))))
        (local.set $b (i32.load8_u (local.get $i)))
        ;; a WTF-8 lone surrogate (ED A0-BF 80-BF) is written by
        ;; JSON.stringify as a \uXXXX escape, never as raw bytes
        (if (i32.eq (local.get $b) (i32.const 237))
          (then
            (if (i32.lt_u (i32.add (local.get $i) (i32.const 2)) (global.get $g_decEnd))
              (then
                (local.set $b2 (i32.load8_u (i32.add (local.get $i) (i32.const 1))))
                (local.set $b3 (i32.load8_u (i32.add (local.get $i) (i32.const 2))))
                (if (i32.and (i32.ge_u (local.get $b2) (i32.const 160))
                      (i32.and (i32.le_u (local.get $b2) (i32.const 191))
                        (i32.and (i32.ge_u (local.get $b3) (i32.const 128))
                                 (i32.le_u (local.get $b3) (i32.const 191)))))
                  (then
                    (local.set $cp
                      (i32.or (i32.shl (i32.and (local.get $b) (i32.const 15)) (i32.const 12))
                        (i32.or (i32.shl (i32.and (local.get $b2) (i32.const 63)) (i32.const 6))
                                (i32.and (local.get $b3) (i32.const 63)))))
                    (call $rec_put (i32.const 92))
                    (call $rec_put (i32.const 117))
                    (call $rec_put (call $hex_digit (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 15))))
                    (call $rec_put (call $hex_digit (i32.and (i32.shr_u (local.get $cp) (i32.const 8)) (i32.const 15))))
                    (call $rec_put (call $hex_digit (i32.and (i32.shr_u (local.get $cp) (i32.const 4)) (i32.const 15))))
                    (call $rec_put (call $hex_digit (i32.and (local.get $cp) (i32.const 15))))
                    (local.set $i (i32.add (local.get $i) (i32.const 3)))
                    (br $lp)))))))
        (if (call $is_safe (local.get $b))
          (then
            (local.set $j (i32.add (local.get $i) (i32.const 1)))
            (block $rd
              (loop $rl
                (br_if $rd (i32.ge_u (local.get $j) (local.get $e)))
                (br_if $rd (i32.eqz (call $is_safe (i32.load8_u (local.get $j)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $rl)))
            (call $rec_putn (local.get $i) (i32.sub (local.get $j) (local.get $i)))
            (local.set $i (local.get $j))
            (br $lp)))
        (call $esc_byte (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Escape-write a single value byte and count it as a value character.
  (func $val_byte (param $b i32)
    (call $esc_byte (local.get $b))
    (global.set $g_valChars (i32.add (global.get $g_valChars) (i32.const 1))))

  ;; ---- error serialization ------------------------------------------------
  (func $err_prefix (param $co i32) (param $cl i32)
    (local $l i32)
    (if (global.get $g_errCount) (then (call $err_put (i32.const 44))))
    (call $err_putn (i32.const 2208) (i32.const 9))
    (call $err_putn (local.get $co) (local.get $cl))
    (call $err_putn (i32.const 2240) (i32.const 9))
    (local.set $l (call $fmt_dec (global.get $g_recLine)))
    (call $err_putn (global.get $g_fmtPtr) (local.get $l))
    (call $err_putn (i32.const 2272) (i32.const 7))
    (if (global.get $g_recRowNull)
      (then (call $err_putn (i32.const 2304) (i32.const 4)))
      (else
        (local.set $l (call $fmt_dec (global.get $g_recRow)))
        (call $err_putn (global.get $g_fmtPtr) (local.get $l)))))

  (func $err_simple (param $co i32) (param $cl i32)
    (call $err_prefix (local.get $co) (local.get $cl))
    (call $err_put (i32.const 125))
    (global.set $g_errCount (i32.add (global.get $g_errCount) (i32.const 1))))

  (func $err_short (param $count i32)
    (local $l i32)
    (call $err_prefix (i32.const 2144) (i32.const 9))
    (call $err_putn (i32.const 2336) (i32.const 10))
    (local.set $l (call $fmt_dec (local.get $count)))
    (call $err_putn (global.get $g_fmtPtr) (local.get $l))
    (call $err_put (i32.const 125))
    (global.set $g_errCount (i32.add (global.get $g_errCount) (i32.const 1))))

  (func $err_long (param $xs i32) (param $xe i32)
    (call $err_prefix (i32.const 2176) (i32.const 8))
    (call $err_putn (i32.const 2368) (i32.const 10))
    (call $err_putn (local.get $xs) (i32.sub (local.get $xe) (local.get $xs)))
    (call $err_put (i32.const 93))
    (call $err_put (i32.const 125))
    (global.set $g_errCount (i32.add (global.get $g_errCount) (i32.const 1))))

  ;; ---- field readers (ports of solve.js) -----------------------------------

  ;; Append unquoted text at $g_pos to the open field; sets $g_fEnd.
  (func $read_unquoted
    (local $i i32) (local $seg i32) (local $c i32)
    (local $x i64) (local $m i64) (local $j i32)
    (block $ret
      (loop $lu
        (local.set $seg (global.get $g_pos))
        (local.set $i (local.get $seg))
        (block $sd
          (loop $sl
            ;; SWAR: skip 8 bytes at a time while none is , LF or CR
            (if (i32.le_u (i32.add (local.get $i) (i32.const 8)) (global.get $g_decEnd))
              (then
                (local.set $x (i64.load (local.get $i)))
                (local.set $m
                  (i64.or
                    (i64.or (call $hb (local.get $x) (i64.const 44))
                            (call $hb (local.get $x) (i64.const 10)))
                    (call $hb (local.get $x) (i64.const 13))))
                (if (i64.eqz (local.get $m))
                  (then
                    (local.set $i (i32.add (local.get $i) (i32.const 8)))
                    (br $sl)))
                (local.set $j
                  (i32.add (local.get $i)
                    (i32.wrap_i64 (i64.div_u (i64.ctz (local.get $m)) (i64.const 8)))))
                (local.set $c (i32.load8_u (local.get $j)))
                (if (i32.or
                      (i32.or (i32.eq (local.get $c) (i32.const 44))
                              (i32.eq (local.get $c) (i32.const 10)))
                      (i32.eq (local.get $c) (i32.const 13)))
                  (then (local.set $i (local.get $j)) (br $sd)))
                ;; mask over-reported: that byte is ordinary, step past it
                (local.set $i (i32.add (local.get $j) (i32.const 1)))
                (br $sl)))
            (br_if $sd (i32.ge_u (local.get $i) (global.get $g_decEnd)))
            (local.set $c (i32.load8_u (local.get $i)))
            (br_if $sd
              (i32.or
                (i32.or (i32.eq (local.get $c) (i32.const 44))
                        (i32.eq (local.get $c) (i32.const 10)))
                (i32.eq (local.get $c) (i32.const 13))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $sl)))
        (if (i32.gt_u (local.get $i) (local.get $seg))
          (then (call $span (local.get $seg) (local.get $i))))
        (if (i32.ge_u (local.get $i) (global.get $g_decEnd))
          (then
            (global.set $g_pos (global.get $g_decEnd))
            (global.set $g_fEnd (i32.const 2))
            (return)))
        (local.set $c (i32.load8_u (local.get $i)))
        (if (i32.eq (local.get $c) (i32.const 44))
          (then
            (global.set $g_pos (i32.add (local.get $i) (i32.const 1)))
            (global.set $g_fEnd (i32.const 0))
            (return)))
        (if (i32.eq (local.get $c) (i32.const 10))
          (then
            (global.set $g_pos (i32.add (local.get $i) (i32.const 1)))
            (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
            (global.set $g_fEnd (i32.const 1))
            (return)))
        (if (i32.and (i32.eq (local.get $c) (i32.const 13))
              (i32.and (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (global.get $g_decEnd))
                       (i32.eq (i32.load8_u (i32.add (local.get $i) (i32.const 1))) (i32.const 10))))
          (then
            (global.set $g_pos (i32.add (local.get $i) (i32.const 2)))
            (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
            (global.set $g_fEnd (i32.const 1))
            (return)))
        ;; lone CR: dropped, error, field goes on
        (call $err_simple (i32.const 2048) (i32.const 8))
        (global.set $g_pos (i32.add (local.get $i) (i32.const 1)))
        (br $lu))))

  ;; After a quoted field closes: end it, or append junk (quote_junk when
  ;; anything was actually appended; the error follows any stray_cr the
  ;; junk itself produced, as in solve.js).
  (func $after_quoted
    (local $c i32) (local $vcSnap i32)
    (if (i32.ge_u (global.get $g_pos) (global.get $g_decEnd))
      (then (global.set $g_fEnd (i32.const 2)) (return)))
    (local.set $c (i32.load8_u (global.get $g_pos)))
    (if (i32.eq (local.get $c) (i32.const 44))
      (then
        (global.set $g_pos (i32.add (global.get $g_pos) (i32.const 1)))
        (global.set $g_fEnd (i32.const 0))
        (return)))
    (if (i32.eq (local.get $c) (i32.const 10))
      (then
        (global.set $g_pos (i32.add (global.get $g_pos) (i32.const 1)))
        (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
        (global.set $g_fEnd (i32.const 1))
        (return)))
    (if (i32.and (i32.eq (local.get $c) (i32.const 13))
          (i32.and (i32.lt_u (i32.add (global.get $g_pos) (i32.const 1)) (global.get $g_decEnd))
                   (i32.eq (i32.load8_u (i32.add (global.get $g_pos) (i32.const 1))) (i32.const 10))))
      (then
        (global.set $g_pos (i32.add (global.get $g_pos) (i32.const 2)))
        (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
        (global.set $g_fEnd (i32.const 1))
        (return)))
    (local.set $vcSnap (global.get $g_valChars))
    (call $read_unquoted)
    (if (i32.gt_u (global.get $g_valChars) (local.get $vcSnap))
      (then (call $err_simple (i32.const 2080) (i32.const 10)))))

  ;; Read a quoted field whose opening quote is at $g_pos.
  (func $read_quoted
    (local $open i32) (local $openLine i32) (local $i i32) (local $seg i32)
    (local $c i32) (local $outSave i32) (local $step i32) (local $x i64)
    (local.set $open (global.get $g_pos))
    (local.set $openLine (global.get $g_line))
    (local.set $outSave (global.get $g_out))
    (local.set $i (i32.add (local.get $open) (i32.const 1)))
    (local.set $seg (local.get $i))
    (block $ret
      (loop $lq
        ;; SWAR: skip chunks holding no quote, CR or LF (an LF would need
        ;; a line increment, a quote or CR would need real work)
        (if (i32.le_u (i32.add (local.get $i) (i32.const 8)) (global.get $g_decEnd))
          (then
            (local.set $x (i64.load (local.get $i)))
            (if (i64.eqz
                  (i64.or
                    (i64.or (call $hb (local.get $x) (i64.const 34))
                            (call $hb (local.get $x) (i64.const 13)))
                    (call $hb (local.get $x) (i64.const 10))))
              (then
                (local.set $i (i32.add (local.get $i) (i32.const 8)))
                (br $lq)))))
        (if (i32.ge_u (local.get $i) (global.get $g_decEnd))
          (then
            ;; unterminated: quote is literal, rest re-read as unquoted
            (global.set $g_out (local.get $outSave))
            (global.set $g_line (local.get $openLine))
            (global.set $g_pos (i32.add (local.get $open) (i32.const 1)))
            (call $err_simple (i32.const 2112) (i32.const 18))
            (call $val_byte (i32.const 34))
            (call $read_unquoted)
            (return)))
        (local.set $c (i32.load8_u (local.get $i)))
        (if (i32.eq (local.get $c) (i32.const 34))
          (then
            (if (i32.and (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (global.get $g_decEnd))
                         (i32.eq (i32.load8_u (i32.add (local.get $i) (i32.const 1))) (i32.const 34)))
              (then
                (call $span (local.get $seg) (local.get $i))
                (call $val_byte (i32.const 34))
                (local.set $i (i32.add (local.get $i) (i32.const 2)))
                (local.set $seg (local.get $i))
                (br $lq)))
            (call $span (local.get $seg) (local.get $i))
            (global.set $g_pos (i32.add (local.get $i) (i32.const 1)))
            (call $after_quoted)
            (return)))
        (if (i32.eq (local.get $c) (i32.const 13))
          (then
            (call $span (local.get $seg) (local.get $i))
            (call $val_byte (i32.const 10))
            (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
            (local.set $step
              (if (result i32)
                (i32.and (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (global.get $g_decEnd))
                         (i32.eq (i32.load8_u (i32.add (local.get $i) (i32.const 1))) (i32.const 10)))
                (then (i32.const 2))
                (else (i32.const 1))))
            (local.set $i (i32.add (local.get $i) (local.get $step)))
            (local.set $seg (local.get $i))
            (br $lq)))
        (if (i32.eq (local.get $c) (i32.const 10))
          (then (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lq))))

  ;; ---- PASS A: JSON string decode ------------------------------------------
  (func $hex4 (param $p i32) (result i32)
    (local $v i32) (local $k i32) (local $d i32) (local $dv i32)
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $k) (i32.const 4)))
        (if (i32.ge_u (i32.add (local.get $p) (local.get $k)) (global.get $g_inEnd))
          (then (br $done)))
        (local.set $d (i32.load8_u (i32.add (local.get $p) (local.get $k))))
        (local.set $dv (i32.const 0))
        (if (i32.and (i32.ge_u (local.get $d) (i32.const 48)) (i32.le_u (local.get $d) (i32.const 57)))
          (then (local.set $dv (i32.sub (local.get $d) (i32.const 48)))))
        (if (i32.and (i32.ge_u (local.get $d) (i32.const 97)) (i32.le_u (local.get $d) (i32.const 102)))
          (then (local.set $dv (i32.sub (local.get $d) (i32.const 87)))))
        (if (i32.and (i32.ge_u (local.get $d) (i32.const 65)) (i32.le_u (local.get $d) (i32.const 70)))
          (then (local.set $dv (i32.sub (local.get $d) (i32.const 55)))))
        (local.set $v (i32.add (i32.mul (local.get $v) (i32.const 16)) (local.get $dv)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $lp)))
    (local.get $v))

  (func $decode (param $p i32) (param $len i32)
    (local $rp i32) (local $rend i32) (local $wp i32)
    (local $b i32) (local $c i32) (local $cp i32) (local $ob i32)
    (local $lo i32) (local $adv i32) (local $x i64)
    (local.set $rp (local.get $p))
    (local.set $rend (i32.add (local.get $p) (local.get $len)))
    (global.set $g_inEnd (local.get $rend))
    (local.set $wp (i32.const 18874368))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $rp) (local.get $rend)))
        (if (i32.gt_u (i32.add (local.get $wp) (i32.const 4)) (i32.const 35651584))
          (then (global.set $g_failed (i32.const 1)) (br $done)))
        ;; SWAR: copy clean 8-byte chunks (no backslash anywhere)
        (if (i32.le_u (i32.add (local.get $rp) (i32.const 8)) (local.get $rend))
          (then
            (if (i32.le_u (i32.add (local.get $wp) (i32.const 8)) (i32.const 35651584))
              (then
                (local.set $x (i64.load (local.get $rp)))
                (if (i64.eqz (call $hb (local.get $x) (i64.const 92)))
                  (then
                    (i64.store (local.get $wp) (local.get $x))
                    (local.set $wp (i32.add (local.get $wp) (i32.const 8)))
                    (local.set $rp (i32.add (local.get $rp) (i32.const 8)))
                    (br $lp)))))))
        (local.set $b (i32.load8_u (local.get $rp)))
        (if (i32.ne (local.get $b) (i32.const 92))
          (then
            (i32.store8 (local.get $wp) (local.get $b))
            (local.set $wp (i32.add (local.get $wp) (i32.const 1)))
            (local.set $rp (i32.add (local.get $rp) (i32.const 1)))
            (br $lp)))
        ;; escape sequence
        (if (i32.ge_u (i32.add (local.get $rp) (i32.const 1)) (local.get $rend))
          (then
            (i32.store8 (local.get $wp) (i32.const 92))
            (local.set $wp (i32.add (local.get $wp) (i32.const 1)))
            (local.set $rp (i32.add (local.get $rp) (i32.const 1)))
            (br $lp)))
        (local.set $c (i32.load8_u (i32.add (local.get $rp) (i32.const 1))))
        (if (i32.eq (local.get $c) (i32.const 117))
          (then
            (local.set $cp (call $hex4 (i32.add (local.get $rp) (i32.const 2))))
            (local.set $adv (i32.const 6))
            ;; a high surrogate followed by \uDC00-\uDFFF combines, exactly
            ;; as JSON.parse would build the JS string
            (if (i32.and (i32.ge_u (local.get $cp) (i32.const 55296))
                         (i32.le_u (local.get $cp) (i32.const 56319)))
              (then
                (if (i32.and (i32.le_u (i32.add (local.get $rp) (i32.const 12)) (local.get $rend))
                      (i32.and (i32.eq (i32.load8_u (i32.add (local.get $rp) (i32.const 6))) (i32.const 92))
                               (i32.eq (i32.load8_u (i32.add (local.get $rp) (i32.const 7))) (i32.const 117))))
                  (then
                    (local.set $lo (call $hex4 (i32.add (local.get $rp) (i32.const 8))))
                    (if (i32.and (i32.ge_u (local.get $lo) (i32.const 56320))
                                 (i32.le_u (local.get $lo) (i32.const 57343)))
                      (then
                        (local.set $cp
                          (i32.add (i32.const 65536)
                            (i32.add (i32.shl (i32.sub (local.get $cp) (i32.const 55296)) (i32.const 10))
                                     (i32.sub (local.get $lo) (i32.const 56320)))))
                        (local.set $adv (i32.const 12))))))))
            (local.set $rp (i32.add (local.get $rp) (local.get $adv)))
            (if (i32.lt_u (local.get $cp) (i32.const 128))
              (then
                (i32.store8 (local.get $wp) (local.get $cp))
                (local.set $wp (i32.add (local.get $wp) (i32.const 1))))
              (else (if (i32.lt_u (local.get $cp) (i32.const 2048))
                (then
                  (i32.store8 (local.get $wp)
                    (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))
                  (i32.store8 (i32.add (local.get $wp) (i32.const 1))
                    (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
                  (local.set $wp (i32.add (local.get $wp) (i32.const 2))))
                (else (if (i32.lt_u (local.get $cp) (i32.const 65536))
                  (then
                    (i32.store8 (local.get $wp)
                      (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))
                    (i32.store8 (i32.add (local.get $wp) (i32.const 1))
                      (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))
                    (i32.store8 (i32.add (local.get $wp) (i32.const 2))
                      (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
                    (local.set $wp (i32.add (local.get $wp) (i32.const 3))))
                  (else
                    (i32.store8 (local.get $wp)
                      (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))
                    (i32.store8 (i32.add (local.get $wp) (i32.const 1))
                      (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))
                    (i32.store8 (i32.add (local.get $wp) (i32.const 2))
                      (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))
                    (i32.store8 (i32.add (local.get $wp) (i32.const 3))
                      (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
                    (local.set $wp (i32.add (local.get $wp) (i32.const 4)))))))))
            (br $lp)))
        ;; one-letter escapes (and a defensive default: the letter itself)
        (local.set $ob (local.get $c))
        (if (i32.eq (local.get $c) (i32.const 98)) (then (local.set $ob (i32.const 8))))
        (if (i32.eq (local.get $c) (i32.const 102)) (then (local.set $ob (i32.const 12))))
        (if (i32.eq (local.get $c) (i32.const 110)) (then (local.set $ob (i32.const 10))))
        (if (i32.eq (local.get $c) (i32.const 114)) (then (local.set $ob (i32.const 13))))
        (if (i32.eq (local.get $c) (i32.const 116)) (then (local.set $ob (i32.const 9))))
        (i32.store8 (local.get $wp) (local.get $ob))
        (local.set $wp (i32.add (local.get $wp) (i32.const 1)))
        (local.set $rp (i32.add (local.get $rp) (i32.const 2)))
        (br $lp)))
    (global.set $g_decEnd (local.get $wp))
    (i32.store (i32.const 12) (i32.sub (local.get $wp) (i32.const 18874368))))

  ;; ---- PASS B: CSV parse -----------------------------------------------------
  (func $parse
    (local $c i32) (local $isFirst i32) (local $recStart i32)
    (local $fieldIndex i32) (local $vcSnap i32) (local $f0chars i32)
    (local $k i32)
    ;; BOM: decoded U+FEFF is EF BB BF at the very start
    (global.set $g_pos (i32.const 18874368))
    (if (i32.and (i32.ge_u (global.get $g_decEnd) (i32.const 18874371))
          (i32.and (i32.eq (i32.load8_u (i32.const 18874368)) (i32.const 239))
            (i32.and (i32.eq (i32.load8_u (i32.const 18874369)) (i32.const 187))
                     (i32.eq (i32.load8_u (i32.const 18874370)) (i32.const 191)))))
      (then (global.set $g_pos (i32.const 18874371))))
    (global.set $g_line (i32.const 1))
    (block $recs_done
      (loop $recs
        ;; skip empty lines
        (block $skip_done
          (loop $skip
            (br_if $skip_done (i32.ge_u (global.get $g_pos) (global.get $g_decEnd)))
            (local.set $c (i32.load8_u (global.get $g_pos)))
            (if (i32.eq (local.get $c) (i32.const 10))
              (then
                (global.set $g_pos (i32.add (global.get $g_pos) (i32.const 1)))
                (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
                (br $skip)))
            (if (i32.and (i32.eq (local.get $c) (i32.const 13))
                  (i32.and (i32.lt_u (i32.add (global.get $g_pos) (i32.const 1)) (global.get $g_decEnd))
                           (i32.eq (i32.load8_u (i32.add (global.get $g_pos) (i32.const 1))) (i32.const 10))))
              (then
                (global.set $g_pos (i32.add (global.get $g_pos) (i32.const 2)))
                (global.set $g_line (i32.add (global.get $g_line) (i32.const 1)))
                (br $skip)))
            (br $skip_done)))
        (br_if $recs_done (i32.ge_u (global.get $g_pos) (global.get $g_decEnd)))
        (if (global.get $g_failed) (then (br $recs_done)))
        (if (i32.ge_u (global.get $g_recCount) (i32.const 131072))
          (then (global.set $g_failed (i32.const 1)) (br $recs_done)))
        (local.set $isFirst (i32.eqz (global.get $g_recCount)))
        (global.set $g_recLine (global.get $g_line))
        (global.set $g_recRowNull (i32.and (global.get $g_header) (local.get $isFirst)))
        (global.set $g_recRow (global.get $g_rows))
        (local.set $recStart (global.get $g_out))
        (call $rec_put (i32.const 91))
        (local.set $fieldIndex (i32.const 0))
        (local.set $f0chars (i32.const 0))
        (block $fields_done
          (loop $fields
            (if (global.get $g_failed) (then (br $fields_done)))
            (if (local.get $fieldIndex)
              (then (call $rec_put (i32.const 44))))
            (if (i32.eq (local.get $fieldIndex) (global.get $g_width))
              (then (global.set $g_extraStart (global.get $g_out))))
            (call $rec_put (i32.const 34))
            (if (i32.eqz (local.get $fieldIndex))
              (then (local.set $vcSnap (global.get $g_valChars))))
            (if (i32.and (i32.lt_u (global.get $g_pos) (global.get $g_decEnd))
                         (i32.eq (i32.load8_u (global.get $g_pos)) (i32.const 34)))
              (then (global.set $g_lastQuoted (i32.const 1)) (call $read_quoted))
              (else (global.set $g_lastQuoted (i32.const 0)) (call $read_unquoted)))
            (call $rec_put (i32.const 34))
            (if (i32.eqz (local.get $fieldIndex))
              (then (local.set $f0chars
                (i32.sub (global.get $g_valChars) (local.get $vcSnap)))))
            (local.set $fieldIndex (i32.add (local.get $fieldIndex) (i32.const 1)))
            (if (i32.eq (local.get $fieldIndex) (global.get $g_width))
              (then (global.set $g_endWidth (global.get $g_out))))
            (br_if $fields_done (i32.ne (global.get $g_fEnd) (i32.const 0)))
            (br $fields)))
        (if (global.get $g_failed) (then (br $recs_done)))
        ;; a line left with no characters is no record
        (if (i32.and (i32.eq (local.get $fieldIndex) (i32.const 1))
              (i32.and (i32.eqz (local.get $f0chars)) (i32.eqz (global.get $g_lastQuoted))))
          (then
            (global.set $g_out (local.get $recStart))
            (br $recs)))
        (if (local.get $isFirst)
          (then (global.set $g_width (local.get $fieldIndex)))
          (else
            (if (i32.lt_u (local.get $fieldIndex) (global.get $g_width))
              (then
                (call $err_short (local.get $fieldIndex))
                (local.set $k (local.get $fieldIndex))
                (block $pd
                  (loop $pl
                    (br_if $pd (i32.ge_u (local.get $k) (global.get $g_width)))
                    (call $rec_putn (i32.const 2400) (i32.const 3))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $pl))))
              (else (if (i32.gt_u (local.get $fieldIndex) (global.get $g_width))
                (then
                  (call $err_long (global.get $g_extraStart) (global.get $g_out))
                  (global.set $g_out (global.get $g_endWidth))))))))
        (call $rec_put (i32.const 93))
        (i32.store (i32.add (i32.const 4096) (i32.mul (global.get $g_recCount) (i32.const 8)))
          (local.get $recStart))
        (i32.store (i32.add (i32.const 4100) (i32.mul (global.get $g_recCount) (i32.const 8)))
          (i32.sub (global.get $g_out) (local.get $recStart)))
        (global.set $g_recCount (i32.add (global.get $g_recCount) (i32.const 1)))
        (if (i32.eqz (i32.and (global.get $g_header) (local.get $isFirst)))
          (then (global.set $g_rows (i32.add (global.get $g_rows) (i32.const 1)))))
        (br $recs))))

  ;; ---- entry point -----------------------------------------------------------
  (func (export "transduce") (param $inPtr i32) (param $inLen i32) (param $header i32)
    (global.set $g_failed (i32.const 0))
    (global.set $g_out (i32.const 35651584))
    (global.set $g_err (i32.const 69206016))
    (global.set $g_errCount (i32.const 0))
    (global.set $g_recCount (i32.const 0))
    (global.set $g_rows (i32.const 0))
    (global.set $g_width (i32.const -1))
    (global.set $g_header (local.get $header))
    (global.set $g_valChars (i32.const 0))
    (global.set $g_fEnd (i32.const 2))
    (call $decode (local.get $inPtr) (local.get $inLen))
    (if (i32.eqz (global.get $g_failed)) (then (call $parse)))
    (i32.store (i32.const 0) (global.get $g_failed))
    (i32.store (i32.const 4) (global.get $g_recCount))
    (i32.store (i32.const 8) (i32.sub (global.get $g_err) (i32.const 69206016))))
)
