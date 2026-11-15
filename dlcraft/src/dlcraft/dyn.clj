(ns dlcraft.dyn
  "SPEC 7: scheduled-tick queue (a sorted LMDB DBI keyed [due seq]), water spread, random ticks."
  (:require [datalevin.core :as d]
            [dlcraft.codec :as c :refer [hash2]]
            [dlcraft.store :as st :refer [skey]]
            [dlcraft.world :as w])
  (:import [java.nio ByteBuffer]
           [java.util ArrayList HashMap TreeMap]
           [dlcraft.codec Section]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(defn- qkey ^bytes [^long due ^long seq] (.array (.putLong (.putLong (ByteBuffer/allocate 16) due) seq)))
(defn- qval ^bytes [^long x ^long y ^long z] (.array (.putInt (.putInt (.putInt (ByteBuffer/allocate 12) (unchecked-int x)) (unchecked-int y)) (unchecked-int z))))

(defn reset-sched! [^dlcraft.store.Env env] (d/clear-dbi (:kv env) "sched"))

(defn sched-ops [^dlcraft.store.Env env due xs ys zs]
  (let [xs (vec xs) ys (vec ys) zs (vec zs)]
  (for [i (range (count xs))]
    [:put "sched" (qkey (long due) (.incrementAndGet ^java.util.concurrent.atomic.AtomicLong (:evseq env))) (qval (nth xs i) (nth ys i) (nth zs i)) :bytes :bytes])))

(defn sched-add-bulk! [^dlcraft.store.Env env kv due xs ys zs]
  (d/transact-kv kv (vec (sched-ops env due xs ys zs))))

(defn sched-add! [env kv due x y z] (sched-add-bulk! env kv due [x] [y] [z]))

(defn sched-size [kv] (d/range-count kv "sched" [:all] :bytes))

(def ^:private HORIZ [[1 0] [-1 0] [0 1] [0 -1]])

(defn dyn-step!
  "SPEC 7 dyn_step.  Returns the number of blocks set."
  [^dlcraft.store.Env env kv ^long now]
  (let [due (d/get-range kv "sched" [:closed (qkey 0 0) (qkey now Long/MAX_VALUE)] :bytes :bytes false)]
    (if (empty? due)
      0
      (let [pos (java.util.LinkedHashSet.)
            _ (doseq [[_ ^bytes v] due] (let [bb (ByteBuffer/wrap v)] (.add pos [(long (.getInt bb 0)) (long (.getInt bb 4)) (long (.getInt bb 8))])))
            cand (HashMap.)
            offer (fn [k ^long lvl] (let [old (.get cand k)] (when (or (nil? old) (< lvl (long old))) (.put cand k lvl))))]
        (doseq [[x y z] pos]
          (let [s (w/get-block kv x y z)]
            (when (and (>= s 6) (<= s 13))
              (let [l (- s 6)]
                (when (< l 7)
                  (doseq [[dx dz] HORIZ]
                    (when (zero? (w/get-block kv (+ x dx) y (+ z dz))) (offer [(+ x dx) y (+ z dz)] (inc l)))))
                (when (and (> y -64) (zero? (w/get-block kv x (dec y) z))) (offer [x (dec y) z] 1))))))
        (let [sorted (sort-by (fn [[[x y z] _]] [x z y]) cand)
              xs (mapv (fn [[[x _ _] _]] x) sorted) ys (mapv (fn [[[_ y _] _]] y) sorted) zs (mapv (fn [[[_ _ z] _]] z) sorted)
              sts (mapv (fn [[_ l]] (+ 6 (long l))) sorted)]
          (d/transact-kv kv (vec (for [[k _] due] [:del "sched" k :bytes])))
          (w/set-blocks! env kv xs ys zs sts)
          (when (seq xs) (sched-add-bulk! env kv (+ now 5) xs ys zs))
          (count xs))))))

(defn random-ticks!
  "SPEC 7 random_ticks.  Returns the number of blocks changed."
  [^dlcraft.store.Env env kv now cx0 cz0 cx1 cz1]
  (let [now (long now) picks (ArrayList.)]
    (doseq [cx (range cx0 (inc (long cx1))) cz (range cz0 (inc (long cz1)))]
      (doseq [[^bytes k ^bytes bl] (d/get-range kv "sect" [:closed (skey cx cz c/MIN-SY) (skey cx cz c/MAX-SY)] :bytes :bytes false)]
        (let [cnt (bit-and (long (.getShort (ByteBuffer/wrap bl) 0)) 0xFFFF)]
          (when (pos? cnt)
            (let [sy (- (bit-and (long (.getShort (ByteBuffer/wrap k) 8)) 0xFFFF) 32768)]
              (dotimes [kk 3]
                (let [i (bit-and (hash2 (+ (* cx 64) sy 4) cz (+ (* now 3) kk)) 4095)
                      x (+ (* cx 16) (bit-and i 15)) z (+ (* cz 16) (bit-and (bit-shift-right i 4) 15)) y (+ (* sy 16) (bit-shift-right i 8))]
                  ;; dirt pick: same-section read straight from the blob already in hand
                  (when (== 3 (c/blob-entry-at bl i))
                    (.add picks [x y z])))))))))
    (let [chosen (ArrayList.)]
      (doseq [[x y z] picks]
        (when (and (zero? (w/get-block kv x (inc y) z))
                   (or (== 2 (w/get-block kv (inc x) y z)) (== 2 (w/get-block kv (dec x) y z))
                       (== 2 (w/get-block kv x y (inc z))) (== 2 (w/get-block kv x y (dec z)))))
          (.add chosen [x y z])))
      (if (.isEmpty chosen)
        0
        (w/set-blocks! env kv (mapv first chosen) (mapv second chosen) (mapv #(nth % 2) chosen) (repeat (.size chosen) 2))))))
