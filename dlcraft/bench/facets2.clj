(ns facets2
  "Game facets: tick, hot-row churn, chat, inventory, dynamics."
  (:require [datalevin.core :as d]
            [dlcraft.codec :as c :refer [hash2]]
            [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.game :as g] [dlcraft.dyn :as dyn] [dlcraft.social :as so] [dlcraft.workload :as wl]
            [pgx] [util :as u :refer [timed repeat-ms median summarize]] [rec :refer [rec! facet]])
  (:import [java.nio ByteBuffer]))

(defn pg1 [pg sql & ps] (apply pgx/query1 pg sql ps))

;; ---------------------------------------------------------------------------------------------- tick
(defn run-tick-scenario
  "returns {:dl {...} :pg {...} :match? bool}"
  [{:keys [env pg]} {:keys [n side frac edits ticks warm]}]
  (let [kv (:kv env)
        mir (wl/init-mirror n side)
        eids (vec (range 1 (inc n))) xs (vec (map #(aget ^doubles (:x mir) %) (range n))) ys (vec (repeat n 80.0)) zs (vec (map #(aget ^doubles (:z mir) %) (range n)))]
    (g/reset-players! env) (pgx/query pg "select mc.reset_players()")
    (g/join-bulk! env eids xs ys zs)
    (pgx/query pg "select mc.join_bulk(?,?,?,?)" (pgx/int-array-of eids) (pgx/float-array-of xs) (pgx/float-array-of ys) (pgx/float-array-of zs))
    (let [pairs-dl (g/vis-init! env) pairs-pg (long (pg1 pg "select mc.vis_init()"))
          dl-t (volatile! []) pg-t (volatile! []) dl-in (volatile! []) pg-in (volatile! []) dl-out (volatile! []) pg-out (volatile! [])
          dl-rows (volatile! 0) pg-rows (volatile! 0) dl-bytes (volatile! 0) pg-bytes (volatile! 0)
          dl-dg (volatile! [0 0 0]) pg-dg (volatile! [0 0 0])]
      (w/drain-block-events! kv) (pgx/query pg "select mc.drain_block_events()")
      (dotimes [t (+ warm ticks)]
        (let [t' (inc t) moves (wl/tick-moves mir t' frac) measure? (>= t warm)
              conns (pgx/int-array-of (map first moves)) pls (pgx/bytea-array-of (map second moves))]
          (dotimes [k edits]
            (let [x (rem (hash2 t' k 31) 256) y (+ 60 (rem (hash2 t' k 32) 40)) z (rem (hash2 t' k 33) 256) s (rem (hash2 t' k 34) 21)]
              (w/set-block! env kv x y z s) (pg1 pg "select mc.set_block(?,?,?,?)" x y z s)))
          (let [[_ a] (timed (g/inbox-push! env moves))
                [_ b] (timed (g/server-tick! env))
                [rows c] (timed (g/outbox-drain! env))]
            (when measure? (vswap! dl-in conj a) (vswap! dl-t conj b) (vswap! dl-out conj c) (vswap! dl-rows + (count rows)) (vswap! dl-bytes + (reduce + (map #(alength ^bytes (second %)) rows)))
                   (vswap! dl-dg (fn [[a b x]] (let [[a2 b2 x2] (wl/digest rows)] [(+ a a2) (+ b b2) (bit-xor x x2)])))))
          (let [[_ a] (timed (pgx/query pg "select mc.inbox_push(?,?)" conns pls))
                [_ b] (timed (pg1 pg "select mc.server_tick()"))
                [rows c] (timed (pgx/bytes-query pg "select conn, data from mc.outbox_drain()"))]
            (when measure? (vswap! pg-in conj a) (vswap! pg-t conj b) (vswap! pg-out conj c) (vswap! pg-rows + (count rows)) (vswap! pg-bytes + (reduce + (map #(alength ^bytes (second %)) rows)))
                   (vswap! pg-dg (fn [[a b x]] (let [[a2 b2 x2] (wl/digest rows)] [(+ a a2) (+ b b2) (bit-xor x x2)])))))))
      {:pairs [pairs-dl pairs-pg]
       :dl {:tick (summarize @dl-t) :ingest (u/median @dl-in) :drain (u/median @dl-out) :rows (/ @dl-rows (double ticks)) :bytes (/ @dl-bytes (double ticks))}
       :pg {:tick (summarize @pg-t) :ingest (u/median @pg-in) :drain (u/median @pg-out) :rows (/ @pg-rows (double ticks)) :bytes (/ @pg-bytes (double ticks))}
       :match? (= @dl-dg @pg-dg)})))

(def tick-scenarios
  [{:label "100 players, 20% moving"  :n 100  :side 20 :frac 0.2 :edits 0  :ticks 200 :warm 40}
   {:label "500 players, 20% moving"  :n 500  :side 40 :frac 0.2 :edits 0  :ticks 200 :warm 40}
   {:label "500 players, 100% moving" :n 500  :side 40 :frac 1.0 :edits 0  :ticks 200 :warm 40}
   {:label "500 players, 20% moving, 20 block edits per tick" :n 500 :side 40 :frac 0.2 :edits 20 :ticks 200 :warm 40}
   {:label "500 players crowded (side 8, ~100 in view of each), 20% moving" :n 500 :side 8 :frac 0.2 :edits 0 :ticks 120 :warm 30}
   {:label "1000 players, 20% moving" :n 1000 :side 55 :frac 0.2 :edits 0  :ticks 150 :warm 30}
   {:label "2000 players, 20% moving" :n 2000 :side 80 :frac 0.2 :edits 0  :ticks 100 :warm 30}])

(defn f-tick [ctx & [only]]
  (facet "server tick (parse, move, visibility, fan-out, block broadcast)"
    (doseq [sc tick-scenarios :when (or (nil? only) (re-find (re-pattern only) (:label sc)))]
      (println "\n  --" (:label sc))
      (let [r (run-tick-scenario ctx sc) l (:label sc)]
        (doseq [[eng k] [["datalevin" :dl] ["postgres" :pg]]]
          (let [m (get r k) t (:tick m)]
            (rec! (str l ": tick avg") eng (:avg t) "ms")
            (rec! (str l ": tick p50") eng (:p50 t) "ms")
            (rec! (str l ": tick p99") eng (:p99 t) "ms")
            (rec! (str l ": tick max") eng (:max t) "ms")
            (rec! (str l ": inbox push") eng (:ingest m) "ms" :note "median")
            (rec! (str l ": outbox drain") eng (:drain m) "ms" :note (if (= k :pg) "includes shipping to the client over JDBC" "in-process"))
            (rec! (str l ": end to end (push + tick + drain)") eng (+ (:avg t) (:ingest m) (:drain m)) "ms" :note (format "%.0f frames, %.0f KB per tick" (:rows m) (/ (:bytes m) 1024.0)))))
        (rec! (str l ": outputs byte-identical (digest of every frame of every tick)") "both" (if (:match? r) 1 0) "1 = yes" :better :higher
              :note (str "visible pairs at start: " (pr-str (:pairs r))))))))

;; ---------------------------------------------------------------------------------------------- hot rows
(defn f-hot [{:keys [env pg]}]
  (facet "hot-row churn: 1000 players updated every tick, 200 ticks"
    (let [n 1000 rounds 200 conn (:conn env) kv (:kv env)
          eids (vec (range 1 (inc n)))
          pg-run (fn [reset-fn round-fn]
                   (pgx/exec! pg (str "select " reset-fn "(" n ")"))
                   (pgx/exec! pg "vacuum analyze bx.hot")
                   (let [ts (vec (for [r (range 1 (inc rounds))] (second (timed (pgx/exec! pg (str "select " round-fn "(" r ")"))))))] ts))
          rec-series (fn [engine label ts size-mb]
                       (let [s (summarize ts)]
                         (rec! (str label ": round avg") engine (:avg s) "ms")
                         (rec! (str label ": round p99") engine (:p99 s) "ms")
                         (rec! (str label ": last 20 rounds avg") engine (/ (reduce + (take-last 20 ts)) 20) "ms")
                         (when size-mb (rec! (str label ": storage after 200 rounds") engine size-mb "MB"))))]
      ;; PostgreSQL, tuned like dbcraft
      (let [ts (pg-run "bx.hot_reset" "bx.hot_round")]
        (rec-series "postgres" "update 1000 rows (fillfactor 60, no hot index)" ts (/ (pg1 pg "select bx.relsize('bx.hot')") 1048576.0)))
      (let [ts (pg-run "bx.hot_idx_reset" "bx.hot_idx_round")]
        (rec-series "postgres" "update 1000 rows (index on the changing column)" ts (/ (pg1 pg "select bx.relsize('bx.hot_idx')") 1048576.0)))
      ;; Datalevin: raw KV records
      (let [ekey (fn [e] (.array (.putInt (ByteBuffer/allocate 4) (int e))))
            rec (fn [e r] (let [bb (ByteBuffer/allocate 40)] (.putDouble bb (+ e (* 0.01 r))) (.putDouble bb (+ 64 (* 0.02 r))) (.putDouble bb (+ e (* 0.03 r))) (.putLong bb r) (.array bb)))
            _ (d/clear-dbi kv "pos")
            size0 (st/disk-bytes env)
            ts (vec (for [r (range 1 (inc rounds))] (second (timed (d/transact-kv kv (vec (for [e eids] [:put "pos" (ekey e) (rec e r) :bytes :bytes])))))))]
        (rec-series "datalevin/kv" "put 1000 packed records" ts (/ (- (st/disk-bytes env) size0) 1048576.0)))
      ;; Datalevin: datoms
      (let [_ (d/transact! conn (vec (for [e eids] {:p/eid e :p/x 0.0 :p/y 0.0 :p/z 0.0 :p/tick 0})))
            size0 (st/disk-bytes env)
            ts (vec (for [r (range 1 (inc rounds))]
                      (second (timed (d/transact! conn (vec (mapcat (fn [e] [[:db/add [:p/eid e] :p/x (+ e (* 0.01 r))] [:db/add [:p/eid e] :p/y (+ 64 (* 0.02 r))]
                                                                              [:db/add [:p/eid e] :p/z (+ e (* 0.03 r))] [:db/add [:p/eid e] :p/tick r]]) eids)))))))]
        (rec-series "datalevin/datalog" "transact! 4 datoms x 1000 players" ts (/ (- (st/disk-bytes env) size0) 1048576.0))))))

(defn f-reader [{:keys [env pg]}]
  (facet "an idle reader that never finishes (the \"psql left open\" problem)"
    (let [n 1000 conn (:conn env) kv (:kv env)
          eids (vec (range 1 (inc n)))
          ekey (fn [e] (.array (.putInt (ByteBuffer/allocate 4) (int e))))
          rec (fn [e r] (let [bb (ByteBuffer/allocate 40)] (.putDouble bb (+ e (* 0.01 r))) (.putDouble bb (+ 64 (* 0.02 r))) (.putDouble bb (+ e (* 0.03 r))) (.putLong bb r) (.array bb)))
          dl-rounds (fn [from to] (vec (for [r (range from to)] (second (timed (d/transact-kv kv (vec (for [e eids] [:put "pos" (ekey e) (rec e r) :bytes :bytes]))))))))
          pg-rounds (fn [from to] (vec (for [r (range from to)] (second (timed (pgx/exec! pg (str "select bx.hot_round(" r ")")))))))]
      (pgx/exec! pg "select bx.hot_reset(1000)") (pgx/exec! pg "vacuum bx.hot")
      (let [base (pg-rounds 1 101) sz0 (pg1 pg "select bx.relsize('bx.hot')")
            reader (pgx/connect false)]
        (pgx/query reader "select count(*) from bx.hot")                       ; opens a repeatable-read-ish snapshot and sits there
        (let [held (pg-rounds 101 301) sz1 (pg1 pg "select bx.relsize('bx.hot')")]
          (rec! "100 rounds before the reader (avg)" "postgres" (/ (reduce + base) 100.0) "ms")
          (rec! "rounds 101-300 with an idle-in-transaction reader (avg of last 100)" "postgres" (/ (reduce + (take-last 100 held)) 100.0) "ms")
          (rec! "table size: before / with the reader" "postgres" (/ sz1 1048576.0) "MB" :note (format "%.1f MB before" (/ sz0 1048576.0))))
        (.rollback reader) (.close reader))
      ;; LMDB: a reader that holds a read transaction pins every page version written after it started
      (d/clear-dbi kv "pos")
      (let [base (dl-rounds 1 101) sz0 (st/disk-bytes env)
            pinned (try (let [s (d/range-seq kv "pos" [:all] :bytes :bytes)] (first s) s) (catch Throwable t (println "  range-seq failed:" (.getMessage t)) nil))
            held (dl-rounds 101 301) sz1 (st/disk-bytes env)]
        (rec! "100 rounds before the reader (avg)" "datalevin/kv" (/ (reduce + base) 100.0) "ms")
        (rec! "rounds 101-300 with an open read transaction (avg of last 100)" "datalevin/kv" (/ (reduce + (take-last 100 held)) 100.0) "ms" :note (if pinned "lazy range-seq held open" "NOT pinned"))
        (rec! "file size: before / with the reader" "datalevin/kv" (/ sz1 1048576.0) "MB" :note (format "%.1f MB before" (/ sz0 1048576.0)))
        (when pinned (try (doall (take 5 pinned)) (catch Throwable _ nil)))))))

;; ---------------------------------------------------------------------------------------------- chat
(defn f-chat [{:keys [env pg]}]
  (facet "chat: 50,000 messages with full-text search"
    (let [rows (vec (for [k (range 1 50001)] [(wl/chat-sender k) (wl/chat-message k) k]))
          batches (vec (partition 100 rows))]
      (so/reset-chat! env) (pgx/exec! pg "select mc.reset_chat()")
      (let [[_ dl-ms] (timed (doseq [b batches] (so/chat-add-bulk! env b)))
            [_ pg-ms] (timed (doseq [b batches] (pgx/query pg "select mc.chat_add_bulk(?,?,?)" (pgx/int-array-of (map first b)) (pgx/text-array-of (map second b)) (pgx/long-array-of (map #(nth % 2) b)))))]
        (rec! "insert 50k messages (500 batches of 100, one commit each)" "datalevin" (/ 50000 (/ dl-ms 1000.0)) "msg/s" :better :higher)
        (rec! "insert 50k messages (500 batches of 100, one commit each)" "postgres" (/ 50000 (/ pg-ms 1000.0)) "msg/s" :better :higher))
      (let [words (vec (for [i (range 200)] (wl/vocab-word (rem (* i 7) 400))))
            dl (repeat-ms 1 3 #(doseq [wd words] (so/chat-search env wd 20)))
            pgr (repeat-ms 1 3 #(doseq [wd words] (pgx/query pg "select id from mc.chat_search(?,?)" wd 20)))]
        (rec! "full-text search, whole word, newest 20 (each word in ~1.7% of messages)" "datalevin" (/ (:median dl) 200) "ms/query")
        (rec! "full-text search, whole word, newest 20 (each word in ~1.7% of messages)" "postgres" (/ (:median pgr) 200) "ms/query" :note "round trip included"))
      (let [rare (str (wl/vocab-word 3) " " (wl/vocab-word 5))]
        nil)
      (let [dl (repeat-ms 1 3 #(dotimes [_ 500] (so/chat-recent env 50)))
            pgr (repeat-ms 1 3 #(dotimes [_ 500] (pgx/query pg "select id from mc.chat_recent(?)" 50)))]
        (rec! "last 50 messages" "datalevin" (/ (:median dl) 500) "ms/query")
        (rec! "last 50 messages" "postgres" (/ (:median pgr) 500) "ms/query" :note "round trip included"))
      (let [dl (repeat-ms 1 3 #(dotimes [_ 10] (so/chat-count-by-sender env)))
            pgr (repeat-ms 1 3 #(dotimes [_ 10] (pgx/query pg "select * from mc.chat_count_by_sender()")))]
        (rec! "messages per sender (full aggregation over 50k)" "datalevin" (/ (:median dl) 10) "ms/query")
        (rec! "messages per sender (full aggregation over 50k)" "postgres" (/ (:median pgr) 10) "ms/query")))))

;; ---------------------------------------------------------------------------------------------- inventory
(defn f-inv [{:keys [env pg]}]
  (facet "inventory (1000 players, 46 slots)"
    (let [ops ["swap" "merge" "quick" "drop"] n 20000
          pl (vec (for [i (range n)] (inc (rem (hash2 i 1 61) 1000)))) os (vec (for [i (range n)] (ops (rem (hash2 i 2 61) 4))))
          as (vec (for [i (range n)] (rem (hash2 i 3 61) 46))) bs (vec (for [i (range n)] (if (= (os i) "drop") (inc (rem (hash2 i 5 61) 40)) (rem (hash2 i 4 61) 46))))
          sub (fn [k] (mapv #(subvec % 0 k) [pl os as bs]))]
      ;; seed
      (so/reset-inv! env) (so/reset-inv-kv! env) (pgx/exec! pg "select mc.reset_inv()")
      (let [[_ a] (timed (so/inv-seed! env 1000)) [_ b] (timed (so/inv-seed-kv! env 1000)) [_ p] (timed (pgx/exec! pg "select mc.inv_seed(1000)"))]
        (rec! "seed 1000 players (about 28k stacks)" "datalevin/datalog" a "ms") (rec! "seed 1000 players (about 28k stacks)" "datalevin/kv" b "ms") (rec! "seed 1000 players (about 28k stacks)" "postgres" p "ms"))
      ;; join: load one player's inventory
      (let [dl (repeat-ms 1 3 #(dotimes [i 1000] (so/inv-load env (inc i))))
            kv (repeat-ms 1 3 #(dotimes [i 1000] (so/inv-load-kv env (inc i))))
            pgr (repeat-ms 1 3 #(dotimes [i 1000] (pgx/query pg "select * from mc.inv_load(?)" (inc i))))]
        (rec! "load one player's inventory (join)" "datalevin/datalog" (/ (* 1000 (:median dl)) 1000) "us/player")
        (rec! "load one player's inventory (join)" "datalevin/kv" (/ (* 1000 (:median kv)) 1000) "us/player")
        (rec! "load one player's inventory (join)" "postgres" (/ (* 1000 (:median pgr)) 1000) "us/player" :note "client round trip included"))
      ;; clicks in one transaction (db-native)
      (let [[a b c d] (sub 20000)
            dl (repeat-ms 0 3 #(so/inv-clicks-bulk! env a b c d))
            kv (repeat-ms 0 3 #(so/inv-clicks-bulk-kv! env a b c d))
            pgr (repeat-ms 0 3 #(pgx/exec! pg "select mc.inv_clicks_bulk(?,?,?,?)" (pgx/int-array-of a) (pgx/text-array-of b) (pgx/int-array-of c) (pgx/int-array-of d)))]
        (rec! "20k clicks inside one transaction" "datalevin/datalog" (/ (* 1000 (:median dl)) 20000) "us/click")
        (rec! "20k clicks inside one transaction" "datalevin/kv" (/ (* 1000 (:median kv)) 20000) "us/click")
        (rec! "20k clicks inside one transaction" "postgres" (/ (* 1000 (:median pgr)) 20000) "us/click" :note "PL/pgSQL loop"))
      ;; clicks, one commit each
      (let [dl (repeat-ms 0 2 #(dotimes [i 1000] (so/inv-click! env (pl i) (os i) (as i) (bs i))))
            kv (repeat-ms 0 2 #(dotimes [i 1000] (so/inv-click-kv! (:kv env) (pl i) (os i) (as i) (bs i))))
            pgr (repeat-ms 0 2 #(dotimes [i 1000] (pgx/exec! pg "select mc.inv_click(?,?,?,?)" (pl i) (os i) (as i) (bs i))))]
        (rec! "one click per commit" "datalevin/datalog" (/ (* 1000 (:median dl)) 1000) "us/click")
        (rec! "one click per commit" "datalevin/kv" (/ (* 1000 (:median kv)) 1000) "us/click")
        (rec! "one click per commit" "postgres" (/ (* 1000 (:median pgr)) 1000) "us/click" :note "client round trip included, sync_commit=off"))
      ;; who holds item 7 (a relational question over all players)
      (let [dl (repeat-ms 1 5 #(count (d/q '[:find ?p :in $ ?i :where [?e :inv/item ?i] [?e :inv/player ?p]] (d/db (:conn env)) 7)))
            kv (repeat-ms 1 5 #(count (so/inv-holders-kv env 7)))
            pgr (repeat-ms 1 5 #(count (pgx/query pg "select distinct player from mc.inv where item = 7")))
            _ (pgx/exec! pg "create index if not exists inv_item_idx on mc.inv (item)")
            pgi (repeat-ms 1 5 #(count (pgx/query pg "select distinct player from mc.inv where item = 7")))
            _ (pgx/exec! pg "drop index if exists mc.inv_item_idx")]
        (rec! "who holds item 7? (28k stacks)" "datalevin/datalog" (:median dl) "ms" :note "AVE index on every attribute")
        (rec! "who holds item 7? (28k stacks)" "datalevin/kv" (:median kv) "ms" :note "scan 1000 records")
        (rec! "who holds item 7? (28k stacks)" "postgres" (:median pgr) "ms" :note "no index on item")
        (rec! "who holds item 7? (28k stacks)" "postgres/indexed" (:median pgi) "ms" :note "with a btree on item")))))

;; ---------------------------------------------------------------------------------------------- dynamics
(defn f-dyn [{:keys [env pg]}]
  (facet "world dynamics (scheduled ticks, water burst, random ticks)"
    (let [kv (:kv env)
          prep (fn []
                 (w/fill! env kv 0 119 0 127 119 127 1) (w/fill! env kv 0 120 0 127 125 127 0)
                 (pg1 pg "select mc.fill(0,119,0,127,119,127,1)") (pg1 pg "select mc.fill(0,120,0,127,125,127,0)")
                 (w/fill! env kv 40 120 40 79 120 79 6) (pg1 pg "select mc.fill(40,120,40,79,120,79,6)")
                 (dyn/reset-sched! env) (pgx/exec! pg "select mc.reset_sched()")
                 (let [xs (vec (for [x (range 40 80) z (range 40 80)] x)) zs (vec (for [x (range 40 80) z (range 40 80)] z)) ys (vec (repeat 1600 120))]
                   (dyn/sched-add-bulk! env kv 1 xs ys zs)
                   (pgx/exec! pg "select mc.sched_add_bulk(?,?,?,?)" 1 (pgx/int-array-of xs) (pgx/int-array-of ys) (pgx/int-array-of zs)))
                 (w/drain-block-events! kv) (pgx/exec! pg "select mc.drain_block_events()"))
          runs (for [rep (range 4)]
                 (do (prep)
                     (let [dl-steps (vec (for [now (range 1 71)] (timed (d/with-transaction-kv [tx kv] (dyn/dyn-step! env tx now)))))
                           _ (w/drain-block-events! kv)
                           pg-steps (vec (for [now (range 1 71)] (timed (pg1 pg "select mc.dyn_step(?)" now))))
                           _ (pgx/exec! pg "select mc.drain_block_events()")]
                       {:dl dl-steps :pg pg-steps})))
          runs (vec runs)
          tot (fn [k] (median (for [r (rest runs)] (reduce + (map second (get r k))))))
          cells (fn [k] (reduce + (map first (get (last runs) k))))]
      (rec! "burst: 1600 sources spread for 70 ticks (total)" "datalevin" (tot :dl) "ms" :note (str (cells :dl) " blocks set"))
      (rec! "burst: 1600 sources spread for 70 ticks (total)" "postgres" (tot :pg) "ms" :note (str (cells :pg) " blocks set"))
      (rec! "burst: busiest single tick" "datalevin" (apply max (map second (:dl (last runs)))) "ms")
      (rec! "burst: busiest single tick" "postgres" (apply max (map second (:pg (last runs)))) "ms")
      (rec! "burst: identical blocks set per tick" "both" (if (= (map first (:dl (last runs))) (map first (:pg (last runs)))) 1 0) "1 = yes" :better :higher)
      ;; random ticks over a 16x16 chunk area
      (let [dl (repeat-ms 2 5 #(dotimes [i 20] (dyn/random-ticks! env kv (+ 1000 i) 0 0 15 15)))
            pgr (repeat-ms 2 5 #(dotimes [i 20] (pg1 pg "select mc.random_ticks(?,?,?,?,?)" (+ 1000 i) 0 0 15 15)))]
        (rec! "random ticks over 256 chunks (per tick)" "datalevin" (/ (:median dl) 20) "ms")
        (rec! "random ticks over 256 chunks (per tick)" "postgres" (/ (:median pgr) 20) "ms")))))
