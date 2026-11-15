(ns smoke-world
  (:require [datalevin.core :as d] [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.codec :as c]))
(defn t [label f] (let [t0 (System/nanoTime) r (f)] (println (format "%-40s %9.1f ms" label (/ (- (System/nanoTime) t0) 1e6))) r))
(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/smoke" {:fresh? true :profile :nometasync})
        kv (:kv env)]
    (t "gen 256 chunks (16x16)" #(w/gen-area! kv 0 0 15 15))
    (println "chunk(0,0) sha:" (c/hex (c/sha256 (w/chunk-payload kv 0 0))) "len" (alength ^bytes (w/chunk-payload kv 0 0)))
    (println "get_block 0 55 0:" (w/get-block kv 0 55 0) "  world hash:" (c/hex (w/world-hash kv)))
    (t "100k get_block" #(dotimes [i 100000] (w/get-block kv (mod (* i 7) 256) (- (mod (* i 13) 130) 64) (mod (* i 11) 256))))
    (println "set_block:" (w/set-block! env kv 5 70 5 20) (w/get-block kv 5 70 5) (w/set-block! env kv 5 70 5 20) (vec (w/drain-block-events! kv)))
    (t "10k set_block in one tx" #(d/with-transaction-kv [tx kv] (dotimes [i 10000] (w/set-block! env tx (mod (* i 7) 256) (+ 70 (mod i 5)) (mod (* i 11) 256) (+ 1 (mod i 20))))))
    (println "fill 64x64x64:" (t "fill 64^3" #(w/fill! env kv 0 0 0 63 63 63 18)))
    (t "chunk_packet x256 (cold build+cache)" #(dotimes [i 256] (w/chunk-packet kv (quot i 16) (mod i 16))))
    (t "chunk_packet x256 (cached)" #(dotimes [i 256] (w/chunk-packet kv (quot i 16) (mod i 16))))
    (println (w/count-states kv 0 0 31 31))
    (println (count (w/find-state kv 17 0 0 255 255)) "diamonds")
    (println "disk bytes" (st/disk-bytes env))
    (st/close env) (shutdown-agents)))
