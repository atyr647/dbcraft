(ns crash-child
  "Child process of the crash test: opens the store, commits one block change at a time and prints `ACK i` after each commit returns.  The parent kills it with SIGKILL."
  (:require [dlcraft.store :as st] [dlcraft.world :as w]))

(defn -main [dir profile & _]
  (let [env (st/open dir {:profile (keyword profile)}) kv (:kv env)]
    (println "READY") (flush)
    (loop [i 0]
      (w/set-block! env kv (rem i 256) 100 (rem (quot i 256) 256) 18)
      (println "ACK" i) (flush)
      (recur (inc i)))))
