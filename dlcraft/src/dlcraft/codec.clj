(ns dlcraft.codec
  "Section wire format (docs: SPEC.md section 2/3).  A section blob is exactly what a chunk packet carries for that section."
  (:import [java.nio ByteBuffer]
           [java.security MessageDigest]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

;; ---------------------------------------------------------------------------------------------- numbers
(defn hash2
  "SPEC 4: 64-bit signed arithmetic, result in [0, 2^31)."
  ^long [^long a ^long b ^long s]
  (let [h0 (bit-and (unchecked-add (unchecked-add (unchecked-multiply a 374761393) (unchecked-multiply b 668265263))
                                   (unchecked-multiply s 1274126177))
                    0x7fffffff)
        h1 (bit-and (unchecked-multiply (bit-xor h0 (unsigned-bit-shift-right h0 13)) 1274126177) 0x7fffffff)]
    (bit-xor h1 (unsigned-bit-shift-right h1 16))))

(defn ceillog2 ^long [^long n] (if (<= n 1) 0 (- 64 (Long/numberOfLeadingZeros (dec n)))))
(defn bits-for ^long [^long palette-size] (if (<= palette-size 1) 0 (max 4 (ceillog2 palette-size))))
(defn longs-for ^long [^long bits] (if (zero? bits) 0 (quot (+ 4095 (quot 64 bits)) (quot 64 bits))))

(def ^:const MIN-Y -64)
(def ^:const MIN-SY -4)
(def ^:const MAX-SY 19)

(defn sec-idx ^long [^long x ^long y ^long z]
  (bit-or (bit-shift-left (bit-and y 15) 8) (bit-shift-left (bit-and z 15) 4) (bit-and x 15)))

;; ---------------------------------------------------------------------------------------------- varint
(defn put-varint! [^ByteBuffer b ^long v]
  (loop [v v]
    (if (zero? (bit-and v (bit-not 0x7F)))
      (.put b (unchecked-byte v))
      (do (.put b (unchecked-byte (bit-or (bit-and v 0x7F) 0x80)))
          (recur (unsigned-bit-shift-right v 7))))))

(defn get-varint ^long [^ByteBuffer b]
  (loop [shift 0 acc 0]
    (let [x (long (.get b))
          acc (bit-or acc (bit-shift-left (bit-and x 0x7F) shift))]
      (if (zero? (bit-and x 0x80)) acc (recur (+ shift 7) acc)))))

;; ---------------------------------------------------------------------------------------------- packing
(defn pack-longs
  "entries: int[4096] of palette indices -> packed longs (big-endian bytes)."
  ^bytes [^ints entries ^long bits]
  (if (zero? bits)
    (byte-array 0)
    (let [vpl (quot 64 bits) n (alength entries) nl (longs-for bits)
          out (ByteBuffer/allocate (* 8 nl))]
      (loop [li 0]
        (when (< li nl)
          (let [base (* li vpl)
                end (min n (+ base vpl))
                w (loop [i base acc 0]
                    (if (< i end)
                      (recur (inc i) (bit-or acc (bit-shift-left (long (aget entries i)) (* (- i base) bits))))
                      acc))]
            (.putLong out (* 8 li) (long w))
            (recur (inc li)))))
      (.array out))))

(defn unpack-longs
  "packed longs -> int[4096]"
  ^ints [^bytes data ^long bits]
  (let [out (int-array 4096)]
    (when-not (zero? bits)
      (let [vpl (quot 64 bits) mask (dec (bit-shift-left 1 bits)) bb (ByteBuffer/wrap data)]
        (dotimes [i 4096]
          (let [w (.getLong bb (* 8 (quot i vpl)))]
            (aset out i (unchecked-int (bit-and (unsigned-bit-shift-right w (* (rem i vpl) bits)) mask)))))))
    out))

;; ---------------------------------------------------------------------------------------------- blob
(defrecord Section [^long cnt ^long bits ^ints palette ^bytes data])

(defn blob
  "Serialise a section (SPEC 2)."
  ^bytes [^long cnt ^long bits ^ints palette ^bytes data]
  (let [b (ByteBuffer/allocate (+ 2 1 5 (* 5 (alength palette)) (alength data) 2))]
    (.putShort b (unchecked-short cnt))
    (.put b (unchecked-byte bits))
    (if (zero? bits)
      (put-varint! b (aget palette 0))
      (do (put-varint! b (alength palette))
          (dotimes [i (alength palette)] (put-varint! b (aget palette i)))))
    (.put b data)
    (.put b (byte 0)) (.put b (byte 0))
    (let [n (.position b) out (byte-array n)]
      (.get (.duplicate (.flip b)) out)
      out)))

(defn parse-blob
  "Inverse of blob -> Section (data is a copy of the packed longs)."
  [^bytes bl]
  (let [b (ByteBuffer/wrap bl)
        cnt (bit-and (long (.getShort b)) 0xFFFF)
        bits (bit-and (long (.get b)) 0xFF)
        palette (if (zero? bits)
                  (int-array [(get-varint b)])
                  (let [n (get-varint b) p (int-array n)] (dotimes [i n] (aset p i (unchecked-int (get-varint b)))) p))
        nl (longs-for bits)
        data (byte-array (* 8 nl))]
    (.get b data)
    (->Section cnt bits palette data)))

(defn blob-entry-at
  "Palette state at section index i, straight from the blob bytes (no copies)."
  ^long [^bytes bl ^long i]
  (let [b (ByteBuffer/wrap bl)
        bits (bit-and (long (.get b 2)) 0xFF)]
    (.position b 3)
    (if (zero? bits)
      (get-varint b)
      (let [n (get-varint b)
            _ (.position b (+ (.position b) 0))
            pal-start (.position b)
            ;; skip n varints, remember where each begins? palettes are tiny: read them
            pal (long-array n)]
        (dotimes [k n] (aset pal k (get-varint b)))
        (let [data-off (.position b)
              vpl (quot 64 bits)
              w (.getLong b (+ data-off (* 8 (quot i vpl))))
              e (bit-and (unsigned-bit-shift-right w (* (rem i vpl) bits)) (dec (bit-shift-left 1 bits)))]
          (aget pal e))))))

(defn blob-palette
  "[block-count palette-vector] from the header only."
  [^bytes bl]
  (let [b (ByteBuffer/wrap bl)
        cnt (bit-and (long (.getShort b)) 0xFFFF)
        bits (bit-and (long (.get b)) 0xFF)]
    (if (zero? bits)
      [cnt [(get-varint b)]]
      (let [n (get-varint b)] [cnt (vec (repeatedly n #(get-varint b)))]))))

(defn sha256 ^bytes [^bytes bs] (.digest (MessageDigest/getInstance "SHA-256") bs))

(defn hex ^String [^bytes bs] (apply str (map #(format "%02x" (bit-and (long %) 0xff)) bs)))
