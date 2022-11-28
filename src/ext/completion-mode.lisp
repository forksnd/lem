(defpackage :lem.completion-mode
  (:use :cl :lem)
  (:export :make-completion-spec
           :make-completion-item
           :completion-item
           :completion-item-label
           :completion-item-detail
           :run-completion)
  #+sbcl
  (:lock t))
(in-package :lem.completion-mode)

(defvar *completion-context*)

(defclass completion-context ()
  ((spec
    :initarg :spec
    :reader completion-context-spec
    :type completion-spec)
   (last-items
    :initform '()
    :accessor completion-context-last-items)))

(defclass completion-spec ()
  ((function
    :initarg :function
    :reader spec-function)))

(defun make-completion-spec (function)
  (make-instance 'completion-spec :function function))

(defclass completion-item ()
  ((label
    :initarg :label
    :initform ""
    :reader completion-item-label
    :type string)
   (detail
    :initarg :detail
    :initform ""
    :reader completion-item-detail
    :type string)
   (start
    :initarg :start
    :initform nil
    :reader completion-item-start
    :type (or null point))
   (end
    :initarg :end
    :initform nil
    :reader completion-item-end
    :type (or null point))
   (focus-action
    :initarg :focus-action
    :initform nil
    :reader completion-item-focus-action
    :type (or null function))))

(defun make-completion-item (&rest initargs)
  (apply #'make-instance 'completion-item initargs))

(defvar *completion-mode-keymap* (make-keymap :name '*completion-mode-keymap*
                                              :undef-hook 'completion-self-insert))
(define-minor-mode completion-mode
    (:name "completion"
     :keymap *completion-mode-keymap*))

(define-key *completion-mode-keymap* 'next-line 'completion-next-line)
(define-key *completion-mode-keymap* "M-n"    'completion-next-line)
(define-key *completion-mode-keymap* "Tab"    'completion-narrowing-down-or-next-line)
(define-key *completion-mode-keymap* 'previous-line 'completion-previous-line)
(define-key *completion-mode-keymap* "M-p"    'completion-previous-line)
(define-key *completion-mode-keymap* 'move-to-end-of-buffer 'completion-end-of-buffer)
(define-key *completion-mode-keymap* 'move-to-beginning-of-buffer 'completion-beginning-of-buffer)
(define-key *completion-mode-keymap* "Return"    'completion-select)
(define-key *completion-mode-keymap* "Space"    'completion-insert-space-and-cancel)
(define-key *completion-mode-keymap* 'delete-previous-char 'completion-delete-previous-char)
(define-key *completion-mode-keymap* 'backward-delete-word 'completion-backward-delete-word)

(define-attribute completion-attribute
  (t :foreground "white" :background "RoyalBlue"))
(define-attribute non-focus-completion-attribute
  (:dark :foreground "white" :background "#444")
  (:light :foreground "black" :background "#DDD"))
(define-attribute detail-attribute
  (:dark :foreground "gray" :background "#444")
  (:light :foreground "#777" :background "#DDD"))

(defclass print-spec ()
  ((label-width
    :initarg :label-width
    :reader label-width)))

(defun compute-label-width (items)
  (loop :for item :in items
        :maximize (1+ (length (completion-item-label item)))))

(defun make-print-spec (items)
  (make-instance 'print-spec
                 :label-width
                 (compute-label-width items)))

(defmethod lem.popup-window:apply-print-spec ((print-spec print-spec) point item)
  (insert-string point " ")
  (insert-string point (completion-item-label item))
  (move-to-column point (label-width print-spec) t)
  (line-end point)
  (insert-string point "  ")
  (unless (alexandria:emptyp (completion-item-detail item))
    (insert-string point (completion-item-detail item)
                   :attribute 'detail-attribute)
    (insert-string point " ")))

(defparameter *limit-number-of-items* 100)

(defun completion-end ()
  (completion-mode nil)
  (lem-if:popup-menu-quit (implementation)))

(defun completion-again ()
  (run-completion-1 *completion-context* t))

(defun call-focus-action ()
  (alexandria:when-let* ((item (lem.popup-window:get-focus-item))
                         (fn (completion-item-focus-action item)))
    (funcall fn)))

(define-command completion-self-insert () ()
  (let ((c (insertion-key-p (last-read-key-sequence))))
    (cond (c (insert-character (current-point) c)
             (completion-again))
          (t (unread-key-sequence (last-read-key-sequence))
             (completion-end)))))

(define-command completion-delete-previous-char (n) ("p")
  (delete-previous-char n)
  (completion-again))

(define-command completion-backward-delete-word (n) ("p")
  (backward-delete-word n)
  (completion-again))

(define-command completion-next-line () ()
  (lem-if:popup-menu-down (implementation))
  (call-focus-action))

(define-command completion-previous-line () ()
  (lem-if:popup-menu-up (implementation))
  (call-focus-action))

(define-command completion-end-of-buffer () ()
  (lem-if:popup-menu-last (implementation))
  (call-focus-action))

(define-command completion-beginning-of-buffer () ()
  (lem-if:popup-menu-first (implementation))
  (call-focus-action))

(define-command completion-select () ()
  (lem-if:popup-menu-select (implementation)))

(define-command completion-insert-space-and-cancel () ()
  (insert-character (current-point) #\space)
  (completion-end))

(defun partial-match (strings)
  (when strings
    (let ((n nil))
      (loop :for rest :on strings
            :do (loop :for rest2 :on (cdr rest)
                      :for mismatch := (mismatch (first rest) (first rest2))
                      :do (and mismatch
                               (setf n
                                     (if n
                                         (min n mismatch)
                                         mismatch)))))
      n)))

(defun narrowing-down (last-items)
  (when last-items
    (let ((n (partial-match (mapcar #'completion-item-label last-items))))
      (multiple-value-bind (start end)
          (completion-item-range (current-point) (first last-items))
        (cond ((and n (plusp n) (< (count-characters start end) n))
               (completion-insert (current-point)
                                  (first last-items)
                                  n)
               (completion-again)
               t)
              ((alexandria:length= last-items 1)
               (completion-insert (current-point)
                                  (first last-items))
               (completion-again)
               t)
              (t
               nil))))))

(define-command completion-narrowing-down-or-next-line () ()
  (or (narrowing-down (completion-context-last-items *completion-context*))
      (completion-next-line)))

(defun completion-item-range (point item)
  (let ((start (or (completion-item-start item)
                   (with-point ((start point))
                     (skip-chars-backward start #'syntax-symbol-char-p)
                     start)))
        (end (or (completion-item-end item)
                 point)))
    (values start end)))

(defun completion-insert (point item &optional begin)
  (when item
    (multiple-value-bind (start end) (completion-item-range point item)
      (delete-between-points start end)
      (insert-string point (subseq (completion-item-label item) 0 begin)))))

(defun compute-completion-items (completion-spec)
  (let ((items (funcall (spec-function completion-spec) (current-point))))
    (when (and *limit-number-of-items*
               (< *limit-number-of-items* (length items)))
      (setf items (subseq items 0 *limit-number-of-items*)))
    items))

(defun run-completion-1 (completion-context repeat)
  (let ((items (compute-completion-items (completion-context-spec completion-context))))
    (setf (completion-context-last-items completion-context) items)
    (cond ((null items)
           (when repeat (completion-end)))
          ((and (not repeat) (null (rest items)))
           (completion-insert (current-point) (first items)))
          (repeat
           (lem-if:popup-menu-update (implementation)
                                     items
                                     :print-spec (make-print-spec items)))
          (t
           (lem-if:display-popup-menu
            (implementation)
            items
            :action-callback (lambda (item)
                               (completion-insert (current-point) item)
                               (completion-end))
            :print-spec (make-print-spec items)
            :focus-attribute 'completion-attribute
            :non-focus-attribute 'non-focus-completion-attribute
            :style '(:use-border nil :offset-y 1))
           (completion-mode t)
           (narrowing-down items)))))

(defun ensure-completion-spec (completion-spec)
  (typecase completion-spec
    (completion-spec
     completion-spec)
    (otherwise
     (make-completion-spec (alexandria:ensure-function completion-spec)))))

(defun run-completion (completion-spec)
  (let ((completion-context
          (make-instance 'completion-context
                         :spec (ensure-completion-spec completion-spec))))
    (setf *completion-context* completion-context)
    (run-completion-1 completion-context
                      nil)))
