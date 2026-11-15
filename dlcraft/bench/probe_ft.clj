(ns probe-ft
  (:require [datalevin.core :as d] [dlcraft.store :as st]))
(defn -main [& _]
  (let [env (st/open "/srv/dlcraft/dl/probe-ft" {:fresh? true :profile :nometasync})
        conn (:conn env)]
    (d/transact! conn [{:chat/id 1 :chat/sender 7 :chat/text "w1a w2b w3c"}
                       {:chat/id 2 :chat/sender 8 :chat/text "w2b w9z the and"}
                       {:chat/id 3 :chat/sender 7 :chat/text "w3c w3c w4d"}])
    (doseq [q ['[:find ?id :in $ ?w :where [(fulltext $ ?w) [[?e ?a ?v]]] [?e :chat/id ?id]]
                '[:find ?id :in $ ?w :where [(fulltext $ ?w) [[?e ?a ?v]]] [?e :chat/id ?id]]]]
      (println (try (sort (d/q q (d/db conn) "w2b")) (catch Throwable t (str "ERR " (.getMessage t))))))
    (println "stopword search 'the':" (d/q '[:find ?id :in $ ?w :where [(fulltext $ ?w) [[?e ?a ?v]]] [?e :chat/id ?id]] (d/db conn) "the"))
    (println "recent:" (take 2 (map :v (d/rseek-datoms (d/db conn) :ave :chat/id))))
    (println "count by sender:" (d/q '[:find ?s (count ?e) :where [?e :chat/sender ?s]] (d/db conn)))
    (println "fulltext-datoms:" (map :e (d/fulltext-datoms (d/db conn) "w3c")))
    (st/close env) (shutdown-agents)))
