;;;; term.lisp — raw mode, the alternate screen, the window size, output
;;;; streams. Mirrors crates/tui/src/term.rs: the enter/exit escape sequences
;;;; are copied byte-for-byte from term.rs:188 and :461 so a leticl head and a
;;;; Rust head leave the terminal in the same state.
;;;;
;;;; Everything here is SBCL builtins: sb-alien for the libc calls, sb-sys for
;;;; the fd-streams. No CFFI, no compiler (PLAN.md §4).

(in-package #:leticl)

(sb-alien:define-alien-type tcflag-t (sb-alien:unsigned 32))
(sb-alien:define-alien-type cc-t (sb-alien:unsigned 8))
(sb-alien:define-alien-type speed-t (sb-alien:unsigned 32))

;;; glibc struct termios: four flag words, a line byte, NCCS(=32) control
;;; chars, two speed words. sb-alien lays structs out like C does.
(sb-alien:define-alien-type termios
    (sb-alien:struct termios
      (c-iflag tcflag-t) (c-oflag tcflag-t) (c-cflag tcflag-t) (c-lflag tcflag-t)
      (c-line cc-t)
      (c-cc (sb-alien:array cc-t 32))
      (c-ispeed speed-t) (c-ospeed speed-t)))

(sb-alien:define-alien-type winsize
    (sb-alien:struct winsize
      (ws-col (sb-alien:unsigned 16))
      (ws-row (sb-alien:unsigned 16))
      (ws-xpixel (sb-alien:unsigned 16))
      (ws-ypixel (sb-alien:unsigned 16))))

(sb-alien:define-alien-routine ("tcgetattr" %tcgetattr) sb-alien:int
  (fd sb-alien:int)
  (termios-p (* termios)))

(sb-alien:define-alien-routine ("tcsetattr" %tcsetattr) sb-alien:int
  (fd sb-alien:int)
  (actions sb-alien:int)
  (termios-p (* termios)))

(sb-alien:define-alien-routine ("cfmakeraw" %cfmakeraw) sb-alien:void
  (termios-p (* termios)))

(sb-alien:define-alien-routine ("ioctl" %ioctl) sb-alien:int
  (fd sb-alien:int)
  (request sb-alien:unsigned-long)
  (argp (* winsize)))

(sb-alien:define-alien-routine ("isatty" %isatty) sb-alien:int
  (fd sb-alien:int))

(defconstant +tiocgwinsz+ #x5413)       ; Linux x86-64
(defconstant +tcsadrain+ 1)             ; glibc: drain output, then apply

(defparameter *saved-termios* (sb-alien:make-alien termios))
(defparameter *raw-termios* (sb-alien:make-alien termios))
(defparameter *raw-fd* nil)

(defun %copy-termios (from to)
  (dolist (s '(c-iflag c-oflag c-cflag c-lflag c-line c-ispeed c-ospeed))
    (setf (sb-alien:slot to s) (sb-alien:slot from s)))
  (dotimes (i 32)
    (setf (sb-alien:deref (sb-alien:slot to 'c-cc) i)
          (sb-alien:deref (sb-alien:slot from 'c-cc) i))))

(defun enter-raw (fd)
  "Raw mode with TCSADRAIN. cfmakeraw clears flags with &= on c_cflag, so it
needs the saved state copied in first — a zeroed c_cflag is not CS8."
  (when (minusp (%tcgetattr fd *saved-termios*))
    (error "tcgetattr failed on fd ~d — not a terminal?" fd))
  (%copy-termios *saved-termios* *raw-termios*)
  (%cfmakeraw *raw-termios*)
  (when (minusp (%tcsetattr fd +tcsadrain+ *raw-termios*))
    (error "tcsetattr failed on fd ~d" fd))
  (setf *raw-fd* fd))

(defun leave-raw ()
  (when (and *raw-fd* *saved-termios*)
    (%tcsetattr *raw-fd* +tcsadrain+ *saved-termios*)
    (setf *raw-fd* nil)))

(defmacro with-raw-mode ((&key (fd 0)) &body body)
  `(unwind-protect (progn (enter-raw ,fd) ,@body) (leave-raw)))

(defun terminal-size (fd)
  "Values cols rows; 80x24 when the ioctl fails (pipe, file, broken tty)."
  (sb-alien:with-alien ((ws winsize))
    (if (zerop (%ioctl fd +tiocgwinsz+ (sb-alien:addr ws)))
        (values (sb-alien:slot ws 'ws-col) (sb-alien:slot ws 'ws-row))
        (values 80 24))))

(defun make-tty-streams ()
  "Values in-stream out-stream on fd 0/1, UTF-8. Output is unbuffered: the
painter batches into strings and writes whole frames, so buffering between is
only latency (wire.rs flushes per frame for the same reason)."
  (values (sb-sys:make-fd-stream 0 :input t :element-type 'character
                                 :external-format :utf-8 :buffering :none)
          (sb-sys:make-fd-stream 1 :output t :element-type 'character
                                 :external-format :utf-8 :buffering :none)))

(defconstant +esc+ (code-char 27))

;;; term.rs:188 — alt screen, cursor hide, bracketed paste, mouse motion+SGR,
;;; steady block cursor.
(defun enter-tui (out)
  (write-string (format nil "~C[?1049h~C[?25l~C[?2004h~C[?1002h~C[?1006h~C[2 q"
                        +esc+ +esc+ +esc+ +esc+ +esc+ +esc+)
                out)
  (force-output out))

;;; term.rs:461 — the exact reverse, synchronized-output off first.
(defun leave-tui (out)
  (write-string (format nil "~C[?2026l~C[?1006l~C[?1002l~C[?2004l~C[0 q~C[?25h~C[?1049l"
                        +esc+ +esc+ +esc+ +esc+ +esc+ +esc+ +esc+)
                out)
  (force-output out))

(defmacro with-tui-terminal ((out &key (fd 1)) &body body)
  "Raw mode + alternate screen for the body; the terminal is given back
exactly as term.rs leaves it, on every exit path."
  (let ((out-sym (gensym "OUT")))
    `(let ((,out-sym ,out))
       (with-raw-mode (:fd ,fd)
         (unwind-protect (progn (enter-tui ,out-sym) ,@body)
           (leave-tui ,out-sym))))))

;;; Synchronized output (?2026): the painter wraps every frame so a fast
;;; stream of deltas never shows a half-painted screen.
(defun sync-begin (out) (write-string (format nil "~C[?2026h" +esc+) out))
(defun sync-end (out)   (write-string (format nil "~C[?2026l" +esc+) out))
