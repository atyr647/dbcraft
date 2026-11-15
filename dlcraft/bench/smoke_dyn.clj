(ns smoke-dyn
  (:require [datalevin.core :as d] [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.dyn :as dyn] [dlcraft.social :as so] [dlcraft.codec :as c]))
(defn t [label f] (let [t0 (System/nanoTime) r (f)] (println (format "%-44s %9.1f ms" label (/ (- (System/nanoTime) t0) 1e6))) r))
(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/smoke-dyn" {:fresh? true :profile :nometasync}) kv (:kv env)]
    (w/gen-area! kv 0 0 7 7)
    ;; flat stone platform at y=100..: fill y 99 stone, then 40x40 sources at y=100
    (w/fill! env kv 0 99 0 127 99 127 1)
    (w/fill! env kv 40 100 40 79 100 79 6)
    (dyn/sched-add-bulk! env kv 1 (for [x (range 40 80) z (range 40 80)] x) (for [x (range 40 80) z (range 40 80)] 100) (for [x (range 40 80) z (range 40 80)] z))
    (let [total (volatile! 0)]
      (t "water burst: 60 ticks" #(doseq [now (range 1 61)] (vswap! total + (d/with-transaction-kv [tx kv] (dyn/dyn-step! env tx now)))))
      (println "cells set:" @total "queue left:" (dyn/sched-size kv)))
    (println "states:" (w/count-states kv 0 0 127 127))
    (t "random ticks x20 (8x8 chunks)" #(dotimes [i 20] (dyn/random-ticks! env kv i 0 0 7 7)))
    ;; chat
    (let [env env]
      (so/reset-chat! env)
      (t "chat add 20000 (batches of 100)" #(doseq [b (partition 100 (range 20000))] (so/chat-add-bulk! env (for [k b] [(inc (rem k 500)) (str "w" (+ 1000 (rem k 400)) " w" (+ 1000 (rem (* k 7) 400)) " xyz") k]))))
      (t "search x100" #(dotimes [i 100] (so/chat-search env (str "w" (+ 1000 i)) 20)))
      (println "recent" (so/chat-recent env 3) "by sender (3)" (take 3 (so/chat-count-by-sender env))))
    (so/reset-inv! env)
    (t "inv seed 1000" #(so/inv-seed! env 1000))
    (println "digest" (so/inv-digest env) "p1 slots" (count (so/inv-load env 1)))
    (t "2000 clicks, each own tx" #(dotimes [i 2000] (so/inv-click! env (inc (rem i 1000)) (["swap" "merge" "quick" "drop"] (rem i 4)) (+ 9 (rem (* i 7) 36)) (+ 9 (rem (* i 11) 36)))))
    (println "digest after" (so/inv-digest env))
    (t "20000 clicks, one tx" (fn [] (so/inv-clicks-bulk! env (map (fn [i] (inc (rem i 1000))) (range 20000)) (map (fn [i] (["swap" "merge" "quick" "drop"] (rem i 4))) (range 20000)) (map (fn [i] (+ 9 (rem (* i 7) 36))) (range 20000)) (map (fn [i] (+ 9 (rem (* i 11) 36))) (range 20000)))))
    (so/reset-inv-kv! env) (t "inv-kv seed 1000" #(so/inv-seed-kv! env 1000))
    (println "kv digest" (so/inv-digest-kv env) "p1 slots" (count (so/inv-load-kv env 1)))
    (t "kv 20000 clicks, one tx" (fn [] (so/inv-clicks-bulk-kv! env (map (fn [i] (inc (rem i 1000))) (range 20000)) (map (fn [i] (["swap" "merge" "quick" "drop"] (rem i 4))) (range 20000)) (map (fn [i] (+ 9 (rem (* i 7) 36))) (range 20000)) (map (fn [i] (+ 9 (rem (* i 11) 36))) (range 20000)))))
    (println "kv digest after" (so/inv-digest-kv env) "holders of item 7:" (count (so/inv-holders-kv env 7)))
    (st/close env) (shutdown-agents)))
