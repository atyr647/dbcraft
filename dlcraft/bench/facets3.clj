(ns facets3
  "Durability, crash recovery, concurrent readers, memory."
  (:require [clojure.java.shell :as sh]
            [clojure.string :as str]
            [datalevin.core :as d]
            [dlcraft.codec :as c :refer [hash2]]
            [dlcraft.store :as st] [dlcraft.world :as w] [dlcraft.game :as g] [dlcraft.workload :as wl]
            [pgx] [util :as u :refer [timed repeat-ms median summarize]] [rec :refer [rec! facet]])
  (:import [java.util.concurrent.atomic AtomicLong AtomicBoolean]))

(defn pg1 [pg sql & ps] (apply pgx/query1 pg sql ps))
(def PGSH "/home/user/dbcraft/dlcraft/tools/pg.sh")
(defn sh! [& args] (apply sh/sh "bash" "-c" args))

;; ---------------------------------------------------------------------------------------------- commit latency
(defn- dl-profile-env [profile]
  (let [env (st/open (str "/srv/dlcraft/dl/dur-" (name profile)) {:fresh? true :profile profile})]
    (w/gen-area! (:kv env) 0 0 15 15) env))

(defn- lat-stats [ts] (let [s (summarize ts)] s))

(defn f-commit [{:keys [pg]}]
  (facet "durability: commit latency, one block edit per commit (2000 edits)"
    (let [n 2000 pos (fn [i] [(rem (hash2 (inc i) 1 21) 256) (+ 70 (rem (hash2 (inc i) 2 21) 20)) (rem (hash2 (inc i) 3 21) 256) (+ 1 (rem (hash2 (inc i) 4 21) 20))])]
      (doseq [[profile label] [[:sync "datalevin sync (LMDB default, full fsync per commit)"] [:nometasync "datalevin nometasync (one fsync, durability of the last commit relaxed)"]
                               [:nosync "datalevin nosync (no fsync)"] [:wal-strict "datalevin WAL strict"] [:wal-relaxed "datalevin WAL relaxed"]]]
        (let [env (dl-profile-env profile) kv (:kv env)]
          (dotimes [i 300] (let [[x y z s] (pos i)] (w/set-block! env kv x y z s)))
          (let [ts (vec (for [i (range n)] (let [[x y z s] (pos i)] (second (timed (w/set-block! env kv x y z s))))))
                s (lat-stats ts)]
            (rec! "set_block, one commit each: mean" (str "datalevin/" (name profile)) (* 1000 (:avg s)) "us")
            (rec! "set_block, one commit each: p99" (str "datalevin/" (name profile)) (* 1000 (:p99 s)) "us"))
          (st/close env)))
      (let [run (fn [setting]
                  (pgx/exec! pg setting)
                  (dotimes [i 300] (let [[x y z s] (pos i)] (pg1 pg "select mc.set_block(?,?,?,?)" x y z s)))
                  (lat-stats (vec (for [i (range n)] (let [[x y z s] (pos i)] (second (timed (pg1 pg "select mc.set_block(?,?,?,?)" x y z s))))))))
            strict (run "set synchronous_commit = on")
            relaxed (run "set synchronous_commit = off")]
        (pgx/exec! pg "alter system set fsync = off") (pgx/exec! pg "select pg_reload_conf()") (Thread/sleep 500)
        (let [unsafe (run "set synchronous_commit = on")]
          (pgx/exec! pg "alter system reset fsync") (pgx/exec! pg "select pg_reload_conf()")
          (rec! "set_block, one commit each: mean" "postgres/synchronous_commit=on" (* 1000 (:avg strict)) "us" :note "client round trip included")
          (rec! "set_block, one commit each: p99" "postgres/synchronous_commit=on" (* 1000 (:p99 strict)) "us")
          (rec! "set_block, one commit each: mean" "postgres/synchronous_commit=off" (* 1000 (:avg relaxed)) "us" :note "dbcraft's setting")
          (rec! "set_block, one commit each: p99" "postgres/synchronous_commit=off" (* 1000 (:p99 relaxed)) "us")
          (rec! "set_block, one commit each: mean" "postgres/fsync=off" (* 1000 (:avg unsafe)) "us")))
      (pgx/exec! pg "set synchronous_commit = off")
      (pg1 pg "select mc.drain_block_events()"))))

;; ---------------------------------------------------------------------------------------------- concurrent writers
(defn- run-threads [k f]
  (let [t0 (System/nanoTime)
        ths (vec (for [t (range k)] (doto (Thread. ^Runnable (fn [] (f t))) (.start))))]
    (doseq [^Thread t ths] (.join t))
    (/ (- (System/nanoTime) t0) 1e6)))

(defn f-writers [{:keys [pg]}]
  (facet "concurrent small writers (each thread: 1000 single-commit block edits in its own chunk)"
    (doseq [k [1 4 8]]
      (doseq [profile [:sync :nometasync :wal-strict]]
        (let [env (dl-profile-env profile) kv (:kv env)
              ms (run-threads k (fn [t] (dotimes [i 1000] (w/set-block! env kv (+ (* t 16) (rem i 16)) (+ 70 (rem (quot i 16) 20)) (rem (* i 7) 16) (+ 1 (rem i 20))))))]
          (rec! (format "%d writers" k) (str "datalevin/" (name profile)) (/ (* k 1000) (/ ms 1000.0)) "commits/s" :better :higher)
          (st/close env)))
      (doseq [[mode setting] [["on" "on"] ["off" "off"]]]
        (let [conns (vec (repeatedly k #(pgx/connect true)))
              _ (doseq [c conns] (pgx/exec! c (str "set synchronous_commit = " setting)))
              ms (run-threads k (fn [t] (let [c (nth conns t)] (dotimes [i 1000] (pgx/query1 c "select mc.set_block(?,?,?,?)" (+ (* t 16) (rem i 16)) (+ 70 (rem (quot i 16) 20)) (rem (* i 7) 16) (+ 1 (rem i 20)))))))]
          (rec! (format "%d writers" k) (str "postgres/synchronous_commit=" mode) (/ (* k 1000) (/ ms 1000.0)) "commits/s" :better :higher)
          (doseq [c conns] (.close c)))))
    (pg1 pg "select mc.drain_block_events()")))

;; ---------------------------------------------------------------------------------------------- kill -9
(defn- dl-crash-run [profile run-ms]
  (let [dir (str "/srv/dlcraft/dl/crash-" (name profile))
        e0 (st/open dir {:fresh? true :profile profile})
        _ (w/gen-area! (:kv e0) 0 0 15 15) _ (st/close e0)
        pb (doto (ProcessBuilder. ^java.util.List ["/home/user/dbcraft/dlcraft/tools/clj.sh" "-M" "-m" "crash-child" dir (name profile)]) (.redirectErrorStream false))
        proc (.start pb)
        rdr (java.io.BufferedReader. (java.io.InputStreamReader. (.getInputStream proc)))
        acked (AtomicLong. -1) ready (promise)
        reader (doto (Thread. ^Runnable (fn [] (loop [] (when-let [l (.readLine rdr)]
                                                          (cond (= l "READY") (deliver ready true)
                                                                (str/starts-with? l "ACK ") (.set acked (Long/parseLong (subs l 4))))
                                                          (recur))))) (.start))]
    (deref ready 120000 nil)
    (Thread/sleep (long run-ms))
    (let [last-acked (.get acked)]
      (.destroyForcibly proc) (.waitFor proc)
      (Thread/sleep 300)
      (let [last-acked (max last-acked (.get acked))
            [env ms] (timed (st/open dir {:profile profile}))
            kv (:kv env)
            present (count (filter (fn [i] (== 18 (w/get-block kv (rem i 256) 100 (rem (quot i 256) 256)))) (range (inc last-acked))))
            extra (count (filter (fn [i] (== 18 (w/get-block kv (rem i 256) 100 (rem (quot i 256) 256)))) (range (inc last-acked) (+ last-acked 50))))]
        (st/close env)
        {:acked (inc last-acked) :lost (- (inc last-acked) present) :unacked-applied extra :reopen-ms ms}))))

(defn- pg-crash-run [mode run-ms]
  (sh! (str PGSH " stop")) (sh! (str PGSH " start " mode))
  (let [pg (pgx/connect true)]
    (pgx/query pg "select mc.reset_world()") (pgx/query pg "select mc.gen_area(0,0,15,15)")
    (pgx/exec! pg "checkpoint") (.close pg))
  (let [acked (AtomicLong. -1) stop (AtomicBoolean. false)
        th (doto (Thread. ^Runnable (fn []
                                      (try (let [c (pgx/connect true)]
                                             (loop [i 0]
                                               (when-not (.get stop)
                                                 (pgx/query1 c "select mc.set_block(?,?,?,?)" (rem i 256) 100 (rem (quot i 256) 256) 18)
                                                 (.set acked i)
                                                 (recur (inc i)))))
                                           (catch Throwable _ nil)))) (.start))]
    (Thread/sleep (long run-ms))
    (let [last-acked (.get acked)]
      (sh! "pkill -9 -x postgres") (.set stop true) (.join th 5000)
      (let [last-acked (max last-acked (.get acked))
            [_ ms] (timed (do (sh! (str PGSH " start " mode))
                              (loop [k 0] (let [ok (try (with-open [c (pgx/connect true)] (pgx/query1 c "select 1") true) (catch Throwable _ false))] (when (and (not ok) (< k 600)) (Thread/sleep 50) (recur (inc k)))))))
            pg (pgx/connect true)
            present (long (pg1 pg "select count(*) from generate_series(0, ?) i where mc.get_block(i % 256, 100, (i / 256) % 256) = 18" last-acked))]
        (.close pg)
        {:acked (inc last-acked) :lost (- (inc last-acked) present) :restart-ms ms}))))

(defn f-crash [_]
  (facet "kill -9 (SIGKILL of the whole server process tree; the OS and its page cache survive)"
    (doseq [profile [:sync :nometasync :wal-relaxed]]
      (let [r (dl-crash-run profile 4000)]
        (println "   " (name profile) r)
        (rec! "acknowledged commits lost" (str "datalevin/" (name profile)) (:lost r) "commits" :note (format "%d acknowledged, reopen %.0f ms, %d unacknowledged edits also applied" (:acked r) (:reopen-ms r) (:unacked-applied r)))
        (rec! "restart after kill -9" (str "datalevin/" (name profile)) (:reopen-ms r) "ms")))
    (doseq [mode ["strict" "relaxed"]]
      (let [r (pg-crash-run mode 3000)]
        (println "   " mode r)
        (rec! "acknowledged commits lost" (str "postgres/" mode) (:lost r) "commits" :note (format "%d acknowledged; crash recovery + start %.0f ms" (:acked r) (:restart-ms r)))
        (rec! "restart after kill -9" (str "postgres/" mode) (:restart-ms r) "ms")))
    (sh! (str PGSH " stop")) (sh! (str PGSH " start relaxed"))))

;; ---------------------------------------------------------------------------------------------- concurrent readers vs the tick
(defn f-readers [{:keys [env pg]}]
  (facet "tick latency while other sessions read chunks (500 players, 20% moving)"
    (let [kv (:kv env) n 500 side 40 frac 0.2 ticks 150 warm 30]
      (doseq [readers [0 1 3]]
        (let [mir (wl/init-mirror n side)
              eids (vec (range 1 (inc n))) xs (vec (map #(aget ^doubles (:x mir) %) (range n))) ys (vec (repeat n 80.0)) zs (vec (map #(aget ^doubles (:z mir) %) (range n)))
              _ (g/reset-players! env) _ (pgx/query pg "select mc.reset_players()")
              _ (g/join-bulk! env eids xs ys zs)
              _ (pgx/query pg "select mc.join_bulk(?,?,?,?)" (pgx/int-array-of eids) (pgx/float-array-of xs) (pgx/float-array-of ys) (pgx/float-array-of zs))
              _ (g/vis-init! env) _ (pgx/query1 pg "select mc.vis_init()")
              stop (AtomicBoolean. false) dl-count (AtomicLong. 0) pg-count (AtomicLong. 0)
              dl-readers (vec (for [r (range readers)] (doto (Thread. ^Runnable (fn [] (loop [i 0] (when-not (.get stop) (w/chunk-packet kv (rem (hash2 i r 3) 32) (rem (hash2 i r 4) 16)) (.incrementAndGet dl-count) (recur (inc i)))))) (.start))))
              dl-t (vec (for [t (range (+ warm ticks))]
                          (let [moves (wl/tick-moves mir (inc t) frac)]
                            (g/inbox-push! env moves)
                            (let [[_ ms] (timed (g/server-tick! env))] (g/outbox-drain! env) ms))))
              _ (.set stop true) _ (doseq [^Thread t dl-readers] (.join t))
              dl-elapsed-note (.get dl-count)
              ;; PostgreSQL: same load, fresh mirror
              mir2 (wl/init-mirror n side)
              _ (.set stop false)
              pg-readers (vec (for [r (range readers)] (doto (Thread. ^Runnable (fn [] (let [c (pgx/connect true)]
                                                                                       (loop [i 0] (when-not (.get stop) (pgx/bytes-query c "select 1, mc.chunk_packet(?,?)" (rem (hash2 i r 3) 32) (rem (hash2 i r 4) 16)) (.incrementAndGet pg-count) (recur (inc i))))
                                                                                       (.close c)))) (.start))))
              pg-t (vec (for [t (range (+ warm ticks))]
                          (let [moves (wl/tick-moves mir2 (+ 1000 (inc t)) frac)]
                            (pgx/query pg "select mc.inbox_push(?,?)" (pgx/int-array-of (map first moves)) (pgx/bytea-array-of (map second moves)))
                            (let [[_ ms] (timed (pg1 pg "select mc.server_tick()"))] (pgx/bytes-query pg "select conn, data from mc.outbox_drain()") ms))))
              _ (.set stop true) _ (doseq [^Thread t pg-readers] (.join t))
              s-dl (summarize (drop warm dl-t)) s-pg (summarize (drop warm pg-t))]
          (rec! (format "%d concurrent chunk readers: tick avg" readers) "datalevin" (:avg s-dl) "ms")
          (rec! (format "%d concurrent chunk readers: tick p99" readers) "datalevin" (:p99 s-dl) "ms")
          (rec! (format "%d concurrent chunk readers: tick avg" readers) "postgres" (:avg s-pg) "ms")
          (rec! (format "%d concurrent chunk readers: tick p99" readers) "postgres" (:p99 s-pg) "ms")
          (when (pos? readers)
            (rec! (format "%d concurrent chunk readers: chunks served during the run" readers) "datalevin" dl-elapsed-note "chunks" :better :higher)
            (rec! (format "%d concurrent chunk readers: chunks served during the run" readers) "postgres" (.get pg-count) "chunks" :better :higher)))))))

;; ---------------------------------------------------------------------------------------------- memory
(defn snapshot-rss! [label]
  (System/gc)
  (rec! (str "resident memory, " label) "datalevin (JVM process)" (u/rss-mb) "MB" :note (format "heap used %d MB, JVM started with -Xms2g -Xmx4g" (quot (- (.totalMemory (Runtime/getRuntime)) (.freeMemory (Runtime/getRuntime))) 1048576)))
  (rec! (str "resident memory, " label) "postgres (postmaster + backends)" (pgx/pg-rss-mb) "MB" :note "shared_buffers 128MB (dbcraft's setting)"))
