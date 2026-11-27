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

(def take-only (= "take" (os/getenv "MODE")))
(def n (scan-number (or (os/getenv "N") "3000")))
(def runs (scan-number (or (os/getenv "RUNS") "20")))

(defn trial []
  (def tc (ev/thread-chan 128))
  (def pc (ev/chan 128))
  (var feeding true)
  (ev/spawn (while feeding (ev/give pc :tick) (ev/sleep 0.0001)))
  (ev/thread
    (fn []
      (for i 0 n
        (ev/give tc i)
        (var x 0)
        (repeat 500 (++ x)))
      (ev/give tc :done))
    nil :n)
  (def got @[])
  (def hung
    (try
      (ev/with-deadline 10
        (while (not= :done (last got))
          (match (if take-only [:take tc (ev/take tc)] (ev/select tc pc))
            [:take c v] (if (= c tc) (array/push got v))))
        false)
      ([_] true)))
  # What the channel held when the reader stopped, and a moment after.
  (def held-at-stop (ev/count tc))
  (set feeding false)
  (ev/sleep 0.1)
  (def left @[])
  (while (pos? (ev/count tc)) (array/push left (ev/take tc)))
  (def nums (filter number? got))
  @{:hung hung
    :got (length nums)
    :in-order (deep= nums (range (length nums)))
    :done-last (= :done (last got))
    :held-at-stop held-at-stop
    :left left})

(var bad 0)
(for r 0 runs
  (def res (trial))
  (unless (and (not (res :hung)) (res :in-order) (res :done-last)
               (= n (res :got)) (empty? (res :left)))
    (++ bad)
    (printf (string "run %d: hung %q, got %d of %d, in order %q, "
                    "held when the reader stopped %d, left after %q")
            r (res :hung) (res :got) n (res :in-order)
            (res :held-at-stop) (res :left))))
(printf "janet %s-%s, %s: %d of %d runs wrong"
        janet/version janet/build (if take-only "ev/take" "ev/select") bad runs)
(os/exit (if (zero? bad) 0 1))
