# One writer thread gives 0 .. n-1 and then :done into a threaded channel.
# The main fiber reads it through ev/select beside a plain channel that a
# local fiber keeps feeding. A single writer's values should all arrive, in
# the order given. Each run that does not is reported: whether the reader
# hung, what it got, and what was in the channel when it stopped and after.
#
#   janet repro.janet              reads through ev/select
#   MODE=take janet repro.janet    reads with ev/take alone, as a control
#
# RUNS (default 20) and N (default 3000) set the runs and the values.
#
# Two experiments test the explanation in README.md:
#
#   QUIET=1 janet repro.janet      once the reader has all n values and no
#                                  :done, stops the feeder and goes on
#                                  selecting, with no other change
#   FEED=0.01 janet repro.janet    feeds the plain channel every FEED
#                                  seconds (default 0.0001)

(def take-only (= "take" (os/getenv "MODE")))
(def quiet (truthy? (os/getenv "QUIET")))
(def feed
  # PowerShell writes $env:FEED=0.01 in the locale's own way, as "0,01".
  (let [given (or (os/getenv "FEED") "0.0001")]
    (or (scan-number (string/replace-all "," "." given))
        (errorf "FEED must be a number of seconds, not %q" given))))
(def n (scan-number (or (os/getenv "N") "3000")))
(def runs (scan-number (or (os/getenv "RUNS") "20")))

(defn trial []
  (def tc (ev/thread-chan 128))
  (def pc (ev/chan 128))
  (var feeding true)
  (ev/spawn (while feeding (ev/give pc :tick) (ev/sleep feed)))
  (ev/thread
    (fn []
      (for i 0 n
        (ev/give tc i)
        (var x 0)
        (repeat 500 (++ x)))
      (ev/give tc :done))
    nil :n)
  (def got @[])
  (var numbers 0)
  (var quieted nil)
  (def hung
    (try
      (ev/with-deadline 10
        (while (not= :done (last got))
          (match (if take-only [:take tc (ev/take tc)] (ev/select tc pc))
            [:take c v] (when (= c tc)
                          (array/push got v)
                          (if (number? v) (++ numbers))))
          # QUIET: every value is in, the end marker is not. Stop feeding
          # the plain channel, and select on as before.
          (when (and quiet feeding (= numbers n) (not= :done (last got)))
            (set feeding false)
            (set quieted (os/clock :monotonic))))
        false)
      ([_] true)))
  (def done-after
    (if (and quieted (not hung)) (- (os/clock :monotonic) quieted)))
  # What the channel held when the reader stopped, and a moment after.
  (def held-at-stop (ev/count tc))
  (set feeding false)
  (ev/sleep 0.1)
  (def left @[])
  (while (pos? (ev/count tc)) (array/push left (ev/take tc)))
  # A feeder blocked on a full channel sees that feeding is over.
  (while (pos? (ev/count pc)) (ev/take pc))
  (def nums (filter number? got))
  @{:hung hung
    :got (length nums)
    :in-order (deep= nums (range (length nums)))
    :done-last (= :done (last got))
    :held-at-stop held-at-stop
    :left left
    :quieted (truthy? quieted)
    :done-after done-after})

(def tally @{:wrong 0 :out-of-order 0 :overtaken 0 :hung 0
             :quieted 0 :recovered 0})
(for r 0 runs
  (def res (trial))
  (def overtaken (and (res :done-last) (< (res :got) n)))
  (def wrong (not (and (not (res :hung)) (res :in-order) (res :done-last)
                       (= n (res :got)) (empty? (res :left)))))
  (if wrong (update tally :wrong inc))
  (unless (res :in-order) (update tally :out-of-order inc))
  (if overtaken (update tally :overtaken inc))
  (if (res :hung) (update tally :hung inc))
  (if (res :quieted) (update tally :quieted inc))
  (if (res :done-after) (update tally :recovered inc))
  (when (or wrong (res :quieted))
    (printf (string "run %d: hung %q, got %d of %d, in order %q, "
                    "held when the reader stopped %d, left after %q%s")
            r (res :hung) (res :got) n (res :in-order)
            (res :held-at-stop) (res :left)
            (cond
              (res :done-after)
              (string/format ", :done came %d microseconds after the feeder stopped"
                             (math/round (* 1e6 (res :done-after))))
              (res :quieted) ", the feeder stopped and :done still did not come"
              ""))))
(printf (string "janet %s-%s, %s, FEED %q%s: %d of %d runs wrong "
                "(%d out of order, %d with :done before its data, %d hung)%s")
        janet/version janet/build (if take-only "ev/take" "ev/select") feed
        (if quiet ", QUIET" "")
        (tally :wrong) runs (tally :out-of-order) (tally :overtaken) (tally :hung)
        (if quiet
          (string/format "; the feeder was stopped in %d, and :done came after it in %d"
                         (tally :quieted) (tally :recovered))
          ""))
(os/exit (if (zero? (tally :wrong)) 0 1))
