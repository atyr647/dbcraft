(ns facets1
  "World facets: generation, chunk reads, point ops, fills, analytics, storage, bulk import."
  (:require [datalevin.core :as d]
            [dlcraft.codec :as c :refer [hash2]]
            [dlcraft.store :as st] [dlcraft.world :as w]
            [pgx] [util :as u :refer [timed repeat-ms median]] [rec :refer [rec! facet]])
  (:import [java.nio ByteBuffer]))

(defn pg1 [pg sql & ps] (apply pgx/query1 pg sql ps))

;; ---------------------------------------------------------------------------------------------- generation
(defn f-gen [{:keys [env pg]}]
  (facet "world generation"
    (let [kv (:kv env)]
      ;; warm both engines on a region that is not measured
      (w/gen-area! kv -8 -8 -1 -1) (pg1 pg "select mc.gen_area(?,?,?,?)" -8 -8 -1 -1)
      (let [[_ dl1] (timed (w/gen-area! kv 0 0 15 15))
            [_ pg1'] (timed (pg1 pg "select mc.gen_area(?,?,?,?)" 0 0 15 15))
            [_ dl2] (timed (w/gen-area! kv 16 0 31 15))
            [_ pg2] (timed (pg1 pg "select mc.gen_area(?,?,?,?)" 16 0 31 15))]
        (rec! "generate 256 chunks (ms/chunk, run 1)" "datalevin" (/ dl1 256) "ms/chunk")
        (rec! "generate 256 chunks (ms/chunk, run 1)" "postgres" (/ pg1' 256) "ms/chunk")
        (rec! "generate 256 chunks (ms/chunk, run 2)" "datalevin" (/ dl2 256) "ms/chunk")
        (rec! "generate 256 chunks (ms/chunk, run 2)" "postgres" (/ pg2 256) "ms/chunk")
        (rec! "chunks per second (run 2)" "datalevin" (/ 256 (/ dl2 1000)) "chunks/s" :better :higher)
        (rec! "chunks per second (run 2)" "postgres" (/ 256 (/ pg2 1000)) "chunks/s" :better :higher)))))

;; ---------------------------------------------------------------------------------------------- chunk reads (the join burst)
(defn f-chunk-read [{:keys [env pg]}]
  (facet "chunk reads (a 16x16 join burst = 256 chunks, ~4.7 MB)"
    (let [kv (:kv env) cells (for [cx (range 16) cz (range 16)] [cx cz])
          pg-bytes #(pgx/query1 pg "select bx.packet_bytes(0,0,15,15)")]
      (let [r (repeat-ms 1 5 #(doseq [[cx cz] cells] (w/chunk-payload kv cx cz)))]
        (rec! "assemble 256 chunk payloads from sections" "datalevin" (:median r) "ms"))
      (let [r (repeat-ms 1 5 #(pgx/query1 pg "select bx.payload_bytes(0,0,15,15)"))]
        (rec! "assemble 256 chunk payloads from sections" "postgres" (:median r) "ms" :note "server side, nothing shipped"))
      (let [r (repeat-ms 0 5 #(do (d/clear-dbi kv "cache") (doseq [[cx cz] cells] (w/chunk-packet kv cx cz))))]
        (rec! "256 chunk packets, cache cold (build + store)" "datalevin" (:median r) "ms"))
      (let [r (repeat-ms 0 5 #(do (pgx/exec! pg "select bx.clear_cache()") (pg-bytes)))]
        (rec! "256 chunk packets, cache cold (build + store)" "postgres" (:median r) "ms"))
      (let [r (repeat-ms 2 10 #(doseq [[cx cz] cells] (w/chunk-packet kv cx cz)))]
        (rec! "256 chunk packets, cache warm" "datalevin" (:median r) "ms"))
      (let [r (repeat-ms 2 10 pg-bytes)]
        (rec! "256 chunk packets, cache warm, server side" "postgres" (:median r) "ms"))
      (let [r (repeat-ms 2 10 #(count (pgx/bytes-query pg "select cx * 100 + cz, mc.chunk_packet(cx, cz) from generate_series(0,15) cx, generate_series(0,15) cz")))]
        (rec! "256 chunk packets, cache warm, shipped to the client" "postgres" (:median r) "ms" :note "JDBC over loopback TCP"))
      (let [r (repeat-ms 2 10 #(let [out (java.util.ArrayList.)] (doseq [[cx cz] cells] (.add out (w/chunk-packet kv cx cz))) (.size out)))]
        (rec! "256 chunk packets, warm, delivered to the caller" "datalevin" (:median r) "ms" :note "in-process: the bytes are in the caller's heap"))
      ;; one packet, latency
      (let [r (repeat-ms 1 5 #(dotimes [i 2000] (w/chunk-packet kv (rem i 16) (rem (quot i 16) 16))))]
        (rec! "single cached chunk packet" "datalevin" (/ (* 1000 (:median r)) 2000) "us"))
      (let [r (repeat-ms 1 5 #(dotimes [i 2000] (pgx/query1 pg "select length(mc.chunk_packet(?,?))" (rem i 16) (rem (quot i 16) 16))))]
        (rec! "single cached chunk packet (client round trip)" "postgres" (/ (* 1000 (:median r)) 2000) "us" :note "JDBC over loopback TCP")))))

;; ---------------------------------------------------------------------------------------------- point ops
(defn f-point [{:keys [env pg]}]
  (facet "point operations (get_block / set_block)"
    (let [kv (:kv env) n 100000 span 256]
      (let [r (repeat-ms 2 5 #(d/with-transaction-kv [tx kv]
                                (loop [i 1 s 0] (if (<= i n) (recur (inc i) (+ s (w/get-block tx (rem (hash2 i 1 7) span) (- (rem (hash2 i 2 7) 130) 64) (rem (hash2 i 3 7) span)))) s))))]
        (rec! "get_block, 100k random, in one transaction" "datalevin" (/ (* 1000 (:median r)) n) "us/op"))
      (let [r (repeat-ms 2 5 #(pgx/query1 pg "select bx.point_get(?,?,?)" n span 7))]
        (rec! "get_block, 100k random, in one transaction" "postgres" (/ (* 1000 (:median r)) n) "us/op" :note "PL/pgSQL loop, logic inside the database"))
      (let [r (repeat-ms 1 5 #(d/with-transaction-kv [tx kv]
                                (dotimes [i 50000] (w/set-block! env tx (rem (hash2 (inc i) 1 9) span) (- (rem (hash2 (inc i) 2 9) 130) 64) (rem (hash2 (inc i) 3 9) span) (+ 1 (rem (hash2 (inc i) 4 9) 20))))))]
        (rec! "set_block, 50k random, in one transaction" "datalevin" (/ (* 1000 (:median r)) 50000) "us/op"))
      (let [r (repeat-ms 1 5 #(pgx/query1 pg "select bx.point_set(?,?,?)" 50000 span 9))]
        (rec! "set_block, 50k random, in one transaction" "postgres" (/ (* 1000 (:median r)) 50000) "us/op"))
      (w/drain-block-events! kv) (pgx/exec! pg "select mc.drain_block_events()")
      ;; one commit per call, the way a gateway-driven edit arrives
      (let [r (repeat-ms 1 3 #(dotimes [i 2000] (w/set-block! env kv (rem (hash2 (inc i) 1 11) span) (- (rem (hash2 (inc i) 2 11) 130) 64) (rem (hash2 (inc i) 3 11) span) (+ 1 (rem (hash2 (inc i) 4 11) 20)))))]
        (rec! "set_block, one commit per call (nometasync)" "datalevin" (/ (* 1000 (:median r)) 2000) "us/op"))
      (let [r (repeat-ms 1 3 #(dotimes [i 2000] (pgx/query1 pg "select mc.set_block(?,?,?,?)" (rem (hash2 (inc i) 1 11) span) (- (rem (hash2 (inc i) 2 11) 130) 64) (rem (hash2 (inc i) 3 11) span) (+ 1 (rem (hash2 (inc i) 4 11) 20)))))]
        (rec! "set_block, one commit per call (sync_commit=off), client round trip" "postgres" (/ (* 1000 (:median r)) 2000) "us/op" :note "JDBC over loopback TCP, autocommit"))
      (let [r (repeat-ms 1 3 #(dotimes [i 2000] (pgx/query1 pg "select mc.get_block(?,?,?)" (rem (hash2 (inc i) 1 11) span) (- (rem (hash2 (inc i) 2 11) 130) 64) (rem (hash2 (inc i) 3 11) span))))]
        (rec! "get_block, one statement per call, client round trip" "postgres" (/ (* 1000 (:median r)) 2000) "us/op" :note "what a client-driven design would pay"))
      (w/drain-block-events! kv) (pgx/exec! pg "select mc.drain_block_events()"))))

;; ---------------------------------------------------------------------------------------------- fill
(defn f-fill [{:keys [env pg]}]
  (facet "fill (set-based bulk edits)"
    (let [kv (:kv env)]
      (doseq [[label [x1 y1 z1 x2 y2 z2]] [["16^3 (one whole section)" [0 0 0 15 15 15]]
                                           ["40^3 (27 partial sections)" [3 3 3 42 42 42]]
                                           ["128x32x128 (128 whole sections, 524k blocks)" [0 0 0 127 31 127]]]]
        (let [k (atom 0)
              dl (repeat-ms 1 5 #(do (swap! k inc) (d/with-transaction-kv [tx kv] (w/fill! env tx x1 y1 z1 x2 y2 z2 (if (odd? @k) 18 20)))))
              k2 (atom 0)
              pgr (repeat-ms 1 5 #(do (swap! k2 inc) (pgx/query1 pg "select mc.fill(?,?,?,?,?,?,?)" x1 y1 z1 x2 y2 z2 (if (odd? @k2) 18 20))))]
          (rec! (str "fill " label) "datalevin" (:median dl) "ms")
          (rec! (str "fill " label) "postgres" (:median pgr) "ms")))
      (w/drain-block-events! kv) (pgx/exec! pg "select mc.drain_block_events()"))))

;; ---------------------------------------------------------------------------------------------- analytics
(defn f-analytics [{:keys [env pg]}]
  (facet "analytics (whole-region scans)"
    (let [kv (:kv env)]
      (let [dl (repeat-ms 1 5 #(w/count-states kv 0 0 255 255))
            pgr (repeat-ms 1 5 #(pgx/query pg "select * from mc.count_states(0,0,255,255)"))]
        (rec! "count blocks by type, 256x256 columns (256 chunks)" "datalevin" (:median dl) "ms")
        (rec! "count blocks by type, 256x256 columns (256 chunks)" "postgres" (:median pgr) "ms"))
      (let [dl (repeat-ms 1 5 #(w/count-states kv 5 5 100 100))
            pgr (repeat-ms 1 5 #(pgx/query pg "select * from mc.count_states(5,5,100,100)"))]
        (rec! "count blocks by type, unaligned 96x96" "datalevin" (:median dl) "ms")
        (rec! "count blocks by type, unaligned 96x96" "postgres" (:median pgr) "ms"))
      (let [dl (repeat-ms 1 5 #(count (w/find-state kv 17 0 0 255 255)))
            pgr (repeat-ms 1 5 #(count (pgx/query pg "select * from mc.find_state(17,0,0,255,255)")))]
        (rec! "find every diamond ore, 256x256 columns" "datalevin" (:median dl) "ms" :note (str (count (w/find-state kv 17 0 0 255 255)) " found"))
        (rec! "find every diamond ore, 256x256 columns" "postgres" (:median pgr) "ms")))))

;; ---------------------------------------------------------------------------------------------- bulk import
(defn- parse-sections
  "[[cx cz sy blob] ...] of a store, in key order"
  [kv]
  (vec (for [[^bytes k ^bytes v] (d/get-range kv "sect" [:all] :bytes :bytes false)]
         (let [bb (ByteBuffer/wrap k)]
           [(long (unchecked-int (bit-xor (.getInt bb 0) Integer/MIN_VALUE))) (long (unchecked-int (bit-xor (.getInt bb 4) Integer/MIN_VALUE))) (- (bit-and (long (.getShort bb 8)) 0xFFFF) 32768) v]))))

(defn- hex-bytea [^bytes b] (let [sb (StringBuilder. (+ 2 (* 2 (alength b))))] (.append sb "\\x") (doseq [x b] (.append sb (format "%02x" (bit-and (long x) 0xff)))) (str sb)))

(defn- pg-copy-rows [sections]
  "CSV text (tab separated) lines for mc.chunk_section"
  (let [sb (StringBuilder.)]
    (doseq [[cx cz sy ^bytes blob] sections]
      (let [sec (c/parse-blob blob) pal (vec (:palette sec))]
        (.append sb (str cx "\t" cz "\t" sy "\t" (:cnt sec) "\t{" (clojure.string/join "," pal) "}\t" (:bits sec) "\t" (hex-bytea (:data sec)) "\n"))))
    (str sb)))

(defn f-bulk [{:keys [env pg] :as ctx}]
  (facet "bulk import of a generated world (512 chunks)"
    (let [kv (:kv env) secs (parse-sections kv) chunks (distinct (map (juxt first second) secs))
          secs (vec (filter (fn [[cx cz _ _]] (and (>= cx 0) (<= cx 31) (>= cz 0) (<= cz 15))) secs))
          _ (println "  sections to import:" (count secs))
          dir "/srv/dlcraft/dl/bulk"
          ;; Datalevin: a fresh store, one transaction per 16 chunks vs the raw bulk call
          run-dl (fn [append?]
                   (let [e2 (st/open dir {:fresh? true :profile :nometasync})]
                     (let [[_ ms] (timed (doseq [part (partition-all (* 24 16) secs)]
                                           (d/transact-kv (:kv e2)
                                                          (vec (concat (for [[cx cz sy blob] part] (if append? [:put "sect" (st/skey cx cz sy) blob :bytes :bytes #{:append}] [:put "sect" (st/skey cx cz sy) blob :bytes :bytes]))
                                                                       (for [[cx cz] (distinct (map (juxt first second) part))] [:put "chunk" (st/ckey cx cz) (byte-array 8) :bytes :bytes]))))))]
                       (st/close e2) ms)))
          dl (run-dl false)
          dl-app (try (run-dl true) (catch Throwable t nil))
          ;; PostgreSQL: COPY (text format) into the section table
          pgc (pgx/connect false)
          cm (org.postgresql.copy.CopyManager. ^org.postgresql.core.BaseConnection (.unwrap pgc org.postgresql.core.BaseConnection))
          _ (pgx/exec! pgc "create temp table _chk as select 1") 
          run-pg (fn []
                   (pgx/exec! pgc "select mc.reset_world()")
                   (let [[txt fmt-ms] (timed (pg-copy-rows secs))
                         [_ copy-ms] (timed (do (.copyIn cm "copy mc.chunk (cx, cz) from stdin" (java.io.StringReader. (apply str (for [[cx cz] chunks] (str cx "\t" cz "\n")))))
                                                (.copyIn cm "copy mc.chunk_section (cx, cz, sy, block_count, palette, bits, data) from stdin" (java.io.StringReader. txt))
                                                (.commit pgc)))]
                     [fmt-ms copy-ms]))
          [pg-fmt pg-copy] (run-pg)
          [pg-fmt2 pg-copy2] (run-pg)]
      (rec! "import 512 chunks, from section blobs" "datalevin" dl "ms" :note "transact-kv, 16 chunks per transaction")
      (when dl-app (rec! "import 512 chunks, :append flag" "datalevin" dl-app "ms" :note "keys pre-sorted"))
      (rec! "import 512 chunks, COPY only" "postgres" pg-copy2 "ms" :note "text COPY of rows already formatted")
      (rec! "import 512 chunks, format rows + COPY" "postgres" (+ pg-fmt2 pg-copy2) "ms" :note "must unpack each blob into columns first")
      (.close pgc)
      ;; restore the shared bench world in PostgreSQL (gen again, not timed)
      (pg1 pg "select mc.gen_area(?,?,?,?)" -8 -8 -1 -1) (pg1 pg "select mc.gen_area(?,?,?,?)" 0 0 31 15)
      (println "  world restored in PostgreSQL"))))

;; ---------------------------------------------------------------------------------------------- storage
(defn f-storage [{:keys [env pg]}]
  (facet "storage"
    (let [kv (:kv env)
          _ (do (d/clear-dbi kv "cache") (pgx/exec! pg "select bx.clear_cache()"))
          pg-world #(+ (pg1 pg "select bx.relsize('mc.chunk')") (pg1 pg "select bx.relsize('mc.chunk_section')"))
          n-chunks (long (pg1 pg "select count(*) from mc.chunk"))]
      (rec! "chunks stored" "postgres" n-chunks "chunks")
      (rec! "world on disk, sections only, no packet cache" "datalevin" (/ (st/disk-bytes env) n-chunks) "bytes/chunk" :note "whole LMDB file incl. everything else in the store")
      (rec! "world on disk, sections only, no packet cache" "postgres" (/ (pg-world) n-chunks) "bytes/chunk" :note "chunk + chunk_section incl. indexes")
      (doseq [cx (range 16) cz (range 16)] (w/chunk-packet kv cx cz))
      (pg1 pg "select bx.packet_bytes(0,0,15,15)")
      (rec! "packet cache for 256 chunks" "postgres" (/ (pg1 pg "select bx.relsize('mc.chunk_cache')") 256) "bytes/chunk")
      ;; compaction
      (let [dl-before (st/disk-bytes env)
            dest "/srv/dlcraft/dl/compact-copy"
            _ (when (.exists (java.io.File. dest)) (doseq [f (reverse (file-seq (java.io.File. dest)))] (.delete ^java.io.File f)))
            [_ dl-ms] (timed (d/copy (:kv env) dest true))
            dl-after (reduce + (map #(.length ^java.io.File %) (filter #(.isFile ^java.io.File %) (file-seq (java.io.File. dest)))))
            pg-before (pg-world)
            [_ pg-ms] (timed (do (pgx/exec! pg "vacuum full mc.chunk_section") (pgx/exec! pg "vacuum full mc.chunk")))
            pg-after (pg-world)]
        (rec! "size before compaction (after the edits of the earlier facets)" "datalevin" (/ dl-before 1048576.0) "MB")
        (rec! "size after compaction (mdb_copy -c)" "datalevin" (/ dl-after 1048576.0) "MB" :note (format "%.0f ms" dl-ms))
        (rec! "size before compaction (sections only)" "postgres" (/ pg-before 1048576.0) "MB")
        (rec! "size after compaction (VACUUM FULL)" "postgres" (/ pg-after 1048576.0) "MB" :note (format "%.0f ms" pg-ms))))))
