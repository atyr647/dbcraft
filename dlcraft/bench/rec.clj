(ns rec
  "Result recording.  Every number the report prints comes from here (and results/*.json)."
  (:require [util :as u]))

(def R (atom []))
(def ^:dynamic *facet* "?")

(defn rec!
  "engine: \"datalevin\" | \"datalevin/kv\" | \"datalevin/datalog\" | \"postgres\" | \"postgres/...\"; better: :lower or :higher"
  [metric engine value unit & {:keys [better note] :or {better :lower}}]
  (println (format "  %-52s %-20s %12s %s%s" metric engine (u/fmt value) unit (if note (str "   (" note ")") "")))
  (swap! R conj {:facet *facet* :metric metric :engine engine :value value :unit unit :better better :note note}))

(defmacro facet [name & body]
  `(binding [*facet* ~name]
     (println (str "\n### " ~name))
     (try ~@body
          (catch Throwable t# (println "FACET FAILED:" ~name (.getMessage t#)) (.printStackTrace t#)
                 (swap! R conj {:facet ~name :metric "FAILED" :engine "-" :value nil :unit (str (.getMessage t#)) :better :lower})))))
