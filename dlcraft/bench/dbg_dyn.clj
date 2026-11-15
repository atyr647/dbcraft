(ns dbg-dyn
  (:require [datalevin.core :as d] [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.dyn :as dyn] [dlcraft.codec :as c] [pgx]))
(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/dbgdyn" {:fresh? true :profile :nometasync}) kv (:kv env) pg (pgx/connect true)
        q1 (fn [sql & ps] (apply pgx/query1 pg sql ps))]
    (pgx/query pg "select mc.reset_world()") (pgx/query pg "select mc.reset_sched()")
    (w/gen-area! kv 0 0 15 15) (q1 "select mc.gen_area(0,0,15,15)")
    (let [both (fn [a b c d e f s] (w/fill! env kv a b c d e f s) (q1 "select mc.fill(?,?,?,?,?,?,?)" a b c d e f s))]
      (both 0 119 0 127 119 127 1) (both 0 120 0 127 125 127 0) (both 40 120 40 79 120 79 6))
    (let [xs (vec (for [x (range 40 80) z (range 40 80)] x)) zs (vec (for [x (range 40 80) z (range 40 80)] z)) ys (vec (repeat 1600 120))]
      (dyn/sched-add-bulk! env kv 1 xs ys zs)
      (pgx/exec! pg "select mc.sched_add_bulk(?,?,?,?)" 1 (pgx/int-array-of xs) (pgx/int-array-of ys) (pgx/int-array-of zs)))
    (println "hash before:" (= (c/hex (w/world-hash kv)) (c/hex (q1 "select mc.world_hash()"))) "sched sizes" (dyn/sched-size kv) (q1 "select mc.sched_size()"))
    (doseq [now (range 1 40)]
      (let [a (d/with-transaction-kv [tx kv] (dyn/dyn-step! env tx now)) b (long (q1 "select mc.dyn_step(?)" now))]
        (when (not= a b) (println "step" now "dl" a "pg" b "sched" (dyn/sched-size kv) (q1 "select mc.sched_size()") "hash equal" (= (c/hex (w/world-hash kv)) (c/hex (q1 "select mc.world_hash()")))))))
    (println "final hash equal:" (= (c/hex (w/world-hash kv)) (c/hex (q1 "select mc.world_hash()"))))
    (st/close env) (.close pg) (shutdown-agents)))
