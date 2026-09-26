;;;; perf-lisp.lisp — the Lisp half of the R60 speed comparison.
;;;;
;;;; **RUNS IN A FRESH PROCESS, AND THAT IS THE POINT.** An earlier attempt at a
;;;; benchmark ran `apply-event` 20,000 times against the OPERATOR's live head and
;;;; wedged its eval channel — the equipment hazard, second occurrence. A benchmark
;;;; is the most dangerous probe there is, because its whole purpose is many
;;;; iterations. This file loads the system, measures, and exits: it never touches a
;;;; running head and needs no socket.
;;;;
;;;; The 25 decode frames are READ FROM THE FILE THE RUST PROBE WROTE, so both sides
;;;; parse byte-identical lines — two benchmarks that each build their own fixture
;;;; measure the two fixtures.
;;;;
;;;;   sbcl --script scripts/perf-lisp.lisp

(require :asdf)
(require :sb-bsd-sockets)
(require :sb-posix)

;; **THE ROOT IS THE REPO, not the script's own directory.** `--script
;; scripts/perf-lisp.lisp` makes `*load-truename*` a path in `scripts/`, so a
;; registry built from its directory pointed one level too low and asdf answered
;; `Component :LETICL not found`.
(let* ((here (or *load-truename* (uiop:getcwd)))
       (root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname here))))
  (asdf:initialize-source-registry
   `(:source-registry
     (:directory ,root)
     (:directory ,(merge-pathnames "vendor/alexandria/" root))
     (:directory ,(merge-pathnames "vendor/trivial-gray-streams/" root))
     (:directory ,(merge-pathnames "vendor/yason/" root))
     (:directory ,(merge-pathnames "vendor/anaphora/" root))
     (:directory ,(merge-pathnames "vendor/fiveam/" root))
     (:directory ,(merge-pathnames "vendor/asdf-flv/" root))
     (:directory ,(merge-pathnames "vendor/trivial-backtrace/" root))
     :inherit-configuration))
  (asdf:load-system :leticl))

(in-package :leticl)

(defvar *uns* internal-time-units-per-second
  "**PRINTED, ALWAYS.** A benchmark earlier in this session divided as though the
unit were a millisecond when it is a microsecond, and reported the renderer at
930,000 us — a number that would have decided the architecture wrongly.")

(defun us (thunk k)
  "Microseconds per call of THUNK over K iterations, after a warm-up."
  (dotimes (i (max 1 (floor k 10))) (declare (ignorable i)) (funcall thunk))
  (let ((t0 (get-internal-real-time)))
    (dotimes (i k) (funcall thunk))
    (/ (- (get-internal-real-time) t0) (* *uns* k 1e-6))))

(defmacro bench ((label k) &body body)
  `(format t "  ~a ~,4f us/call~%" ,label (us (lambda () ,@body) ,k)))

;;; --- the same inputs as the Rust probe -------------------------------------

(defparameter *ascii* "the quick brown fox jumps over the lazy dog and keeps going for a while")
(defparameter *cjk* "这是一个中文标识符和一个更长的句子，用来测量显示宽度")
(defparameter *emoji* "a 🎉 with 🇵🇱 flags 👨‍👩‍👧‍👦 and combining é")
(defparameter *code* "fn main() { let x: Vec<String> = v.iter().map(|s| s.to_string()).collect(); }")

(defun load-frames ()
  "The lines Rust wrote, as a list.

**IT RETURNS THEM — it does not set a global as well.** The first version did both,
and the caller's `(setf *frames* (load-frames))` then overwrote the list with the
function's own return value, which was NIL. The run went on to `(/ 0.0 0)`."
  (with-open-file (s "/tmp/leticl-probe/perf/frames.jsonl")
    (loop for line = (read-line s nil :eof)
          until (eq line :eof)
          unless (zerop (length line)) collect line)))

(defun tag-of (frame)
  (string-downcase (or (getf frame :event) (getf frame :frame) "?")))

;;; --- the run ---------------------------------------------------------------

(defun measure-width ()
  (format t "~&== width (string-width) ==~%")
  (dolist (pair (list (cons "ascii" *ascii*) (cons "cjk" *cjk*)
                      (cons "emoji" *emoji*) (cons "code" *code*)))
    (let ((s (cdr pair)))
      (format t "  ~6a chars=~3d cols=~3d  ~,4f us/call~%"
              (car pair) (length s) (string-width s)
              (us (lambda () (string-width s)) 200000))))
  (bench ("wrap-ranges(ascii,40)" 50000) (wrap-ranges *ascii* 40))
  (bench ("truncate-to-width(code,40)" 200000) (truncate-to-width *code* 40)))

(defun measure-progress ()
  (format t "~&== progress ==~%")
  (bench ("thousands(41200)" 200000) (thousands 41200))
  (bench ("duration(1240)" 200000) (duration 1240))
  (let ((p (list :total 41200 :cache 38100 :processed 25300 :time-ms 1240)))
    (bench ("progress-bar(p,40)" 200000) (progress-bar p 40))
    (bench ("prefill-line(p,120)" 200000) (prefill-line p 120))))

(defun measure-decode (frames)
  (format t "~&== frame decode (decode-frame, yason) ==~%")
  (let ((n (length frames)))
    (format t "  ~d kinds, ~d bytes~%"
            n (loop for l in frames sum (length l)))
    (let ((all (us (lambda () (dolist (l frames) (decode-frame l))) 200)))
      (format t "  decode, all ~2d kinds          ~10,4f us/all   ~8,4f us/kind~%"
              n all (/ all n))
      (format t "                                  => an 8000-event restore ~8,2f ms of decode~%"
              (/ (* 8000 all) n 1000.0)))
    (format t "  -- per kind (slowest 6) --~%")
    (let ((rows (loop for l in frames
                      collect (list (tag-of (decode-frame l))
                                    (us (lambda () (decode-frame l)) 20000)
                                    (length l)))))
      (dolist (r (subseq (sort rows #'> :key #'second) 0 (min 6 (length rows))))
        (format t "     ~26a len=~5d  ~9,4f us/frame~%" (first r) (third r) (second r))))))

(defun measure-apply (frames)
  ;; **ON A FRESH SESSION, IN THIS PROCESS** — never `*head*`. This is the half of
  ;; "reading a frame" that is not parsing it: deciding what it MEANS, which is the
  ;; seam R60's open question is about.
  (format t "~&== apply-event (folding a decoded frame into state) ==~%")
  (let* ((decoded (mapcar #'decode-frame frames))
         (n (length decoded)))
    (let ((all (us (lambda ()
                     (let ((s (make-session)))
                       (dolist (f decoded) (apply-event s f))))
                   200)))
      (format t "  apply, all ~2d kinds          ~10,4f us/all   ~8,4f us/kind~%"
              n all (/ all n))
      (format t "                                  => an 8000-event restore ~8,2f ms of apply~%"
              (/ (* 8000 all) n 1000.0)))))

(defun main ()
  (let ((frames (load-frames)))
    (format t "~&internal-time-units-per-second = ~d~%" *uns*)
    (format t "  frames loaded = ~d~%" (length frames))
    (measure-width)
    (measure-progress)
    (measure-decode frames)
    (measure-apply frames)))

(main)
