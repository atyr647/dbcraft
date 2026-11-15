(ns pgx
  "Thin JDBC helpers for the PostgreSQL side (plain pgjdbc over TCP loopback; the server-side functions do the work)."
  (:import [java.sql Connection DriverManager PreparedStatement ResultSet Statement Types]
           [java.util Properties]))

(set! *warn-on-reflection* true)

(def ^:dynamic *url* "jdbc:postgresql://127.0.0.1:54340/dlbench?user=postgres&reWriteBatchedInserts=true&prepareThreshold=1")

(defn connect
  (^Connection [] (connect true))
  (^Connection [autocommit?]
   (let [c (DriverManager/getConnection *url*)]
     (.setAutoCommit c (boolean autocommit?))
     c)))

(defn- bind! [^PreparedStatement ps ^Connection c params]
  (doseq [[i p] (map-indexed vector params)]
    (let [i (inc (long i))]
      (cond
        (nil? p) (.setObject ps i nil)
        (instance? (Class/forName "[B") p) (.setBytes ps i ^bytes p)
        (integer? p) (if (<= Integer/MIN_VALUE (long p) Integer/MAX_VALUE) (.setInt ps i (int p)) (.setLong ps i (long p)))
        (float? p) (.setDouble ps i (double p))
        (string? p) (.setString ps i ^String p)
        (boolean? p) (.setBoolean ps i p)
        (and (map? p) (:array p)) (.setArray ps i (.createArrayOf c ^String (:array p)
                                                                  (if (= "bytea" (:array p))
                                                                    (into-array (Class/forName "[B") (:vals p))
                                                                    (to-array (:vals p)))))
        :else (.setObject ps i p)))))

(defn int-array-of [xs] {:array "int4" :vals (map int xs)})
(defn float-array-of [xs] {:array "float8" :vals (map double xs)})
(defn bytea-array-of [xs] {:array "bytea" :vals xs})
(defn text-array-of [xs] {:array "text" :vals xs})
(defn long-array-of [xs] {:array "int8" :vals (map long xs)})

(defn- row [^ResultSet rs n]
  (vec (for [i (range 1 (inc (long n)))] (.getObject rs (int i)))))

(defn query
  "rows as vectors"
  [^Connection c ^String sql & params]
  (with-open [ps (.prepareStatement c sql)]
    (bind! ps c params)
    (with-open [rs (.executeQuery ps)]
      (let [n (.getColumnCount (.getMetaData rs))]
        (loop [acc (transient [])]
          (if (.next rs) (recur (conj! acc (row rs n))) (persistent! acc)))))))

(defn query1 [c sql & params] (ffirst (apply query c sql params)))

(defn exec!
  "statement without result"
  [^Connection c ^String sql & params]
  (with-open [ps (.prepareStatement c sql)]
    (bind! ps c params)
    (.execute ps)))

(defn exec-script! [^Connection c ^String sql]
  (with-open [st (.createStatement c)] (.execute st sql)))

(defn bytes-query
  "rows of [int, bytea] fetched straight to byte arrays"
  [^Connection c ^String sql & params]
  (with-open [ps (.prepareStatement c sql)]
    (bind! ps c params)
    (with-open [rs (.executeQuery ps)]
      (loop [acc (transient [])]
        (if (.next rs) (recur (conj! acc [(.getInt rs 1) (.getBytes rs 2)])) (persistent! acc))))))

(defn server-ms
  "run `sql` and return the elapsed milliseconds as the SERVER measures them (statement_timestamp to clock_timestamp is not available for a
  single statement, so wrap it): [result ms]"
  [^Connection c ^String sql & params]
  (let [t0 (System/nanoTime) r (apply query c sql params)]
    [r (/ (- (System/nanoTime) t0) 1e6)]))

(defn pg-rss-mb
  "resident MB of the postmaster and its children"
  []
  (let [out (:out (clojure.java.shell/sh "bash" "-c" "cd /home/user/dbcraft/dlcraft && tools/pg.sh rss"))]
    (try (Long/parseLong (clojure.string/trim out)) (catch Exception _ nil))))
