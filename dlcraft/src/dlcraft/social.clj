(ns dlcraft.social
  "Chat (Datalog entities with a full-text index) and inventories (one Datalog entity per non-empty slot), SPEC 8."
  (:require [datalevin.core :as d]
            [dlcraft.codec :refer [hash2]]
            [dlcraft.store :as st])
  (:import [java.util.concurrent.atomic AtomicLong]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

;; ---------------------------------------------------------------------------------------------- chat
(defonce ^AtomicLong chat-seq (AtomicLong. 0))

(defn reset-chat! [{:keys [conn]}]
  (.set chat-seq 0)
  (let [db (d/db conn)
        eids (d/q '[:find [?e ...] :where [?e :chat/id _]] db)]
    (when (seq eids) (d/transact! conn (for [e eids] [:db/retractEntity e])))))

(defn chat-add-bulk!
  "rows [[sender text at] ...] -> last id"
  [{:keys [conn]} rows]
  (let [ents (for [[s t at] rows] {:chat/id (.incrementAndGet chat-seq) :chat/sender s :chat/at at :chat/text t})]
    (d/transact! conn (vec ents))
    (.get chat-seq)))

(defn chat-add! [env sender text at] (chat-add-bulk! env [[sender text at]]))

(defn chat-search
  "ids containing the whole token, newest first"
  [{:keys [conn]} word lim]
  (->> (d/q '[:find ?id :in $ ?w :where [(fulltext $ ?w {:top 1000000}) [[?e ?a ?v]]] [?e :chat/id ?id]] (d/db conn) word)
       (map first) (sort >) (take lim) vec))

(defn chat-recent
  "newest `lim` ids: a range over the AVE index of the sequential unique :chat/id"
  [{:keys [conn]} lim]
  (let [hi (.get chat-seq)]
    (vec (reverse (map :v (d/index-range (d/db conn) :chat/id (max 1 (- hi (dec lim))) hi))))))

(defn chat-count-by-sender [{:keys [conn]}]
  (into (sorted-map) (d/q '[:find ?s (count ?e) :where [?e :chat/sender ?s]] (d/db conn))))

;; ---------------------------------------------------------------------------------------------- inventory
(defn max-stack ^long [^long item] (cond (< item 100) 64 (< item 180) 16 :else 1))
(defn- ikey ^long [^long player ^long slot] (+ (* player 64) slot))

(defn reset-inv! [{:keys [conn]}]
  (let [eids (d/q '[:find [?e ...] :where [?e :inv/key _]] (d/db conn))]
    (when (seq eids) (d/transact! conn (for [e eids] [:db/retractEntity e])))))

(defn inv-seed! [{:keys [conn]} n]
  (d/transact! conn
               (vec (for [p (range 1 (inc n)) slot (range 5 45)
                          :when (< (rem (hash2 p slot 9) 100) 70)]
                      (let [item (+ 1 (rem (hash2 p slot 10) 199)) cnt (+ 1 (rem (hash2 p slot 11) (max-stack item)))]
                        {:inv/key (ikey p slot) :inv/player p :inv/slot slot :inv/item item :inv/count cnt})))))

(defn- slot-of
  "[item count] or nil"
  [db ^long player ^long slot]
  (when-let [e (d/entity db [:inv/key (ikey player slot)])]
    [(:inv/item e) (:inv/count e)]))

(defn- slot-tx [^long player ^long slot cur]
  (if cur
    {:inv/key (ikey player slot) :inv/player player :inv/slot slot :inv/item (first cur) :inv/count (second cur)}
    [:db/retractEntity [:inv/key (ikey player slot)]]))

(defn click-plan
  "pure: given a fn (slot -> [item count] | nil), returns {slot new-value-or-nil} of the slots that change, SPEC 8"
  [get-slot op ^long a ^long b]
  (if (and (== a b) (#{"swap" "merge"} op)) {}
  (case op
    "swap" (let [sa (get-slot a) sb (get-slot b)] (if (= sa sb) {} {a sb b sa}))
    "merge" (let [sa (get-slot a) sb (get-slot b)]
              (cond (nil? sa) {}
                    (and sb (= (first sa) (first sb)))
                    (let [mv (min (second sa) (- (max-stack (first sa)) (second sb)))]
                      (if (<= mv 0) {}
                          {a (when (> (- (second sa) mv) 0) [(first sa) (- (second sa) mv)])
                           b [(first sb) (+ (second sb) mv)]}))
                    :else {a sb b sa}))
    "quick" (let [sa (get-slot a)
                  rng (cond (and (>= a 9) (<= a 35)) (range 36 45) (and (>= a 36) (<= a 44)) (range 9 36) :else nil)]
              (if (or (nil? sa) (nil? rng)) {}
                  (let [item (first sa) ms (max-stack item)
                        ;; pass 1: merge into same-item stacks with room
                        [rem1 ch1] (reduce (fn [[rem ch] s]
                                             (if (<= rem 0) (reduced [rem ch])
                                                 (let [cur (get-slot s)]
                                                   (if (and cur (= (first cur) item) (< (second cur) ms))
                                                     (let [mv (min rem (- ms (second cur)))]
                                                       [(- rem mv) (assoc ch s [item (+ (second cur) mv)])])
                                                     [rem ch]))))
                                           [(second sa) {}] rng)
                        ;; pass 2: first empty slot
                        [rem2 ch2] (if (<= rem1 0) [rem1 ch1]
                                       (if-let [s (first (filter #(nil? (get-slot %)) rng))]
                                         (let [mv (min rem1 ms)] [(- rem1 mv) (assoc ch1 s [item mv])])
                                         [rem1 ch1]))]
                    (if (= rem2 (second sa)) {}
                        (assoc ch2 a (when (> rem2 0) [item rem2]))))))
    "drop" (let [sa (get-slot a)]
             (if (nil? sa) {}
                 (let [mv (min b (second sa)) left (- (second sa) mv)]
                   (if (<= mv 0) {} {a (when (> left 0) [(first sa) left])})))))))

(defn inv-click!
  "one click in its own transaction"
  [{:keys [conn]} player op a b]
  (let [player (long player) a (long a) b (long b) db (d/db conn)
        plan (click-plan #(slot-of db player %) op a b)]
    (when (seq plan)
      (d/transact! conn (vec (for [[s v] plan] (slot-tx player s v)))))))

(defn inv-clicks-bulk!
  "all clicks inside ONE transaction (reads see earlier clicks of the same call)"
  [{:keys [conn]} players ops as bs]
  (let [players (vec players) ops (vec ops) as (vec as) bs (vec bs)]
  (d/with-transaction [tx conn]
    (dotimes [i (count players)]
      (let [db (d/db tx) player (long (nth players i))
            plan (click-plan #(slot-of db player %) (nth ops i) (long (nth as i)) (long (nth bs i)))]
        (when (seq plan)
          (d/transact! tx (vec (for [[s v] plan] (slot-tx player s v))))))))))

(defn inv-load [{:keys [conn]} ^long player]
  (->> (d/q '[:find ?s ?i ?c :in $ ?p :where [?e :inv/player ?p] [?e :inv/slot ?s] [?e :inv/item ?i] [?e :inv/count ?c]] (d/db conn) player)
       (sort-by first) vec))

(defn inv-digest ^long [{:keys [conn]}]
  (reduce (fn [^long acc [p s i c]] (+ acc (* p 1000003) (* s 8191) (* i 131) (* c 7) (* p s 3)))
          0 (d/q '[:find ?p ?s ?i ?c :where [?e :inv/player ?p] [?e :inv/slot ?s] [?e :inv/item ?i] [?e :inv/count ?c]] (d/db conn))))

;; ---------------------------------------------------------------------------------------------- inventory as one KV record per player
;; 46 slots x (u16 item, u8 count) = 138 bytes in the `inv` DBI keyed by player id.  A click is one get and one put: the Datalog-entity
;; version above is what a "readable rows" design looks like; this one is what Datalevin's raw LMDB layer is for.
(defn- pkey ^bytes [^long p] (.array (.putInt (java.nio.ByteBuffer/allocate 4) (unchecked-int p))))

(defn- decode-inv [^bytes b]
  (let [bb (java.nio.ByteBuffer/wrap b) items (long-array 46) counts (long-array 46)]
    (dotimes [i 46] (aset items i (bit-and (long (.getShort bb (* 3 i))) 0xFFFF)) (aset counts i (bit-and (long (.get bb (+ (* 3 i) 2))) 0xFF)))
    [items counts]))

(defn- encode-inv ^bytes [^longs items ^longs counts]
  (let [bb (java.nio.ByteBuffer/allocate 138)]
    (dotimes [i 46] (.putShort bb (* 3 i) (unchecked-short (aget items i))) (.put bb (+ (* 3 i) 2) (unchecked-byte (aget counts i))))
    (.array bb)))

(defn inv-seed-kv! [{:keys [kv]} n]
  (d/transact-kv kv
                 (vec (for [p (range 1 (inc n))]
                        (let [items (long-array 46) counts (long-array 46)]
                          (doseq [slot (range 5 45)]
                            (when (< (rem (hash2 p slot 9) 100) 70)
                              (let [item (+ 1 (rem (hash2 p slot 10) 199))]
                                (aset items slot item) (aset counts slot (+ 1 (rem (hash2 p slot 11) (max-stack item)))))))
                          [:put "inv" (pkey p) (encode-inv items counts) :bytes :bytes])))))

(defn reset-inv-kv! [{:keys [kv]}] (d/clear-dbi kv "inv"))

(defn inv-click-kv!
  "one click against the record, through any KV handle (the env's, or a transaction's)"
  [kv player op a b]
  (when-let [bl (d/get-value kv "inv" (pkey (long player)) :bytes :bytes)]
    (let [player (long player) a (long a) b (long b)
          [^longs items ^longs counts] (decode-inv bl)
          get-slot (fn [s] (let [s (long s)] (when (pos? (aget counts s)) [(aget items s) (aget counts s)])))
          plan (click-plan get-slot op a b)]
      (when (seq plan)
        (doseq [[s v] plan]
          (aset items (long s) (long (if v (first v) 0))) (aset counts (long s) (long (if v (second v) 0))))
        (d/transact-kv kv "inv" [[:put (pkey player) (encode-inv items counts)]] :bytes :bytes)))))

(defn inv-clicks-bulk-kv! [{:keys [kv]} players ops as bs]
  (let [players (vec players) ops (vec ops) as (vec as) bs (vec bs)]
  (d/with-transaction-kv [tx kv]
    (dotimes [i (count players)]
      (inv-click-kv! tx (long (nth players i)) (nth ops i) (long (nth as i)) (long (nth bs i)))))))

(defn inv-load-kv [{:keys [kv]} ^long player]
  (when-let [bl (d/get-value kv "inv" (pkey player) :bytes :bytes)]
    (let [[^longs items ^longs counts] (decode-inv bl)]
      (vec (for [s (range 46) :when (pos? (aget counts s))] [s (aget items s) (aget counts s)])))))

(defn inv-digest-kv ^long [{:keys [kv]}]
  (reduce (fn [^long acc [^bytes k ^bytes v]]
            (let [p (long (.getInt (java.nio.ByteBuffer/wrap k))) [^longs items ^longs counts] (decode-inv v)]
              (loop [s 0 acc acc]
                (if (< s 46)
                  (recur (inc s) (if (pos? (aget counts s))
                                   (+ acc (* p 1000003) (* s 8191) (* (aget items s) 131) (* (aget counts s) 7) (* p s 3))
                                   acc))
                  acc))))
          0 (d/get-range kv "inv" [:all] :bytes :bytes false)))

(defn inv-holders-kv
  "who holds `item` anywhere: player ids (a scan over all records)"
  [{:keys [kv]} ^long item]
  (vec (for [[^bytes k ^bytes v] (d/get-range kv "inv" [:all] :bytes :bytes false)
             :let [[^longs items ^longs counts] (decode-inv v)]
             :when (some (fn [s] (and (pos? (aget counts s)) (== (aget items s) item))) (range 46))]
         (long (.getInt (java.nio.ByteBuffer/wrap k))))))
