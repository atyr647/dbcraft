(ns dlcraft.workload
  "Deterministic inputs, identical for both engines (everything is a pure function of integers)."
  (:require [dlcraft.codec :as c :refer [hash2]])
  (:import [java.nio ByteBuffer]
           [java.security MessageDigest]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

;; ---------------------------------------------------------------------------------------------- players
(defn start-xz
  "start position of player `eid` in a square world of `side` chunks (blocks), SPEC-independent but fixed"
  [^long eid ^long side]
  (let [span (* side 16 1000)]
    [(/ (double (rem (hash2 eid 1 99) span)) 1000.0) (/ (double (rem (hash2 eid 2 99) span)) 1000.0)]))

(defn init-mirror
  "the harness's own copy of every player's pose (it computes the next move from it)"
  [n side]
  (let [x (double-array n) y (double-array n) z (double-array n) yaw (float-array n) pitch (float-array n)]
    (dotimes [i n]
      (let [[px pz] (start-xz (inc i) side)]
        (aset x i px) (aset y i 80.0) (aset z i pz) (aset yaw i (float 0)) (aset pitch i (float 0))))
    {:n n :x x :y y :z z :yaw yaw :pitch pitch}))

(defn move-payload ^bytes [x y z yaw pitch]
  (let [bb (ByteBuffer/allocate 34)]
    (.put bb (byte 0x1d)) (.putDouble bb (double x)) (.putDouble bb (double y)) (.putDouble bb (double z)) (.putFloat bb (float yaw)) (.putFloat bb (float pitch)) (.put bb (byte 1))
    (.array bb)))

(defn tick-moves
  "Advances the mirror for tick `t` and returns [[conn payload] ...] for the players that send a move packet.
  A move that the engines must reject (more than 10 blocks) is sent now and then and does NOT advance the mirror."
  [{:keys [^long n ^doubles x ^doubles y ^doubles z ^floats yaw ^floats pitch]} ^long t ^double frac]
  (let [out (java.util.ArrayList.)
        thresh (long (* frac 100))]
    (dotimes [i n]
      (let [eid (inc i)]
        (when (< (rem (hash2 eid t 77) 100) thresh)
          (if (zero? (rem (hash2 eid t 88) 2000))
            (.add out [eid (move-payload (+ (aget x i) 11.5) (aget y i) (aget z i) (aget yaw i) (aget pitch i))])   ; rejected
            (let [dx (/ (double (- (rem (hash2 eid t 5) 2001) 1000)) 5000.0)
                  dz (/ (double (- (rem (hash2 eid t 6) 2001) 1000)) 5000.0)
                  nx (+ (aget x i) dx) nz (+ (aget z i) dz) nyaw (float (+ (aget yaw i) 1.0))]
              (aset x i nx) (aset z i nz) (aset yaw i nyaw)
              (.add out [eid (move-payload nx (aget y i) nz nyaw (aget pitch i))]))))))
    (vec out)))

;; ---------------------------------------------------------------------------------------------- digest of an outbox drain (SPEC 6)
(defn row-hash ^long [^long conn ^bytes data]
  (let [md (MessageDigest/getInstance "SHA-256")
        _ (.update md (.array (.putInt (ByteBuffer/allocate 4) (unchecked-int conn))))
        _ (.update md data)
        d (.digest md)]
    (.getLong (ByteBuffer/wrap d) 0)))

(defn digest
  "rows: [[conn data] ...] -> [count bytes xor]"
  [rows]
  (reduce (fn [[^long n ^long b ^long x] [conn ^bytes data]]
            [(inc n) (+ b (alength data)) (bit-xor x (row-hash (long conn) data))])
          [0 0 0] rows))

;; ---------------------------------------------------------------------------------------------- chat
(defn vocab-word ^String [^long i] (str "w" (Long/toString (+ 1000 i) 36)))
(defn chat-message
  "message number k: 4..9 words from a 400-word vocabulary"
  ^String [^long k]
  (let [n (+ 4 (rem (hash2 k 1 41) 6))]
    (clojure.string/join " " (for [j (range n)] (vocab-word (rem (hash2 k j 42) 400))))))

(defn chat-sender ^long [^long k] (inc (rem (hash2 k 3 43) 500)))
