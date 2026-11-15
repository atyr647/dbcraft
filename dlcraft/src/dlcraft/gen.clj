(ns dlcraft.gen
  "Terrain generator, SPEC 4.  Integer arithmetic only so that PostgreSQL computes exactly the same blocks."
  (:require [dlcraft.codec :as c :refer [hash2]]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn oct ^long [^long x ^long z ^long shift ^long seed]
  (let [cs (bit-shift-left 1 shift) gx (bit-shift-right x shift) gz (bit-shift-right z shift)
        fx (bit-and x (dec cs)) fz (bit-and z (dec cs))
        n00 (bit-and (hash2 gx gz seed) 4095) n10 (bit-and (hash2 (inc gx) gz seed) 4095)
        n01 (bit-and (hash2 gx (inc gz) seed) 4095) n11 (bit-and (hash2 (inc gx) (inc gz) seed) 4095)]
    (bit-shift-right (+ (* n00 (- cs fx) (- cs fz)) (* n10 fx (- cs fz)) (* n01 (- cs fx) fz) (* n11 fx fz)) (* 2 shift))))

(defn height ^long [^long x ^long z]
  (+ 52 (bit-shift-right (* (oct x z 6 1337) 32) 12) (bit-shift-right (* (oct x z 4 1338) 10) 12)))

(defn block-at ^long [^long x ^long y ^long z ^long h]
  (cond
    (== y -64) 4
    (> y h) (if (<= y 62) 6 0)
    (== y h) (if (<= h 63) 5 2)
    (>= y (- h 3)) (cond (<= h 63) 5
                         (and (== y (dec h)) (zero? (bit-and (hash2 x z 7) 31))) 14
                         :else 3)
    :else (let [r (rem (hash2 (+ x (* y 4099)) (- z (* y 7919)) 11) 1024)]
            (cond (< r 10) 15
                  (and (< r 15) (< y 32)) 16
                  (and (== r 15) (< y -16)) 17
                  :else 1))))

(defn column-heights
  "int[256] indexed (z&15)*16 + (x&15) for chunk (cx, cz)."
  ^ints [^long cx ^long cz]
  (let [h (int-array 256)]
    (dotimes [i 256]
      (aset h i (unchecked-int (height (+ (* cx 16) (bit-and i 15)) (+ (* cz 16) (bit-shift-right i 4))))))
    h))


(defn count-air ^long [^ints states]
  (loop [i 0 n 0] (if (< i 4096) (recur (inc i) (if (zero? (aget states i)) (inc n) n)) n)))

(defn gen-section
  "-> [blob-bytes cnt bits palette]  for one section of a chunk, given its column heights."
  [^long cx ^long cz ^long sy ^ints heights]
  (let [states (int-array 4096)
        present (boolean-array 32)
        y0 (* sy 16)]
    (dotimes [i 4096]
      (let [lx (bit-and i 15) lz (bit-and (bit-shift-right i 4) 15) ly (bit-shift-right i 8)
            h (aget heights (+ (* lz 16) lx))
            s (block-at (+ (* cx 16) lx) (+ y0 ly) (+ (* cz 16) lz) h)]
        (aset states i (unchecked-int s))
        (aset present s true)))
    (let [pal (int-array (filter #(aget present %) (range 32)))
          bits (c/bits-for (alength pal))
          cnt (- 4096 (count-air states))]
      (if (zero? bits)
        {:cnt cnt :bits 0 :palette pal :data (byte-array 0)}
        (let [rank (int-array 32)
              _ (dotimes [k (alength pal)] (aset rank (aget pal k) k))
              idx (int-array 4096)]
          (dotimes [i 4096] (aset idx i (aget rank (aget states i))))
          {:cnt cnt :bits bits :palette pal :data (c/pack-longs idx bits)})))))
