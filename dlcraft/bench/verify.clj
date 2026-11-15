(ns verify
  "Equivalence checks: both engines get the same inputs and must produce the same bytes (SPEC).  Run before trusting any timing:
     tools/clj.sh -M -m verify"
  (:require [clojure.string :as str]
            [datalevin.core :as d]
            [dlcraft.codec :as c :refer [hash2]]
            [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.game :as g] [dlcraft.dyn :as dyn] [dlcraft.social :as so] [dlcraft.workload :as wl]
            [pgx]))

(def results (atom {:pass 0 :fail 0}))
(defn check! [label expected actual]
  (if (= expected actual)
    (do (swap! results update :pass inc) (println "PASS" label))
    (do (swap! results update :fail inc)
        (println "FAIL" label "\n   dl:" (pr-str (if (coll? expected) (take 12 expected) expected)) "\n   pg:" (pr-str (if (coll? actual) (take 12 actual) actual))))))

(defn pg-world-hash [pg] (c/hex ^bytes (pgx/query1 pg "select mc.world_hash()")))
(defn dl-world-hash [kv] (c/hex ^bytes (w/world-hash kv)))

(defn pg-events [pg]
  (vec (for [[_ kind x y z o n cnt] (pgx/query pg "select id, kind, x, y, z, old_state, new_state, cnt from mc.drain_block_events() order by id")]
         [(if (= kind "fill") 1 0) x y z o n cnt])))
(defn dl-events [kv] (vec (map vec (w/drain-block-events! kv))))

(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/verify" {:fresh? true :profile :nometasync}) kv (:kv env)
        pg (pgx/connect true)]
    (println "== reset PostgreSQL")
    (doseq [f ["mc.reset_world()" "mc.reset_players()" "mc.reset_sched()" "mc.reset_chat()" "mc.reset_inv()"]] (pgx/query pg (str "select " f)))

    (println "\n== 1. generation")
    (let [n-dl (w/gen-area! kv -3 -3 4 4) n-pg (pgx/query1 pg "select mc.gen_area(?,?,?,?)" -3 -3 4 4)]
      (check! "gen_area count" n-dl (long n-pg)))
    (check! "world_hash after gen" (dl-world-hash kv) (pg-world-hash pg))
    (doseq [[cx cz] [[0 0] [-1 -1] [3 -2] [-3 4]]]
      (check! (format "chunk_payload %d %d" cx cz) (c/hex (c/sha256 (w/chunk-payload kv cx cz))) (c/hex (c/sha256 ^bytes (pgx/query1 pg "select mc.chunk_payload(?,?)" cx cz))))
      (check! (format "chunk_packet %d %d" cx cz) (c/hex (c/sha256 (w/chunk-packet kv cx cz))) (c/hex (c/sha256 ^bytes (pgx/query1 pg "select mc.chunk_packet(?,?)" cx cz)))))
    (check! "chunk_packet of a missing chunk" nil (pgx/query1 pg "select mc.chunk_packet(?,?)" 100 100))

    (println "\n== 2. single edits (set_block)")
    (let [rnd (fn [i k m] (rem (hash2 i k 501) m))
          edits (for [i (range 3000)]
                  [(- (rnd i 1 128) 48) (- (rnd i 2 400) 72) (- (rnd i 3 128) 48) (rnd i 4 21)])
          dl (vec (for [[x y z s] edits] (w/set-block! env kv x y z s)))
          pgr (vec (for [[x y z s] edits] (pgx/query1 pg "select mc.set_block(?,?,?,?)" x y z s)))]
      (check! "set_block results" dl pgr)
      (check! "set_block events" (dl-events kv) (pg-events pg))
      (check! "world_hash after set_block" (dl-world-hash kv) (pg-world-hash pg))
      (check! "get_block samples" (vec (for [[x y z _] (take 200 edits)] (w/get-block kv x y z)))
              (vec (for [[x y z _] (take 200 edits)] (pgx/query1 pg "select mc.get_block(?,?,?)" x y z)))))

    (println "\n== 3. palette growth (21 states into one section, repack to 5 bits)")
    (doseq [s (range 21)]
      (w/set-block! env kv 8 8 8 s) (pgx/query1 pg "select mc.set_block(?,?,?,?)" 8 8 8 s)
      (w/set-block! env kv (+ 1 s) 9 8 (- 20 s)) (pgx/query1 pg "select mc.set_block(?,?,?,?)" (+ 1 s) 9 8 (- 20 s)))
    (check! "palette growth hash" (dl-world-hash kv) (pg-world-hash pg))
    (check! "palette growth events" (dl-events kv) (pg-events pg))

    (println "\n== 4. set_blocks (batch with duplicates and out-of-range)")
    (let [rnd (fn [i k m] (rem (hash2 i k 777) m))
          n 2500
          xs (vec (for [i (range n)] (- (rnd i 1 100) 30))) ys (vec (for [i (range n)] (- (rnd i 2 380) 66))) zs (vec (for [i (range n)] (- (rnd i 3 100) 30)))
          ss (vec (for [i (range n)] (rnd i 4 21)))
          dl (w/set-blocks! env kv xs ys zs ss)
          pgn (pgx/query1 pg "select mc.set_blocks(?,?,?,?)" (pgx/int-array-of xs) (pgx/int-array-of ys) (pgx/int-array-of zs) (pgx/int-array-of ss))]
      (check! "set_blocks changed" dl (long pgn))
      (check! "set_blocks events (array order)" (dl-events kv) (pg-events pg))
      (check! "world_hash after set_blocks" (dl-world-hash kv) (pg-world-hash pg)))

    (println "\n== 5. fill")
    (doseq [[label box s]
            [["tiny" [5 70 5 5 70 5] 19] ["one section whole" [16 0 16 31 15 31] 18] ["same again (no-op)" [16 0 16 31 15 31] 18]
             ["across sections" [-5 -10 -5 40 60 20] 20] ["inverted corners" [30 90 30 10 80 10] 1] ["slab" [-40 99 -40 70 99 70] 18]
             ["partly outside the world" [-60 -80 -60 -40 340 -40] 4] ["into air column" [0 100 0 15 200 15] 6]
             ["whole sections stacked" [64 -64 64 79 319 79] 0] ["big 64^3" [0 0 0 63 63 63] 14]]]
      (let [[x1 y1 z1 x2 y2 z2] box
            dl (w/fill! env kv x1 y1 z1 x2 y2 z2 s)
            pgn (pgx/query1 pg "select mc.fill(?,?,?,?,?,?,?)" x1 y1 z1 x2 y2 z2 s)]
        (check! (str "fill " label " changed") dl (long pgn))
        (check! (str "fill " label " events") (dl-events kv) (pg-events pg))
        (check! (str "fill " label " hash") (dl-world-hash kv) (pg-world-hash pg))))

    (println "\n== 6. chunk_packet cache invalidation")
    (let [a (c/hex (c/sha256 (w/chunk-packet kv 0 0))) b (c/hex (c/sha256 ^bytes (pgx/query1 pg "select mc.chunk_packet(?,?)" 0 0)))]
      (check! "packet before edit" a b)
      (w/set-block! env kv 3 3 3 5) (pgx/query1 pg "select mc.set_block(?,?,?,?)" 3 3 3 5)
      (w/drain-block-events! kv) (pg-events pg)
      (check! "packet after edit differs" true (not= a (c/hex (c/sha256 (w/chunk-packet kv 0 0)))))
      (check! "packet after edit" (c/hex (c/sha256 (w/chunk-packet kv 0 0))) (c/hex (c/sha256 ^bytes (pgx/query1 pg "select mc.chunk_packet(?,?)" 0 0)))))

    (println "\n== 7. analytics")
    (check! "count_states" (into {} (w/count-states kv -20 -20 70 70))
            (into {} (for [[s n] (pgx/query pg "select state, n from mc.count_states(?,?,?,?)" -20 -20 70 70)] [(long s) (long n)])))
    (check! "count_states one chunk" (into {} (w/count-states kv 16 16 31 31))
            (into {} (for [[s n] (pgx/query pg "select state, n from mc.count_states(?,?,?,?)" 16 16 31 31)] [(long s) (long n)])))
    (check! "find_state diamond" (w/find-state kv 17 -20 -20 70 70)
            (vec (for [[x y z] (pgx/query pg "select x, y, z from mc.find_state(?,?,?,?,?)" 17 -20 -20 70 70)] [(long x) (long y) (long z)])))

    (println "\n== 8. tick: players, visibility, movement, block broadcast")
    (let [n 200 side 6 mir (wl/init-mirror n side)
          eids (vec (range 1 (inc n))) xs (vec (map #(aget ^doubles (:x mir) %) (range n))) ys (vec (repeat n 80.0)) zs (vec (map #(aget ^doubles (:z mir) %) (range n)))]
      (g/reset-players! env)
      (pgx/query pg "select mc.reset_players()")
      (g/join-bulk! env eids xs ys zs)
      (pgx/query pg "select mc.join_bulk(?,?,?,?)" (pgx/int-array-of eids) (pgx/float-array-of xs) (pgx/float-array-of ys) (pgx/float-array-of zs))
      (check! "vis_init pairs" (g/vis-init! env) (long (pgx/query1 pg "select mc.vis_init()")))
      (w/drain-block-events! kv) (pg-events pg)
      (let [bad (atom nil) tot (atom 0)]
        (dotimes [t 60]
          (let [t' (inc t)
                moves (wl/tick-moves mir t' 0.3)
                ;; a few edits that the tick must broadcast
                edits (for [k (range 5)] [(rem (hash2 t' k 31) 96) (+ 60 (rem (hash2 t' k 32) 40)) (rem (hash2 t' k 33) 96) (rem (hash2 t' k 34) 21)])]
            (doseq [[x y z s] edits] (w/set-block! env kv x y z s) (pgx/query1 pg "select mc.set_block(?,?,?,?)" x y z s))
            (when (zero? (rem t 7)) (w/fill! env kv 10 70 10 14 72 14 (rem t' 21)) (pgx/query1 pg "select mc.fill(?,?,?,?,?,?,?)" 10 70 10 14 72 14 (rem t' 21)))
            (g/inbox-push! env moves)
            (pgx/query pg "select mc.inbox_push(?,?)" (pgx/int-array-of (map first moves)) (pgx/bytea-array-of (map second moves)))
            (let [gt-dl (g/server-tick! env) gt-pg (pgx/query1 pg "select mc.server_tick()")
                  rows-dl (g/outbox-drain! env)
                  rows-pg (pgx/bytes-query pg "select conn, data from mc.outbox_drain()")
                  dg-dl (wl/digest rows-dl) dg-pg (wl/digest rows-pg)]
              (swap! tot + (count rows-dl))
              (when (and (not @bad) (not= dg-dl dg-pg)) (reset! bad [t' dg-dl dg-pg gt-dl gt-pg]))
              (when (and (not @bad) (not= (long gt-dl) (long gt-pg))) (reset! bad [t' :game-time gt-dl gt-pg])))))
        (check! (str "60 ticks: per-tick outbox digests identical (" @tot " frames)") nil @bad))
      (check! "visible pairs" (g/visible-pairs kv) (long (pgx/query1 pg "select mc.visible_pairs()")))
      (check! "player digest" (g/player-digest kv) (long (pgx/query1 pg "select mc.player_digest()")))
      (check! "game time" (g/game-time kv) (long (pgx/query1 pg "select mc.game_time()"))))

    (println "\n== 9. dynamics: water burst, random ticks")
    (let [n 24 x0 20 z0 20 y 120]
      (doseq [[nm f] [["dl" #(w/fill! env kv 0 119 0 95 119 95 1)] ["pg" #(pgx/query1 pg "select mc.fill(?,?,?,?,?,?,?)" 0 119 0 95 119 95 1)]]] (f))
      (w/fill! env kv x0 y z0 (+ x0 n -1) y (+ z0 n -1) 6) (pgx/query1 pg "select mc.fill(?,?,?,?,?,?,?)" x0 y z0 (+ x0 n -1) y (+ z0 n -1) 6)
      (w/drain-block-events! kv) (pg-events pg)
      (let [xs (vec (for [x (range x0 (+ x0 n)) z (range z0 (+ z0 n))] x)) zs (vec (for [x (range x0 (+ x0 n)) z (range z0 (+ z0 n))] z)) ys (vec (repeat (* n n) y))]
        (dyn/reset-sched! env) (pgx/query pg "select mc.reset_sched()")
        (dyn/sched-add-bulk! env kv 1 xs ys zs)
        (pgx/query pg "select mc.sched_add_bulk(?,?,?,?)" 1 (pgx/int-array-of xs) (pgx/int-array-of ys) (pgx/int-array-of zs)))
      (let [diffs (atom [])]
        (doseq [now (range 1 41)]
          (let [a (d/with-transaction-kv [tx kv] (dyn/dyn-step! env tx now)) b (long (pgx/query1 pg "select mc.dyn_step(?)" now))]
            (when (not= a b) (swap! diffs conj [now a b]))))
        (check! "dyn_step changed counts identical over 40 steps" [] @diffs))
      (check! "sched size" (dyn/sched-size kv) (long (pgx/query1 pg "select mc.sched_size()")))
      (check! "hash after water" (dl-world-hash kv) (pg-world-hash pg))
      (check! "events after water" (dl-events kv) (pg-events pg))
      (let [diffs (atom [])]
        (doseq [now (range 1 31)]
          (let [a (dyn/random-ticks! env kv now 0 0 5 5) b (long (pgx/query1 pg "select mc.random_ticks(?,?,?,?,?)" now 0 0 5 5))]
            (when (not= a b) (swap! diffs conj [now a b]))))
        (check! "random_ticks changed counts identical over 30 steps" [] @diffs))
      (check! "hash after random ticks" (dl-world-hash kv) (pg-world-hash pg)))

    (println "\n== 10. chat")
    (let [rows (vec (for [k (range 1 2001)] [(wl/chat-sender k) (wl/chat-message k) k]))]
      (so/reset-chat! env)
      (so/chat-add-bulk! env rows)
      (pgx/query pg "select mc.chat_add_bulk(?,?,?)" (pgx/int-array-of (map first rows)) (pgx/text-array-of (map second rows)) (pgx/long-array-of (map #(nth % 2) rows)))
      (doseq [wd [(wl/vocab-word 7) (wl/vocab-word 123) (wl/vocab-word 399) "nosuchword"]]
        (check! (str "chat_search " wd) (so/chat-search env wd 25) (vec (map (comp long first) (pgx/query pg "select id from mc.chat_search(?,?)" wd 25)))))
      (check! "chat_recent" (so/chat-recent env 30) (vec (map (comp long first) (pgx/query pg "select id from mc.chat_recent(?)" 30))))
      (check! "chat_count_by_sender" (into {} (so/chat-count-by-sender env)) (into {} (for [[s n] (pgx/query pg "select sender, n from mc.chat_count_by_sender()")] [(long s) (long n)]))))

    (println "\n== 11. inventory")
    (let [ops ["swap" "merge" "quick" "drop"] n 3000
          pl (vec (for [i (range n)] (inc (rem (hash2 i 1 61) 100)))) os (vec (for [i (range n)] (ops (rem (hash2 i 2 61) 4))))
          as (vec (for [i (range n)] (rem (hash2 i 3 61) 46))) bs (vec (for [i (range n)] (if (= (os i) "drop") (inc (rem (hash2 i 5 61) 40)) (rem (hash2 i 4 61) 46))))]
      (so/reset-inv! env) (so/reset-inv-kv! env) (pgx/query pg "select mc.reset_inv()")
      (so/inv-seed! env 100) (so/inv-seed-kv! env 100) (pgx/query pg "select mc.inv_seed(?)" 100)
      (check! "inv seed digest (datalog)" (so/inv-digest env) (long (pgx/query1 pg "select mc.inv_digest()")))
      (check! "inv seed digest (kv)" (so/inv-digest-kv env) (long (pgx/query1 pg "select mc.inv_digest()")))
      (so/inv-clicks-bulk! env pl os as bs) (so/inv-clicks-bulk-kv! env pl os as bs)
      (pgx/query pg "select mc.inv_clicks_bulk(?,?,?,?)" (pgx/int-array-of pl) (pgx/text-array-of os) (pgx/int-array-of as) (pgx/int-array-of bs))
      (check! "inv digest after 3000 clicks (datalog)" (so/inv-digest env) (long (pgx/query1 pg "select mc.inv_digest()")))
      (check! "inv digest after 3000 clicks (kv)" (so/inv-digest-kv env) (long (pgx/query1 pg "select mc.inv_digest()")))
      (check! "inv_load p17" (vec (map vec (so/inv-load env 17))) (vec (for [[s i c] (pgx/query pg "select slot, item, count from mc.inv_load(?) order by slot" 17)] [(long s) (long i) (long c)]))))

    (println "\n==== verify:" @results)
    (st/close env) (.close pg) (shutdown-agents)
    (System/exit (if (zero? (:fail @results)) 0 1))))
