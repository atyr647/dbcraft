(ns dlcraft.world
  "World storage and edits on LMDB (SPEC 2, 3, 5).  `kv` is the Datalog connection's KV handle, or a transaction handle inside
  `datalevin.core/with-transaction-kv`, so any function here can run inside one big atomic transaction."
  (:require [datalevin.core :as d]
            [dlcraft.codec :as c]
            [dlcraft.gen :as g]
            [dlcraft.store :as st :refer [skey ckey]])
  (:import [java.nio ByteBuffer]
           [java.util ArrayList Arrays]
           [java.util.concurrent.atomic AtomicLong]
           [dlcraft.codec Section]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

;; ---------------------------------------------------------------------------------------------- raw access
(defn- get-blob ^bytes [kv ^long cx ^long cz ^long sy]
  (d/get-value kv "sect" (skey cx cz sy) :bytes :bytes))

(defn- put-op [dbi ^bytes k ^bytes v] [:put dbi k v])

(defn chunk-version
  "nil if the chunk does not exist"
  [kv ^long cx ^long cz]
  (when-let [^bytes v (d/get-value kv "chunk" (ckey cx cz) :bytes :bytes)]
    (.getLong (ByteBuffer/wrap v) 0)))

(defn- version-bytes ^bytes [^long v] (.array (.putLong (ByteBuffer/allocate 8) v)))

(defn chunk-exists? [kv ^long cx ^long cz] (some? (d/get-value kv "chunk" (ckey cx cz) :bytes :bytes)))

;; ---------------------------------------------------------------------------------------------- generation
(defn gen-chunk-ops
  "Transaction ops that create chunk (cx, cz), nil if it exists."
  [kv ^long cx ^long cz]
  (when-not (chunk-exists? kv cx cz)
    (let [h (g/column-heights cx cz)]
      (cons [:put "chunk" (ckey cx cz) (version-bytes 0) :bytes :bytes]
            (for [sy (range c/MIN-SY (inc c/MAX-SY))]
              (let [{:keys [cnt bits palette data]} (g/gen-section cx cz sy h)]
                [:put "sect" (skey cx cz sy) (c/blob cnt bits palette data) :bytes :bytes]))))))

(defn gen-chunk! [kv ^long cx ^long cz]
  (when-let [ops (gen-chunk-ops kv cx cz)]
    (d/transact-kv kv ops)
    true))

(defn gen-area!
  "Generate the inclusive chunk rectangle; one transaction per chunk-row batch of `batch` chunks.  Returns the number generated."
  ([kv cx0 cz0 cx1 cz1] (gen-area! kv cx0 cz0 cx1 cz1 16))
  ([kv cx0 cz0 cx1 cz1 batch]
   (let [chunks (for [cx (range cx0 (inc cx1)) cz (range cz0 (inc cz1))] [cx cz])
         n (volatile! 0)]
     (doseq [part (partition-all batch chunks)]
       (let [ops (doall (mapcat (fn [[cx cz]] (gen-chunk-ops kv cx cz)) part))]
         (when (seq ops)
           (d/transact-kv kv ops)
           (vswap! n + (count (filter #(= "chunk" (second %)) ops))))))
     @n)))

;; ---------------------------------------------------------------------------------------------- reads
(defn get-block
  ^long [kv ^long x ^long y ^long z]
  (if (or (< y -64) (> y 319))
    0
    (let [bl (get-blob kv (bit-shift-right x 4) (bit-shift-right z 4) (bit-shift-right y 4))]
      (if bl (c/blob-entry-at bl (c/sec-idx x y z)) 0))))

;; ---------------------------------------------------------------------------------------------- editing a section
(defn- entry-at ^long [^bytes data ^long bits ^long i]
  (let [vpl (quot 64 bits)
        w (.getLong (ByteBuffer/wrap data) (* 8 (quot i vpl)))]
    (bit-and (unsigned-bit-shift-right w (* (rem i vpl) bits)) (dec (bit-shift-left 1 bits)))))

(defn- set-entry! [^bytes data ^long bits ^long i ^long e]
  (let [vpl (quot 64 bits) off (* 8 (quot i vpl)) sh (* (rem i vpl) bits)
        mask (bit-shift-left (dec (bit-shift-left 1 bits)) sh)
        bb (ByteBuffer/wrap data)
        w (.getLong bb off)]
    (.putLong bb off (bit-or (bit-and w (bit-not mask)) (bit-shift-left e sh)))))

(deftype Edit [^long idx ^long state ^long order])  ; order = position in the caller's array (for event ordering)

(defn edit-section
  "Apply [idx state] edits in order to the blob.  Returns nil if nothing changed, else
  {:blob new-blob :changed [[idx old new order] ...]} (SPEC 3)."
  [^bytes bl edits]
  (let [^Section sec (c/parse-blob bl)
        pal (ArrayList.)
        _ (dotimes [i (alength ^ints (:palette sec))] (.add pal (aget ^ints (:palette sec) i)))
        bits (long (:bits sec))
        ^bytes data (:data sec)
        cnt (long (:cnt sec))
        changed (ArrayList.)]
    (loop [es (seq edits) bits bits data data cnt cnt]
      (if es
        (let [^Edit e (first es)
              idx (.idx e) s (.state e)
              old (if (zero? bits) (long (.get pal 0)) (long (.get pal (int (entry-at data bits idx)))))]
          (if (== old s)
            (recur (next es) bits data cnt)
            (let [pi0 (.indexOf pal (int s))
                  pi (if (neg? pi0) (do (.add pal (int s)) (dec (.size pal))) pi0)
                  size (.size pal)
                  need-repack (or (zero? bits) (> size (bit-shift-left 1 bits)))
                  bits' (if need-repack (c/bits-for size) bits)
                  data' (if need-repack
                          (let [entries (if (zero? bits) (int-array 4096) (c/unpack-longs data bits))]
                            (c/pack-longs entries bits'))
                          data)]
              (set-entry! data' bits' idx pi)
              (.add changed (long-array [idx old s (.order e)]))
              (recur (next es) bits' data' (+ cnt (if (zero? s) 0 1) (if (zero? old) 0 -1))))))
        (when-not (.isEmpty changed)
          (let [palette (int-array pal)]
            {:blob (c/blob cnt bits palette data) :changed (vec changed)}))))))

(defn fill-section-edit
  "Fill the box [lx0..lx1]x[ly0..ly1]x[lz0..lz1] (section-local, inclusive) with `state`.  Returns nil if nothing changed, else {:blob :n}."
  [^bytes bl box ^long state]
  (let [^longs box box
        lx0 (aget box 0) lx1 (aget box 1) ly0 (aget box 2) ly1 (aget box 3) lz0 (aget box 4) lz1 (aget box 5)
        whole (and (== lx0 0) (== lx1 15) (== ly0 0) (== ly1 15) (== lz0 0) (== lz1 15))
        ^Section sec (c/parse-blob bl)
        ^ints pal0 (:palette sec) bits (long (:bits sec))
        ^ints entries (if (zero? bits) (int-array 4096) (c/unpack-longs (:data sec) bits))
        ;; how many blocks in the box differ from state
        n (loop [y ly0 acc 0]
            (if (<= y ly1)
              (recur (inc y)
                     (loop [z lz0 acc acc]
                       (if (<= z lz1)
                         (recur (inc z)
                                (loop [x lx0 acc acc]
                                  (if (<= x lx1)
                                    (recur (inc x) (if (== (long (aget pal0 (aget entries (c/sec-idx x y z)))) state) acc (inc acc)))
                                    acc)))
                         acc)))
              acc))]
    (when (pos? n)
      (if whole
        {:blob (c/blob (if (zero? state) 0 4096) 0 (int-array [state]) (byte-array 0)) :n n}
        (let [pal (ArrayList.)
              _ (dotimes [i (alength pal0)] (.add pal (aget pal0 i)))
              pi0 (.indexOf pal (int state))
              pi (if (neg? pi0) (do (.add pal (int state)) (dec (.size pal))) pi0)
              size (.size pal)
              bits' (if (or (zero? bits) (> size (bit-shift-left 1 bits))) (c/bits-for size) bits)]
          (loop [y ly0]
            (when (<= y ly1)
              (loop [z lz0]
                (when (<= z lz1)
                  (loop [x lx0]
                    (when (<= x lx1)
                      (aset entries (c/sec-idx x y z) (unchecked-int pi))
                      (recur (inc x))))
                  (recur (inc z))))
              (recur (inc y))))
          ;; recount non-air
          (let [cnt (loop [i 0 k 0] (if (< i 4096) (recur (inc i) (if (zero? (long (.get pal (aget entries i)))) k (inc k))) k))]
            {:blob (c/blob cnt bits' (int-array pal) (c/pack-longs entries bits')) :n n}))))))

;; ---------------------------------------------------------------------------------------------- events (SPEC 5: the block-event queue)
(def ^:const EV-BLOCK 0)
(def ^:const EV-FILL 1)

(defn- ev-bytes ^bytes [kind x y z old new cnt]
  (let [bb (ByteBuffer/allocate 25)]
    (.put bb (unchecked-byte (long kind))) (.putInt bb (unchecked-int (long x))) (.putInt bb (unchecked-int (long y))) (.putInt bb (unchecked-int (long z)))
    (.putInt bb (unchecked-int (long old))) (.putInt bb (unchecked-int (long new))) (.putInt bb (unchecked-int (long cnt)))
    (.array bb)))

(defn- next-seq ^long [^AtomicLong a] (.incrementAndGet a))

;; ---------------------------------------------------------------------------------------------- writes
(defn- bump-version-op [kv ^long cx ^long cz]
  (let [v (chunk-version kv cx cz)]
    [:put "chunk" (ckey cx cz) (version-bytes (inc (long v))) :bytes :bytes]))

(defn set-blocks!
  "SPEC 5 set_blocks: arrays of equal length, applied in array order, each section read and written once.  `env` is the st/Env (for the event
  sequence); `kv` the KV handle to use (the env's or a transaction's).  Returns the number of blocks changed."
  [^dlcraft.store.Env env kv xs ys zs states]
  (let [xs (vec xs) ys (vec ys) zs (vec zs) states (vec states) n (count xs)
        groups (java.util.LinkedHashMap.)]
    (dotimes [i n]
      (let [x (long (nth xs i)) y (long (nth ys i)) z (long (nth zs i)) s (long (nth states i))]
        (when (and (>= y -64) (<= y 319))
          (let [k [(bit-shift-right x 4) (bit-shift-right z 4) (bit-shift-right y 4)]
                ^ArrayList l (or (.get groups k) (let [l (ArrayList.)] (.put groups k l) l))]
            (.add l (->Edit (c/sec-idx x y z) s i))))))
    (let [ops (ArrayList.)
          evs (ArrayList.)
          chunks-changed (java.util.LinkedHashSet.)]
      (doseq [^java.util.Map$Entry e (.entrySet groups)]
        (let [[cx cz sy] (.getKey e)
              bl (get-blob kv cx cz sy)]
          (when bl
            (when-let [{:keys [blob changed]} (edit-section bl (.getValue e))]
              (.add ops [:put "sect" (skey cx cz sy) blob :bytes :bytes])
              (.add chunks-changed [cx cz])
              (doseq [^longs ch changed]
                (let [idx (aget ch 0)
                      x (+ (* cx 16) (bit-and idx 15)) z (+ (* cz 16) (bit-and (bit-shift-right idx 4) 15)) y (+ (* sy 16) (bit-shift-right idx 8))]
                  (.add evs [(aget ch 3) (ev-bytes EV-BLOCK x y z (aget ch 1) (aget ch 2) 0)])))))))
      (doseq [[cx cz] chunks-changed] (.add ops (bump-version-op kv cx cz)))
      (doseq [[_ b] (sort-by first evs)] (.add ops [:put "evq" (next-seq (:evseq env)) b :long :bytes]))
      (when-not (.isEmpty ops) (d/transact-kv kv ops))
      (count evs))))

(defn set-block!
  "SPEC 5 set_block.  Fast single-block path."
  [^dlcraft.store.Env env kv x y z state]
  (let [x (long x) y (long y) z (long z) state (long state)]
  (if (or (< y -64) (> y 319))
    false
    (let [cx (bit-shift-right x 4) cz (bit-shift-right z 4) sy (bit-shift-right y 4)
          bl (get-blob kv cx cz sy)]
      (if-not bl
        false
        (if-let [{:keys [blob changed]} (edit-section bl [(->Edit (c/sec-idx x y z) state 0)])]
          (let [^longs ch (first changed)]
            (d/transact-kv kv [[:put "sect" (skey cx cz sy) blob :bytes :bytes]
                               (bump-version-op kv cx cz)
                               [:put "evq" (next-seq (:evseq env)) (ev-bytes EV-BLOCK x y z (aget ch 1) (aget ch 2) 0) :long :bytes]])
            true)
          false))))))

(defn fill!
  "SPEC 5 fill.  Returns the number of blocks changed."
  [^dlcraft.store.Env env kv x1 y1 z1 x2 y2 z2 state]
  (let [state (long state)
        xa (min (long x1) (long x2)) xb (max (long x1) (long x2))
        ya (max -64 (min (long y1) (long y2))) yb (min 319 (max (long y1) (long y2)))
        za (min (long z1) (long z2)) zb (max (long z1) (long z2))
        ops (ArrayList.) evs (ArrayList.) chunks (java.util.LinkedHashSet.)
        total (volatile! 0)]
    (when (<= ya yb)
      (doseq [cx (range (bit-shift-right xa 4) (inc (bit-shift-right xb 4)))
              cz (range (bit-shift-right za 4) (inc (bit-shift-right zb 4)))
              sy (range (bit-shift-right ya 4) (inc (bit-shift-right yb 4)))]
        (when-let [bl (get-blob kv cx cz sy)]
          (let [x0 (max xa (* cx 16)) x1' (min xb (+ (* cx 16) 15))
                y0 (max ya (* sy 16)) y1' (min yb (+ (* sy 16) 15))
                z0 (max za (* cz 16)) z1' (min zb (+ (* cz 16) 15))]
            (when-let [{:keys [blob n]} (fill-section-edit bl (long-array [(- x0 (* cx 16)) (- x1' (* cx 16)) (- y0 (* sy 16)) (- y1' (* sy 16))
                                                                              (- z0 (* cz 16)) (- z1' (* cz 16))]) state)]
              (.add ops [:put "sect" (skey cx cz sy) blob :bytes :bytes])
              (.add chunks [cx cz])
              (vswap! total + n)
              (.add evs (ev-bytes EV-FILL x0 y0 z0 -1 state n)))))))
    (doseq [[cx cz] chunks] (.add ops (bump-version-op kv cx cz)))
    (doseq [b evs] (.add ops [:put "evq" (next-seq (:evseq env)) b :long :bytes]))
    (when-not (.isEmpty ops) (d/transact-kv kv ops))
    @total))

;; ---------------------------------------------------------------------------------------------- chunk packets
(defn chunk-payload
  "Concatenation of the 24 section blobs, nil if the chunk does not exist."
  ^bytes [kv ^long cx ^long cz]
  (let [rows (d/get-range kv "sect" [:closed (skey cx cz c/MIN-SY) (skey cx cz c/MAX-SY)] :bytes :bytes true)]
    (when (seq rows)
      (let [total (reduce + (map #(alength ^bytes %) rows))
            out (ByteBuffer/allocate total)]
        (doseq [^bytes b rows] (.put out b))
        (.array out)))))

(defn- frame ^bytes [^long cx ^long cz ^bytes payload]
  (let [body-len (+ 1 4 4 (alength payload))
        out (ByteBuffer/allocate (+ 5 body-len))]
    (c/put-varint! out body-len)
    (.put out (byte 0x2c)) (.putInt out (unchecked-int cx)) (.putInt out (unchecked-int cz)) (.put out payload)
    (let [a (byte-array (.position out))] (.get (.duplicate (.flip out)) a) a)))

(defn build-chunk-packet ^bytes [kv ^long cx ^long cz]
  (when-let [p (chunk-payload kv cx cz)] (frame cx cz p)))

(defn chunk-packet
  "Cached per chunk and version, rebuilt when stale (SPEC 5).  Writes the cache through `kv` (a transaction handle or the env's)."
  ^bytes [kv ^long cx ^long cz]
  (when-let [v (chunk-version kv cx cz)]
    (let [^bytes cached (d/get-value kv "cache" (ckey cx cz) :bytes :bytes)]
      (if (and cached (== (.getLong (ByteBuffer/wrap cached) 0) (long v)))
        (Arrays/copyOfRange cached 8 (alength cached))
        (let [^bytes pk (build-chunk-packet kv cx cz)
              out (ByteBuffer/allocate (+ 8 (alength pk)))]
          (.putLong out (long v)) (.put out pk)
          (d/transact-kv kv "cache" [[:put (ckey cx cz) (.array out)]] :bytes :bytes)
          pk)))))

;; ---------------------------------------------------------------------------------------------- hashing and analytics
(defn world-hash
  "SPEC 5 world_hash: sha256 of i32 cx, i32 cz, i16 sy, blob for every section in numeric key order."
  ^bytes [kv]
  (let [md (java.security.MessageDigest/getInstance "SHA-256")]
    (doseq [[^bytes k ^bytes v] (d/get-range kv "sect" [:all] :bytes :bytes false)]
      (let [bb (ByteBuffer/wrap k)
            hdr (ByteBuffer/allocate 10)]
        (.putInt hdr (- (.getInt bb 0) 2147483648)) (.putInt hdr (- (.getInt bb 4) 2147483648)) (.putShort hdr (unchecked-short (- (bit-and (.getShort bb 8) 0xFFFF) 32768)))
        (.update md (.array hdr)) (.update md v)))
    (.digest md)))

(defn count-states
  "{state n} over the column rectangle, all y, generated chunks only."
  [kv x1 z1 x2 z2]
  (let [x1 (long x1) z1 (long z1) x2 (long x2) z2 (long z2) tally (long-array 32)]
    (doseq [cx (range (bit-shift-right x1 4) (inc (bit-shift-right x2 4)))
            cz (range (bit-shift-right z1 4) (inc (bit-shift-right z2 4)))]
      (let [full? (and (<= x1 (* cx 16)) (>= x2 (+ (* cx 16) 15)) (<= z1 (* cz 16)) (>= z2 (+ (* cz 16) 15)))
            rows (d/get-range kv "sect" [:closed (skey cx cz c/MIN-SY) (skey cx cz c/MAX-SY)] :bytes :bytes true)]
        (doseq [^bytes bl rows]
          (let [^Section sec (c/parse-blob bl) ^ints pal (:palette sec) bits (:bits sec)]
            (if (zero? (long bits))
              (if full?
                (aset tally (aget pal 0) (+ (aget tally (aget pal 0)) 4096))
                (let [w (- (inc (min x2 (+ (* cx 16) 15))) (max x1 (* cx 16)))
                      h (- (inc (min z2 (+ (* cz 16) 15))) (max z1 (* cz 16)))]
                  (aset tally (aget pal 0) (long (+ (aget tally (aget pal 0)) (* 16 (long w) (long h)))))))
              (let [^ints entries (c/unpack-longs (:data sec) bits)]
                (if full?
                  (dotimes [i 4096] (let [s (aget pal (aget entries i))] (aset tally s (inc (aget tally s)))))
                  (dotimes [i 4096]
                    (let [x (+ (* cx 16) (bit-and i 15)) z (+ (* cz 16) (bit-and (bit-shift-right i 4) 15))]
                      (when (and (>= x x1) (<= x x2) (>= z z1) (<= z z2))
                        (let [s (aget pal (aget entries i))] (aset tally s (inc (aget tally s))))))))))))))
    (into (sorted-map) (for [s (range 32) :when (pos? (aget tally s))] [s (aget tally s)]))))

(defn find-state
  "Positions [x y z] holding `state` in the column rectangle, ordered by (x, y, z).  Sections whose palette lacks the state are skipped from the header."
  [kv state x1 z1 x2 z2]
  (let [state (long state) x1 (long x1) z1 (long z1) x2 (long x2) z2 (long z2) out (ArrayList.)]
    (doseq [cx (range (bit-shift-right x1 4) (inc (bit-shift-right x2 4)))
            cz (range (bit-shift-right z1 4) (inc (bit-shift-right z2 4)))]
      (doseq [[^bytes k ^bytes bl] (d/get-range kv "sect" [:closed (skey cx cz c/MIN-SY) (skey cx cz c/MAX-SY)] :bytes :bytes false)]
        (let [[_ pal] (c/blob-palette bl)]
          (when (some #(== (long %) state) pal)
            (let [sy (- (bit-and (.getShort (ByteBuffer/wrap k) 8) 0xFFFF) 32768)
                  ^Section sec (c/parse-blob bl)
                  ^ints entries (if (zero? (long (:bits sec))) (int-array 4096) (c/unpack-longs (:data sec) (:bits sec)))
                  ^ints p (:palette sec)]
              (dotimes [i 4096]
                (when (== (aget p (aget entries i)) state)
                  (let [x (+ (* cx 16) (bit-and i 15)) z (+ (* cz 16) (bit-and (bit-shift-right i 4) 15)) y (+ (* sy 16) (bit-shift-right i 8))]
                    (when (and (>= x x1) (<= x x2) (>= z z1) (<= z z2)) (.add out [x y z]))))))))))
    (vec (sort out))))

(defn drain-block-events!
  "Test helper: returns and removes the pending events as [kind x y z old new cnt]."
  [kv]
  (let [rows (d/get-range kv "evq" [:all] :long :bytes false)]
    (d/transact-kv kv "evq" (for [[k _] rows] [:del k]) :long)
    (for [[_ ^bytes b] rows]
      (let [bb (ByteBuffer/wrap b)] [(.get bb) (.getInt bb) (.getInt bb) (.getInt bb) (.getInt bb) (.getInt bb) (.getInt bb)]))))
