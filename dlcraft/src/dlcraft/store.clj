(ns dlcraft.store
  "One LMDB environment holds everything durable, through Datalevin's `datalog-kv`: raw key-value DBIs for the hot, binary, ordered data
  (sections, chunk versions, packet cache, positions, spatial cells, visibility, scheduled ticks, block events) next to the Datalog
  indexes for the relational data (chat, inventory, player profile).  A `with-transaction` over both is ONE atomic commit, the analogue of
  dbcraft's \"one tick = one transaction\".  Queues that PostgreSQL keeps in UNLOGGED tables (inbox, outbox) live in a second, in-memory-only LMDB environment."
  (:require [datalevin.core :as d])
  (:import [java.nio ByteBuffer]
           [java.util.concurrent.atomic AtomicLong]))

(set! *warn-on-reflection* true)

(def schema
  {:chat/id     {:db/valueType :db.type/long :db/unique :db.unique/identity}
   :chat/sender {:db/valueType :db.type/long}
   :chat/at     {:db/valueType :db.type/long}
   :chat/text   {:db/valueType :db.type/string :db/fulltext true}
   :inv/key     {:db/valueType :db.type/long :db/unique :db.unique/identity}   ; player * 64 + slot (one entity per non-empty slot)
   :inv/player  {:db/valueType :db.type/long}
   :inv/slot    {:db/valueType :db.type/long}
   :inv/item    {:db/valueType :db.type/long}
   :inv/count   {:db/valueType :db.type/long}
   :p/eid       {:db/valueType :db.type/long :db/unique :db.unique/identity}
   :p/name      {:db/valueType :db.type/string}
   :p/x         {:db/valueType :db.type/double :db/noindex true}
   :p/y         {:db/valueType :db.type/double :db/noindex true}
   :p/z         {:db/valueType :db.type/double :db/noindex true}
   :p/tick      {:db/valueType :db.type/long :db/noindex true}})

;; Durability profiles.  The first three keep LMDB's own commit protocol (copy-on-write B+tree, no log), the last two use Datalevin's WAL.
;;   :sync        LMDB default: data pages and both meta pages are fsynced at every commit.  Full ACID.            ~ PostgreSQL synchronous_commit = on
;;   :nometasync  one fsync per commit, last meta page flushed lazily: a system crash may undo the LAST commit, never corrupts (ACI, bounded D).   ~ synchronous_commit = off
;;   :nosync      no fsync at all (a process crash is safe, an OS crash can corrupt).                                ~ fsync = off
;;   :wal-strict / :wal-relaxed   Datalevin's write-ahead log.
(def profiles
  {:sync        {}
   :nometasync  {:kv-opts {:flags #{:nometasync}}}
   :nosync      {:kv-opts {:flags #{:nosync}}}
   :wal-strict  {:wal? true :wal-durability-profile :strict}
   :wal-relaxed {:wal? true :wal-durability-profile :relaxed}})

(def dbis ["sect" "chunk" "cache" "pos" "cell" "vis" "sched" "evq" "meta" "inv"])

(defrecord Env [conn kv mem evseq inseq outseq profile dir])

(defn- delete-tree! [^String dir]
  (let [f (java.io.File. dir)]
    (when (.exists f) (doseq [x (reverse (file-seq f))] (.delete ^java.io.File x)))))

(defn open
  "Open (creating) a store.  opts: :profile (default :nometasync), :fresh? (delete first), :mapsize MiB."
  [dir {:keys [profile fresh? mapsize] :or {profile :nometasync mapsize 16384}}]
  (when fresh? (delete-tree! dir))
  (let [popts (get profiles profile)
        conn (d/create-conn dir schema (-> popts (assoc-in [:kv-opts :mapsize] mapsize)
                                           (update-in [:kv-opts :flags] #(or % #{}))
                                           (assoc-in [:kv-opts :max-dbs] 64)))
        kv (d/datalog-kv conn)
        mem (d/open-kv nil {:inmemory? true :mapsize 2048})]
    (doseq [n dbis] (d/open-dbi kv n))
    (doseq [n ["inbox" "outbox"]] (d/open-dbi mem n))
    (->Env conn kv mem (AtomicLong. 0) (AtomicLong. 0) (AtomicLong. 0) profile dir)))

(defn close [^Env env]
  (d/close-kv (:mem env))
  (d/close (:conn env)))

(defn disk-bytes
  "Bytes on disk of the durable store."
  [^Env env]
  (reduce + (map #(.length ^java.io.File %) (filter #(.isFile ^java.io.File %) (file-seq (java.io.File. ^String (:dir env)))))))

;; ---------------------------------------------------------------------------------------------- keys
(defn skey ^bytes [^long cx ^long cz ^long sy]
  (let [bb (ByteBuffer/allocate 10)]
    (.putInt bb (unchecked-int (+ cx 2147483648))) (.putInt bb (unchecked-int (+ cz 2147483648)))
    (.putShort bb (unchecked-short (+ sy 32768)))
    (.array bb)))

(defn ckey ^bytes [^long cx ^long cz]
  (let [bb (ByteBuffer/allocate 8)]
    (.putInt bb (unchecked-int (+ cx 2147483648))) (.putInt bb (unchecked-int (+ cz 2147483648)))
    (.array bb)))

(defn key->chunk
  "[cx cz] from the first 8 bytes of a section or chunk key"
  [^bytes k]
  (let [bb (ByteBuffer/wrap k)] [(- (.getInt bb 0) 2147483648) (- (.getInt bb 4) 2147483648)]))
