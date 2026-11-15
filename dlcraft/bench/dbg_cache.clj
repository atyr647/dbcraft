(ns dbg-cache
  (:require [datalevin.core :as d] [dlcraft.store :as st] [dlcraft.social :as so] [dlcraft.workload :as wl]))
(defn t [f n] (let [t0 (System/nanoTime)] (dotimes [_ n] (f)) (/ (- (System/nanoTime) t0) 1e3 n)))
(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/dbgcache" {:fresh? true :profile :nometasync})]
    (doseq [b (partition 100 (range 1 20001))] (so/chat-add-bulk! env (for [k b] [(wl/chat-sender k) (wl/chat-message k) k])))
    (let [words (vec (for [i (range 200)] (wl/vocab-word (rem (* i 7) 400))))]
      (println "default cache:")
      (println "  search, 200 distinct words, 1st pass (us/query):" (t (let [i (atom -1)] #(so/chat-search env (words (swap! i (fn [x] (mod (inc x) 200)))) 20)) 200))
      (println "  search, same 200 words, 2nd pass:" (t (let [i (atom -1)] #(so/chat-search env (words (swap! i (fn [x] (mod (inc x) 200)))) 20)) 200))
      (println "  recent 50 x1000:" (t #(so/chat-recent env 50) 1000) " by-sender x20:" (t #(so/chat-count-by-sender env) 20))
      (d/datalog-index-cache-limit (d/db (:conn env)) 0)
      (println "cache limit 0:")
      (println "  search 200 words:" (t (let [i (atom -1)] #(so/chat-search env (words (swap! i (fn [x] (mod (inc x) 200)))) 20)) 200))
      (println "  recent 50 x1000:" (t #(so/chat-recent env 50) 1000) " by-sender x20:" (t #(so/chat-count-by-sender env) 20))
      (println "  by-sender after a write (cache must be invalid):" (do (so/chat-add! env 1 "w1a w1b" 0) (t #(so/chat-count-by-sender env) 5))))
    (st/close env) (shutdown-agents)))
