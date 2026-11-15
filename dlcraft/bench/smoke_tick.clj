(ns smoke-tick
  (:require [datalevin.core :as d] [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.game :as g] [dlcraft.workload :as wl]))
(defn -main [& [n frac]]
  (let [n (Long/parseLong (or n "500")) frac (Double/parseDouble (or frac "0.2")) side 40
        env (st/open "/srv/dlcraft/dl/smoke-tick" {:fresh? true :profile :nometasync})
        kv (:kv env) mir (wl/init-mirror n side)]
    (g/join-bulk! env (range 1 (inc n)) (map #(aget ^doubles (:x mir) %) (range n)) (repeat n 80.0) (map #(aget ^doubles (:z mir) %) (range n)))
    (println "pairs:" (g/vis-init! env))
    (let [times (volatile! [])]
      (dotimes [t 220]
        (g/inbox-push! env (wl/tick-moves mir (inc t) frac))
        (let [t0 (System/nanoTime) _ (g/server-tick! env) t1 (System/nanoTime)
              rows (g/outbox-drain! env) t2 (System/nanoTime)]
          (when (>= t 20) (vswap! times conj [(/ (- t1 t0) 1e6) (/ (- t2 t1) 1e6) (count rows)]))
          (when (= t 219) (println "last digest" (wl/digest rows)))))
      (let [ts (sort (map first @times)) m (count ts)]
        (println (format "tick ms: avg %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f | drain avg %.2f ms | rows/tick %.0f"
                         (/ (reduce + ts) m) (nth ts (quot m 2)) (nth ts (long (* m 0.95))) (nth ts (long (* m 0.99))) (last ts)
                         (/ (reduce + (map second @times)) m) (/ (reduce + (map #(nth % 2) @times)) (double m))))))
    (println "pairs now:" (g/visible-pairs kv) "digest" (g/player-digest kv) "game_time" (g/game-time kv))
    (st/close env) (shutdown-agents)))
