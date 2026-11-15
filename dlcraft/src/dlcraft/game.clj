(ns dlcraft.game
  "Players, spatial cells, visibility and the tick (SPEC 6) on LMDB.  Hot per-player state is one packed 65-byte record in the `pos` DBI
  (no Datalog datoms: an update is one LMDB put); the spatial hash is the `cell` DBI keyed [cx cz eid]; visibility is the `vis` DBI keyed
  [viewer target] (both directions).  The whole tick reads, then writes everything in one transaction."
  (:require [datalevin.core :as d]
            [dlcraft.codec :as c]
            [dlcraft.store :as st])
  (:import [java.nio ByteBuffer]
           [java.util ArrayList HashMap HashSet LinkedHashMap TreeSet]
           [java.security MessageDigest]
           [java.util.concurrent ConcurrentHashMap]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

;; ---------------------------------------------------------------------------------------------- player records
(deftype P [^long eid ^double x ^double y ^double z ^float yaw ^float pitch ^boolean og ^long cx ^long cz ^long sqx ^long sqy ^long sqz])

(defn- ibias ^long [^long v] (+ v 2147483648))

(defn ->bytes ^bytes [^P p]
  (let [bb (ByteBuffer/allocate 65)]
    (.putDouble bb (.x p)) (.putDouble bb (.y p)) (.putDouble bb (.z p))
    (.putFloat bb (.yaw p)) (.putFloat bb (.pitch p)) (.put bb (if (.og p) (byte 1) (byte 0)))
    (.putInt bb (unchecked-int (.cx p))) (.putInt bb (unchecked-int (.cz p)))
    (.putLong bb (.sqx p)) (.putLong bb (.sqy p)) (.putLong bb (.sqz p))
    (.array bb)))

(defn bytes-> ^P [^long eid ^bytes b]
  (let [bb (ByteBuffer/wrap b)]
    (P. eid (.getDouble bb 0) (.getDouble bb 8) (.getDouble bb 16) (.getFloat bb 24) (.getFloat bb 28) (== 1 (long (.get bb 32)))
        (long (.getInt bb 33)) (long (.getInt bb 37)) (.getLong bb 41) (.getLong bb 49) (.getLong bb 57))))

(defn- ekey ^bytes [^long eid] (.array (.putInt (ByteBuffer/allocate 4) (unchecked-int eid))))
(defn- ckey3 ^bytes [^long cx ^long cz ^long eid]
  (let [bb (ByteBuffer/allocate 12)]
    (.putInt bb (unchecked-int (ibias cx))) (.putInt bb (unchecked-int (ibias cz))) (.putInt bb (unchecked-int eid))
    (.array bb)))
(defn- vkey ^bytes [^long a ^long b] (.array (.putInt (.putInt (ByteBuffer/allocate 8) (unchecked-int a)) (unchecked-int b))))

(def ^:private ^bytes ONE (byte-array [1]))

(defn- rint-q ^long [^double v] (long (Math/rint (* v 4096.0))))
(defn- chunk-of ^long [^double v] (long (Math/floor (/ v 16.0))))

(defonce ^:private ^ConcurrentHashMap uuid-cache (ConcurrentHashMap.))
(defn uuid-bytes ^bytes [^long eid]
  (or (.get uuid-cache eid)
      (let [b (.digest (MessageDigest/getInstance "MD5") (.getBytes (str "p" eid) "UTF-8"))]
        (.put uuid-cache eid b) b)))

(defn angle ^long [^double deg] (bit-and (long (Math/floor (/ (* deg 256.0) 360.0))) 255))

;; ---------------------------------------------------------------------------------------------- packets (SPEC 6)
(defn- framed ^bytes [^ByteBuffer body]
  (let [n (.position body)
        out (ByteBuffer/allocate (+ 5 n))]
    (c/put-varint! out n)
    (.put out (.array body) 0 n)
    (let [a (byte-array (.position out))] (.get (.duplicate (.flip out)) a) a)))

(defn pkt-add-entity ^bytes [^P p]
  (let [b (ByteBuffer/allocate 64)]
    (c/put-varint! b 1) (c/put-varint! b (.eid p)) (.put b (uuid-bytes (.eid p)))
    (.putDouble b (.x p)) (.putDouble b (.y p)) (.putDouble b (.z p))
    (.put b (unchecked-byte (angle (double (.yaw p))))) (.put b (unchecked-byte (angle (double (.pitch p)))))
    (framed b)))

(defn pkt-remove ^bytes [^long eid]
  (let [b (ByteBuffer/allocate 16)] (c/put-varint! b 2) (c/put-varint! b 1) (c/put-varint! b eid) (framed b)))

(defn pkt-move ^bytes [^P p ^long dx ^long dy ^long dz]
  (let [b (ByteBuffer/allocate 32)]
    (c/put-varint! b 3) (c/put-varint! b (.eid p))
    (.putShort b (unchecked-short dx)) (.putShort b (unchecked-short dy)) (.putShort b (unchecked-short dz))
    (.put b (unchecked-byte (angle (double (.yaw p))))) (.put b (unchecked-byte (angle (double (.pitch p)))))
    (.put b (if (.og p) (byte 1) (byte 0)))
    (framed b)))

(defn pkt-teleport ^bytes [^P p]
  (let [b (ByteBuffer/allocate 64)]
    (c/put-varint! b 4) (c/put-varint! b (.eid p))
    (.putDouble b (.x p)) (.putDouble b (.y p)) (.putDouble b (.z p))
    (.put b (unchecked-byte (angle (double (.yaw p))))) (.put b (unchecked-byte (angle (double (.pitch p)))))
    (.put b (if (.og p) (byte 1) (byte 0)))
    (framed b)))

(defn- block-pos ^long [^long x ^long y ^long z]
  (bit-or (bit-shift-left (bit-and x 0x3FFFFFF) 38) (bit-shift-left (bit-and z 0x3FFFFFF) 12) (bit-and y 0xFFF)))

(defn pkt-block-update ^bytes [^long x ^long y ^long z ^long state]
  (let [b (ByteBuffer/allocate 24)] (c/put-varint! b 5) (.putLong b (block-pos x y z)) (c/put-varint! b state) (framed b)))

(defn pkt-fill-update ^bytes [x y z state cnt]
  (let [b (ByteBuffer/allocate 32)] (c/put-varint! b 6) (.putLong b (block-pos (long x) (long y) (long z))) (c/put-varint! b (long state)) (c/put-varint! b (long cnt)) (framed b)))

(defn move-packet
  "SPEC 6 step 4: move_entity, or teleport_entity when a delta does not fit an i16."
  ^bytes [^P p ^long dx ^long dy ^long dz]
  (if (and (<= (Math/abs dx) 32767) (<= (Math/abs dy) 32767) (<= (Math/abs dz) 32767))
    (pkt-move p dx dy dz)
    (pkt-teleport p)))

;; ---------------------------------------------------------------------------------------------- inbox / outbox (in-memory LMDB, the UNLOGGED tables of this design)
(defn inbox-push!
  "rows: seq of [conn payload-bytes]"
  [^dlcraft.store.Env env rows]
  (d/transact-kv (:mem env) "inbox"
                 (for [[conn ^bytes pl] rows]
                   (let [bb (ByteBuffer/allocate (+ 4 (alength pl)))]
                     (.putInt bb (unchecked-int conn)) (.put bb pl)
                     [:put (.incrementAndGet ^java.util.concurrent.atomic.AtomicLong (:inseq env)) (.array bb)]))
                 :long :bytes))

(defn- outbox-write! [^dlcraft.store.Env env ^ArrayList rows]
  (when-not (.isEmpty rows)
    (d/transact-kv (:mem env) "outbox"
                   (for [^objects r rows]
                     (let [^bytes data (aget r 1)
                           bb (ByteBuffer/allocate (+ 4 (alength data)))]
                       (.putInt bb (unchecked-int (long (aget r 0)))) (.put bb data)
                       [:put (.incrementAndGet ^java.util.concurrent.atomic.AtomicLong (:outseq env)) (.array bb)]))
                   :long :bytes)))

(defn outbox-drain!
  "Returns [[conn data] ...] and empties the outbox."
  [^dlcraft.store.Env env]
  (let [rows (d/get-range (:mem env) "outbox" [:all] :long :bytes true)]
    (d/clear-dbi (:mem env) "outbox")
    (mapv (fn [^bytes b] (let [bb (ByteBuffer/wrap b)] [(.getInt bb 0) (java.util.Arrays/copyOfRange b 4 (alength b))])) rows)))

;; ---------------------------------------------------------------------------------------------- game time
(defn game-time ^long [kv]
  (if-let [^bytes b (d/get-value kv "meta" "game_time" :string :bytes)] (.getLong (ByteBuffer/wrap b) 0) 0))
(defn- put-game-time [^long t] [:put "meta" "game_time" (.array (.putLong (ByteBuffer/allocate 8) t)) :string :bytes])

;; ---------------------------------------------------------------------------------------------- joining
(defn join-bulk!
  "SPEC 6 join_bulk: no packets."
  [^dlcraft.store.Env env eids xs ys zs]
  (let [kv (:kv env) eids (vec eids) xs (vec xs) ys (vec ys) zs (vec zs)
        ops (ArrayList.)]
    (dotimes [i (count eids)]
      (let [eid (long (nth eids i)) x (double (nth xs i)) y (double (nth ys i)) z (double (nth zs i))
            p (P. eid x y z (float 0) (float 0) true (chunk-of x) (chunk-of z) (rint-q x) (rint-q y) (rint-q z))]
        (.add ops [:put "pos" (ekey eid) (->bytes p) :bytes :bytes])
        (.add ops [:put "cell" (ckey3 (.cx p) (.cz p) eid) ONE :bytes :bytes])))
    (d/transact-kv kv ops)))

(defn reset-players! [^dlcraft.store.Env env]
  (doseq [n ["pos" "cell" "vis"]] (d/clear-dbi (:kv env) n))
  (d/clear-dbi (:mem env) "inbox") (d/clear-dbi (:mem env) "outbox")
  (d/transact-kv (:kv env) [[:del "meta" "game_time" :string]]))

(defn- load-p ^P [kv ^long eid]
  (when-let [b (d/get-value kv "pos" (ekey eid) :bytes :bytes)] (bytes-> eid b)))

(defn- neighbours
  "eids in the 7x7 cell window around chunk (cx, cz), from the cell index (pre-tick state)"
  [kv ^long cx ^long cz ^long r]
  (let [out (ArrayList.)]
    (doseq [^long x (range (- cx r) (+ cx r 1))]
      (doseq [^bytes k (d/key-range kv "cell" [:closed (ckey3 x (- cz r) 0) (ckey3 x (+ cz r) 0x7fffffff)] :bytes)]
        (.add out (long (.getInt (ByteBuffer/wrap k) 8)))))
    out))

(defn- visible-set
  "eids currently visible to `eid` (vis DBI)"
  ^HashSet [kv ^long eid]
  (let [out (HashSet.)]
    (doseq [^bytes k (d/key-range kv "vis" [:closed (vkey eid 0) (vkey eid 0x7fffffff)] :bytes)]
      (.add out (long (.getInt (ByteBuffer/wrap k) 4))))
    out))

(defn- in-range? [^P a ^P b]
  (let [dx (- (.x a) (.x b)) dz (- (.z a) (.z b))] (<= (+ (* dx dx) (* dz dz)) 2304.0)))

(defn vis-init!
  "SPEC 6 vis_init: silent; returns the number of unordered visible pairs."
  [^dlcraft.store.Env env]
  (let [kv (:kv env)
        all (d/get-range kv "pos" [:all] :bytes :bytes false)
        ps (HashMap.)
        _ (doseq [[^bytes k ^bytes v] all] (let [eid (long (.getInt (ByteBuffer/wrap k)))] (.put ps eid (bytes-> eid v))))
        ops (ArrayList.)
        pairs (volatile! 0)]
    (doseq [^P p (vals ps)]
      (doseq [q-eid (neighbours kv (.cx p) (.cz p) 3)]
        (when (< (.eid p) (long q-eid))
          (let [^P q (.get ps q-eid)]
            (when (in-range? p q)
              (vswap! pairs inc)
              (.add ops [:put "vis" (vkey (.eid p) q-eid) ONE :bytes :bytes])
              (.add ops [:put "vis" (vkey q-eid (.eid p)) ONE :bytes :bytes]))))))
    (when-not (.isEmpty ops) (d/transact-kv kv ops))
    @pairs))

(defn visible-pairs [kv] (quot (long (d/range-count kv "vis" [:all] :bytes)) 2))

(defn player-digest
  "SPEC 6: sum of eid*1000003 + sqx*7 + sqy*13 + sqz*17 + cx*31 + cz*37"
  ^long [kv]
  (reduce (fn [^long acc [^bytes k ^bytes v]]
            (let [^P p (bytes-> (long (.getInt (ByteBuffer/wrap k))) v)]
              (+ acc (* (.eid p) 1000003) (* (.sqx p) 7) (* (.sqy p) 13) (* (.sqz p) 17) (* (.cx p) 31) (* (.cz p) 37))))
          0 (d/get-range kv "pos" [:all] :bytes :bytes false)))

;; ---------------------------------------------------------------------------------------------- the tick
(defn- decode-move
  "payload -> [x y z yaw pitch og] or nil"
  [^bytes pl]
  (when (== (alength pl) 34)
    (let [bb (ByteBuffer/wrap pl)]
      [(.getDouble bb 1) (.getDouble bb 9) (.getDouble bb 17) (.getFloat bb 25) (.getFloat bb 29) (not (zero? (bit-and (long (.get bb 33)) 1)))])))

(defn- out! [^ArrayList rows ^long conn ^bytes data] (.add rows (object-array [conn data])))

(defn server-tick!
  "SPEC 6.  Returns the new game_time."
  [^dlcraft.store.Env env]
  (let [kv (:kv env) mem (:mem env)
        inbox (d/get-range mem "inbox" [:all] :long :bytes true)
        _ (when (seq inbox) (d/clear-dbi mem "inbox"))
        t (inc (game-time kv))
        rows (ArrayList.)
        ops (ArrayList.)
        ;; 1. parse and validate: last packet per conn wins
        moves (LinkedHashMap.)]
    (doseq [^bytes b inbox]
      (let [bb (ByteBuffer/wrap b) conn (long (.getInt bb 0))
            pl (java.util.Arrays/copyOfRange b 4 (alength b))]
        (when-let [m (decode-move pl)] (.put moves conn m))))
    ;; 2. apply
    (let [mover (HashMap.)                                   ; eid -> new P (final position)
          old   (HashMap.)]                                  ; eid -> old P
      (doseq [^java.util.Map$Entry e (.entrySet moves)]
        (let [conn (long (.getKey e)) [x y z yaw pitch og] (.getValue e)
              ^P o (load-p kv conn)]
          (when (and o (<= (Math/abs (- (double x) (.x o))) 10.0) (<= (Math/abs (- (double z) (.z o))) 10.0))
            (.put old conn o)
            (.put mover conn (P. conn (double x) (double y) (double z) (float yaw) (float pitch) (boolean og)
                                 (chunk-of x) (chunk-of z) (.sqx o) (.sqy o) (.sqz o))))))
      (let [pcache (HashMap.)
            final-of (fn ^P [^long eid] (or (.get mover eid)
                                            (let [c (.get pcache eid)]
                                              (if (nil? c) (let [lp (load-p kv eid)] (.put pcache eid lp) lp) c))))
            ;; movers bucketed by their NEW cell (a per-tick scratch grid; the stored cell index still shows the old cells)
            mgrid (HashMap.)
            _ (doseq [^java.util.Map$Entry e (.entrySet mover)]
                (let [^P p (.getValue e) k (+ (* (ibias (.cx p)) 4294967296) (ibias (.cz p)))
                      ^ArrayList l (or (.get mgrid k) (let [l (ArrayList.)] (.put mgrid k l) l))]
                  (.add l (.eid p))))]
        ;; 3+4. visibility diff and movement fan-out for each mover
        (doseq [^java.util.Map$Entry e (.entrySet mover)]
          (let [^P p (.getValue e) eid (.eid p)
                ^P o (.get old eid)
                ;; candidates: window in the pre-tick cell index + every mover
                cand (HashSet.)
                _ (doseq [q (neighbours kv (.cx p) (.cz p) 3)] (.add cand (long q)))
                _ (loop [gx (- (.cx p) 3)]
                    (when (<= gx (+ (.cx p) 3))
                      (loop [gz (- (.cz p) 3)]
                        (when (<= gz (+ (.cz p) 3))
                          (when-let [^ArrayList l (.get mgrid (+ (* (ibias gx) 4294967296) (ibias gz)))] (.addAll cand l))
                          (recur (inc gz))))
                      (recur (inc gx))))
                now (HashSet.)]
            (doseq [q cand]
              (let [q (long q)]
                (when-not (== q eid)
                  (when (in-range? p (final-of q)) (.add now q)))))
            (let [^HashSet was (visible-set kv eid)]
              ;; enters
              (doseq [q now]
                (let [q (long q)]
                  (when-not (.contains was q)
                    (when (or (not (.containsKey mover q)) (< eid q))
                      (let [^P qp (final-of q)]
                        (out! rows eid (pkt-add-entity qp))
                        (out! rows q (pkt-add-entity p))
                        (.add ops [:put "vis" (vkey eid q) ONE :bytes :bytes])
                        (.add ops [:put "vis" (vkey q eid) ONE :bytes :bytes]))))))
              ;; leaves
              (doseq [q was]
                (let [q (long q)]
                  (when-not (.contains now q)
                    (when (or (not (.containsKey mover q)) (< eid q))
                      (out! rows eid (pkt-remove q))
                      (out! rows q (pkt-remove eid))
                      (.add ops [:del "vis" (vkey eid q) :bytes])
                      (.add ops [:del "vis" (vkey q eid) :bytes])))))
              ;; movement fan-out: retained pairs
              (let [qx (rint-q (.x p)) qy (rint-q (.y p)) qz (rint-q (.z p))
                    dx (- qx (.sqx o)) dy (- qy (.sqy o)) dz (- qz (.sqz o))]
                (doseq [q now]
                  (when (.contains was (long q))
                    (out! rows q (move-packet p dx dy dz))))))))
        ;; state writes for movers
        (doseq [^java.util.Map$Entry e (.entrySet mover)]
          (let [^P p (.getValue e) ^P o (.get old (.getKey e))
                np (P. (.eid p) (.x p) (.y p) (.z p) (.yaw p) (.pitch p) (.og p) (.cx p) (.cz p)
                       (rint-q (.x p)) (rint-q (.y p)) (rint-q (.z p)))]
            (.add ops [:put "pos" (ekey (.eid p)) (->bytes np) :bytes :bytes])
            (when (or (not= (.cx o) (.cx p)) (not= (.cz o) (.cz p)))
              (.add ops [:del "cell" (ckey3 (.cx o) (.cz o) (.eid p)) :bytes])
              (.add ops [:put "cell" (ckey3 (.cx p) (.cz p) (.eid p)) ONE :bytes :bytes]))))
        ;; 5. block events
        (let [evs (d/get-range kv "evq" [:all] :long :bytes false)]
          (when (seq evs)
            (doseq [[k _] evs] (.add ops [:del "evq" k :long]))
            (doseq [[_ ^bytes b] evs]
              (let [bb (ByteBuffer/wrap b) kind (.get bb 0) x (long (.getInt bb 1)) y (long (.getInt bb 5)) z (long (.getInt bb 9))
                    nw (long (.getInt bb 17)) cnt (long (.getInt bb 21))
                    ecx (bit-shift-right x 4) ecz (bit-shift-right z 4)
                    viewers (HashSet.)]
                (doseq [q (neighbours kv ecx ecz 8)]
                  (let [q (long q)] (when-not (.containsKey mover q) (.add viewers q))))
                (doseq [^java.util.Map$Entry e (.entrySet mover)]
                  (let [^P p (.getValue e)]
                    (when (and (<= (Math/abs (- (.cx p) ecx)) 8) (<= (Math/abs (- (.cz p) ecz)) 8)) (.add viewers (.eid p)))))
                (let [data (if (zero? kind) (pkt-block-update x y z nw) (pkt-fill-update x y z nw cnt))]
                  (doseq [q viewers] (out! rows (long q) data)))))))
        (.add ops (put-game-time t))
        (d/transact-kv kv ops)
        (outbox-write! env rows)
        t))))
