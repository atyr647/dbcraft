(ns dlcraft.golden
  "Prints golden vectors that the PostgreSQL implementation must reproduce (spec/golden.edn)."
  (:require [dlcraft.codec :as c] [dlcraft.gen :as g] [clojure.pprint]))

(defn chunk-payload-hash [cx cz]
  (let [h (g/column-heights cx cz)
        bl (for [sy (range -4 20)]
             (let [{:keys [cnt bits palette data]} (g/gen-section cx cz sy h)] (c/blob cnt bits palette data)))
        total (reduce + (map alength bl))
        out (java.nio.ByteBuffer/allocate total)]
    (doseq [^bytes b bl] (.put out b))
    {:len total :sha256 (c/hex (c/sha256 (.array out)))}))

(defn -main [& _]
  (let [pts [[0 0] [1 0] [-1 -1] [100 -250] [-12345 6789] [33554 -4000] [15 16] [-16 -17]]
        golden {:hash2 (vec (for [[a b s] [[0 0 0] [1 2 3] [-5 7 11] [1000 -1000 1337] [-123456 654321 7] [20000000 -20000000 1338]]]
                              [a b s (c/hash2 a b s)]))
                :oct (vec (for [[x z] pts] [x z (g/oct x z 6 1337) (g/oct x z 4 1338)]))
                :height (vec (for [[x z] pts] [x z (g/height x z)]))
                :block-at (vec (for [[x z] [[0 0] [-1 -1] [100 -250]]
                                     y [-64 -40 -17 0 20 31 55 61 62 63 64 70 95]]
                                 [x y z (g/block-at x y z (g/height x z))]))
                :chunks (into {} (for [[cx cz] [[0 0] [-1 -1] [5 -7] [-300 120]]] [[cx cz] (chunk-payload-hash cx cz)]))
                :varint [[0 "00"] [127 "7f"] [128 "8001"] [300 "ac02"] [2097151 "ffff7f"] [2147483647 "ffffffff07"]]}]
    (spit "spec/golden.edn" (with-out-str (clojure.pprint/pprint golden)))
    (println "wrote spec/golden.edn")))
