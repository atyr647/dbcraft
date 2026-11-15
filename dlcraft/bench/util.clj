(ns util
  (:require [cheshire.core :as json]
            [clojure.string :as str]))

(defn now-ns ^long [] (System/nanoTime))
(defn ms-since ^double [^long t0] (/ (double (- (System/nanoTime) t0)) 1e6))

(defmacro timed
  "[result elapsed-ms]"
  [& body] `(let [t0# (System/nanoTime) r# (do ~@body)] [r# (/ (double (- (System/nanoTime) t0#)) 1e6)]))

(defn pct [sorted p] (let [n (count sorted)] (nth sorted (min (dec n) (long (Math/floor (* p n)))))))

(defn summarize
  "latency summary of a seq of ms values"
  [xs]
  (let [s (vec (sort xs)) n (count s)]
    (if (zero? n) {}
        {:n n :avg (/ (reduce + s) n) :p50 (pct s 0.5) :p95 (pct s 0.95) :p99 (pct s 0.99) :max (peek s) :min (first s)})))

(defn median [xs] (let [s (vec (sort xs)) n (count s)] (when (pos? n) (nth s (quot n 2)))))

(defn repeat-ms
  "run f `reps` times (after `warm` unmeasured), return {:median :best :runs [..]}"
  [warm reps f]
  (dotimes [_ warm] (f))
  (let [runs (vec (for [_ (range reps)] (second (timed (f)))))]
    {:median (median runs) :best (apply min runs) :runs runs}))

(defn rss-mb
  "resident set of this JVM, MB (NIO read: java.io readers call available(), which /proc rejects in this sandbox)"
  []
  (->> (java.nio.file.Files/readAllLines (java.nio.file.Paths/get "/proc/self/status" (make-array String 0)))
       (some #(second (re-find #"VmRSS:\s+(\d+) kB" %)))
       Long/parseLong (#(quot ^long % 1024))))

(defn round [x n] (when x (let [m (Math/pow 10 n)] (/ (Math/round (* (double x) m)) m))))

(defn fmt [x] (cond (nil? x) "-" (float? x) (cond (>= (Math/abs (double x)) 100) (format "%.0f" x) (>= (Math/abs (double x)) 10) (format "%.1f" x) :else (format "%.2f" x)) :else (str x)))

(defn write-json! [path data]
  (spit path (json/generate-string data {:pretty true})))
