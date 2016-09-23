;;; monitor.el --- Utilities for monitoring expressions.

;; Copyright (C) 2016 Ben Moon
;; Author: Ben Moon <guiltydolphin@gmail.com>
;; URL: https://github.com/guiltydolphin/monitor
;; Git-Repository: git://github.com/guiltydolphin/monitor.git
;; Created: 2016-08-17
;; Version: 0.2.0
;; Keywords: lisp, monitor, utility
;; Package-Requires: ((dash "2.13.0"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Monitor provides utilities for monitoring expressions.
;; A predicate-based system is used to determine when to run
;; specific functions - not unlike Emacs' built-in hooks (see Info node `Hooks').
;;
;; For example, if we wanted to print "foo" every time the value
;; of (point) changed in the current buffer, we could write:
;;
;;    (monitor-expression-value (point) (lambda () (print "foo")))
;;
;; A (rather convoluted) way of mimicking the functionality of the
;; standard `after-change-major-mode-hook' could be to use the
;; following expression:
;;
;;    (monitor-expression-value major-mode (...))
;;
;; Which would run whenever the value of `major-mode' changed.

;;; Code:

(require 'dash)

;;; CORE

(defgroup monitor nil
  "Monitor expressions."
  :group 'lisp
  :prefix 'monitor-)

;;;###autoload
(define-minor-mode monitor-mode
  "Minor mode for monitoring expressions."
  :group 'monitor
  (if monitor-mode
      (add-hook 'post-command-hook 'monitor--check-monitored nil t)
    (remove-hook 'post-command-hook 'monitor--check-monitored t)))

;;;###autoload
(define-globalized-minor-mode monitor-global-mode monitor-mode monitor-mode
  :group 'monitor)

(defvar monitor--monitored nil
  "Monitored expressions.")

(defun monitor--monitor (pred &rest fns)
  "After `post-command-hook' check PRED for a non-NIL value.
If PRED evaluates to non-NIL, then run each function in FNS."
  (let ((exist-fns (cdr (assoc pred monitor--monitored))))
    (dolist (fn fns) (unless (member fn exist-fns) (push fn exist-fns)))
    (monitor--monitored-update-functions pred exist-fns)))

(defun monitor--monitored-update-functions (pred fns)
  "Update the functions of PRED to FNS.
If FNS is nil then this deletes the entry at PRED."
  (setq monitor--monitored (--reject (equal (car it) pred) monitor--monitored))
  (when fns (push (cons pred fns) monitor--monitored)))

(defun monitor--monitored-remove-function (pred &rest fns )
  "Remove from PRED, any functions `equal' to a member of FNS."
  (let ((exist-fns (cdr (assoc pred monitor--monitored))))
    (setq exist-fns (--reject (member it fns) exist-fns))
    (monitor--monitored-update-functions pred exist-fns)))

(defun monitor--monitored-remove-pred (pred)
  "Remove PRED from the monitored predicates."
  (monitor--monitored-update-functions pred nil))

(defun monitor--check-monitored ()
  "Check each monitored expression."
  (dolist (pexp (copy-alist monitor--monitored))
    (when (condition-case var (eval (car pexp))
            (error (progn (message "error when evaluating %s (got %s)" (car pexp) (error-message-string var))
                          (monitor--monitored-remove-pred (car pexp)) nil)))
      (dolist (f (cdr pexp))
        (condition-case var (funcall f)
          (error (progn (message "error when executing %s (got %s)" f (error-message-string var))
                        (monitor--monitored-remove-function (car pexp) f))))))))

;;; EXPRESSIONS

(defvar monitor--watched-expressions-global nil
  "Alist of expressions known to monitor.
Values are the last known values.")

(defvar monitor--watched-expressions-buffer nil
  "Alist of variables known to monitor in the current buffer.
Values are the last known values.")
(make-variable-buffer-local 'monitor--watched-expressions-buffer)

(defun monitor--update-watched-expression (var val &optional local)
  "Update the known value of VAR to VAL.
Update the buffer-local value if LOCAL is non-nil."
  (let ((monitor-var (monitor--watched-expressions-var local)))
    (eval `(setq ,monitor-var (assq-delete-all var ,monitor-var)))
    (eval `(push (cons var val) ,monitor-var))))

(defun monitor--watched-expressions-var (&optional local)
  "Return the correct watch variables based on whether LOCAL is non-nil."
  (intern (format "monitor--watched-expressions-%s" (if local 'buffer 'global))))

(defun monitor--watched-expressions-last-value (var &optional local)
  "Return the last known value of VAR.
Return the buffer-local version if LOCAL is non-nil."
  (eval `(cdr (assoc var ,(monitor--watched-expressions-var local)))))

(defun monitor--monitor-in-mode (pred mode &rest fns)
  "Monitor PRED in `major-mode' MODE.
If MODE is nil then no mode restriction is applied.
FNS are run as in `monitor--monitor'."
  (let ((mode-pred (if mode `(and (eq major-mode ',mode) ,pred) pred)))
    (apply 'monitor--monitor mode-pred fns)))

(defun monitor--expression-value-changed (expr &optional local)
  "Check for a change in value of EXPR.
Update the known value of EXPR if it has changed.
If LOCAL is non-nil, check the buffer-local value."
  (let ((old-val (monitor--watched-expressions-last-value expr local))
        (new-val (eval expr)))
    (unless (eq old-val new-val)
      (monitor--update-watched-expression expr new-val local) t)))

(defun monitor--monitor-expression-value (expr fn &optional mode local)
  "Monitor EXPR and run FN if it's value is changed.
Optional MODE should specify a `major-mode'.
If LOCAL is non-nil then monitor the buffer-local value."
  (monitor--monitor-in-mode `(monitor--expression-value-changed ',expr ,local) mode fn))

;;;###autoload
(defmacro monitor-expression-value (expr fn &optional mode local)
  "Monitor EXPR and run FN if it's value is changed.
Optional MODE should specify a `major-mode'.
If LOCAL is non-nil then monitor the buffer-local value."
  `(monitor--monitor-expression-value ',expr ,fn ,mode ,local))

(defvar monitor--plist-attribute 'monitor-type
  "Key used to access a monitor definition from a symbol.")

(defun monitor--make-plist ()
  "Return a new 'empty' plist."
  ; there might be a better way to do this, but I haven't figured it out yet...
  (make-list 2 nil))

(defun monitor--create-monitor-plist (parent doc &rest args)
  "Return a plist representing an 'empty' monitor.
See `define-monitor' for the meaning of PARENT, DOC, and ARGS."
  `(:decl ,(or args (monitor--make-plist)) :meta (:parent ,parent :doc ,doc)))

(defun monitor--monitor-plist-equal-p (plist-a plist-b)
  "T if PLIST-A and PLIST-B are equal as monitor definitions.

This ignores meta attributes that may vary - such as :instances."
  (let ((meta-a (plist-get plist-a :meta))
        (meta-b (plist-get plist-b :meta)))
    (and (equal (plist-get meta-a :doc) (plist-get meta-b :doc))
         (equal (plist-get meta-a :parent) (plist-get meta-b :parent))
         (monitor--plist-equal-p (plist-get plist-a :decl) (plist-get plist-b :decl))
         t)))

(defun monitor-define-monitor (name parent doc &rest args)
  "Define a new monitor called NAME with parent PARENT.
The first argument NAME is the symbol that will be associated with the monitor
definition.  Each symbol may only have one associated monitor.
The second argument PARENT is the name of the parent monitor, in almost all
cases this should be a non-nil symbol, though NIL may be used if it is desirable
to have no parent.
The third argument DOC is a documentation string that should describe the purpose
of the monitor, as well as any monitor or instance options it introduces.

Lastly, the remaining arguments ARGS should be in the form of pairs of keywords
and values, the meaning and use of which may vary between monitors."
  (declare (doc-string 3))
  (when parent (unless (monitorp parent) (signal 'wrong-type-argument `(monitorp nilp ,parent))))
  (let ((monitor-plist (apply 'monitor--create-monitor-plist parent doc args)))
    (if (monitorp name)
        (unless (monitor--monitor-plist-equal-p monitor-plist (monitor--plist name))
          (monitor--remove-monitor name)
          (put name monitor--plist-attribute monitor-plist))
      (put name monitor--plist-attribute monitor-plist))))

(defalias 'define-monitor 'monitor-define-monitor)

(defun monitor--destroy-instances (monitor)
  "Remove all instances of MONITOR."
  (--each (monitor--instances monitor) (monitor--instance-destroy it)))

(defun monitor--remove-monitor (monitor)
  "Remove MONITOR's definition as a monitor."
  (monitor--disable monitor)
  (monitor--destroy-instances monitor)
  (put monitor monitor--plist-attribute nil))

(defun monitorp (monitor)
  "Return non-NIL if MONITOR is a monitor."
  (when (and (symbolp monitor) (get monitor monitor--plist-attribute)) t))

(defun monitor--plist (monitor)
  "Get MONITOR's associated plist."
  (unless (monitorp monitor) (signal 'wrong-type-argument `(monitorp ,monitor)))
  (get monitor monitor--plist-attribute))

(defun monitor--meta-props (monitor)
  "Return the meta properties of MONITOR."
  (plist-get (monitor--plist monitor) :meta))

(defun monitor--meta-get (monitor prop)
  "From MONITOR get the value of the meta property PROP."
  (plist-get (monitor--meta-props monitor) prop))

(defun monitor--meta-put (monitor prop value)
  "Set MONITOR's meta PROP property to VALUE."
  (plist-put (monitor--meta-props monitor) prop value))

(defun monitor--parent (monitor)
  "Return the name of the parent monitor of MONITOR (or NIL)."
  (monitor--meta-get monitor :parent))

(defun monitor--decl-props (monitor)
  "Return the decl properties of MONITOR."
  (plist-get (monitor--plist monitor) :decl))

(defun monitor--decl-get (monitor prop)
  "From MONITOR get the value of the decl property PROP."
  (let ((decls (monitor--decl-props monitor)))
    (if (plist-member decls prop)
        (plist-get decls prop)
      (-when-let (parent (monitor--parent monitor))
        (monitor--decl-get parent prop)))))

(defun monitor--decl-put (monitor prop value)
  "Set MONITOR's decl PROP property to VALUE."
  (plist-put (monitor--decl-props monitor) prop value))

(defun monitor--enabled-p (monitor)
  "T if MONITOR is enabled."
  (monitor--meta-get monitor :enabled))

(defun monitor--disabled-p (monitor)
  "T if MONITOR is disabled."
  (not (monitor--enabled-p monitor)))

(defun monitor--enable (monitor)
  "Enable MONITOR."
  (unless (monitor--enabled-p monitor)
    (monitor-run-monitor-option monitor :enable monitor)
    (monitor--meta-put monitor :enabled t)))

(defun monitor--disable (monitor)
  "Disable MONITOR."
  (unless (monitor--disabled-p monitor)
    (monitor-run-monitor-option monitor :disable monitor)
    (monitor--meta-put monitor :enabled nil)))

(defun monitor-run-monitor-option (monitor prop &rest args)
  "Run MONITOR's PROP option with ARGS as arguments.

Don't do anything if the option is not a function."
  (let ((f (monitor--decl-get monitor prop)))
    (apply 'monitor--fn-run f args)))

(defun monitor--has-option-p (monitor prop)
  "T if MONITOR provides the PROP option."
  (plist-member (monitor--decl-props monitor) prop))

(defun monitor-run-monitor-option-with-parents (monitor prop &rest args)
  "Run MONITOR's PROP option with ARGS as arguments.

Do the same for each parent in MONITOR's heirarchy."
  (list (when (monitor--has-option-p monitor prop)
          (apply 'monitor-run-monitor-option monitor prop args))
        (when (monitor--parent monitor)
          (apply 'monitor-run-monitor-option-with-parents (monitor--parent monitor) prop args))))

(defun monitor--instances (monitor)
  "Return existing instances of MONITOR."
  (monitor--meta-get monitor :instances))

(defun monitor--instance-existing-p (instance)
  "T if INSTANCE is equal to an existing instance."
  (let ((instances (monitor--instances (monitor--instance-monitor instance))))
    (let ((-compare-fn 'monitor--instance-equal)) (-contains-p instances instance))))

(defun monitor--instance-has-option-p (instance prop)
  "T if INSTANCE provides the PROP option."
  (plist-member (monitor--instance-args instance) prop))

(define-error 'monitor-missing-required-option "missing required option")

(defun monitor--instance-require-option (instance prop)
  "Check that INSTANCE provides the PROP option, fail otherwise."
  (unless (monitor--instance-has-option-p instance prop)
    (signal 'monitor-missing-required-option (list prop))))

(defun monitor-instance-create (monitor &rest args)
  "Define a new monitor instance.
MONITOR is the monitor to watch.
ARGS is a list of (usually key-value) arguments that define the instance.

The keys that have an effect in ARGS varies between monitors, see the
documentation for MONITOR (and its parents) for which keys are applicable."
  (declare (indent 1))
  (let ((instance `(:args (:monitor ,monitor ,@args) :meta ,(monitor--make-plist))))
    (unless (monitor--instance-existing-p instance)
      (monitor-run-monitor-option-with-parents monitor :validate instance)
      (monitor-run-monitor-option monitor :create instance)
      (let ((instances (monitor--instances monitor)))
        (monitor--meta-put monitor :instances (cons instance instances))))
      instance))

(defalias 'monitor 'monitor-instance-create)

(defun monitor--instance-destroy (instance)
  "Destroy INSTANCE."
  (when (monitor--instance-existing-p instance)
    (let ((monitor (monitor--instance-monitor instance)))
      (monitor-run-monitor-option monitor :destroy instance)
      (let ((instances (monitor--instances monitor)))
        (monitor--meta-put monitor :instances (--reject (monitor--instance-equal it instance) instances))))))

(defun monitor--instance-p (instance)
  "T if INSTANCE is a monitor instance."
  (when (and (listp instance) (monitorp (plist-get (plist-get instance :args) :monitor))) t))

(defun monitor--instance-args (instance)
  "Return the arguments used in the creation of INSTANCE."
  (unless (monitor--instance-p instance) (signal 'wrong-type-argument `(monitor-instance-p ,instance)))
  (plist-get instance :args))

(defun monitor--instance-monitor (instance)
  "Return the monitor used in the creation of INSTANCE."
  (unless (monitor--instance-p instance) (signal 'wrong-type-argument `(monitor-instance-p ,instance)))
  (plist-get (monitor--instance-args instance) :monitor))

(defun monitor--plist-equal-p (plist-a plist-b)
  "T if PLIST-A and PLIST-B have equal key-values."
  (let ((keys-a (-sort 'string-lessp (-filter 'keywordp plist-a)))
        (keys-b (-sort 'string-lessp (-filter 'keywordp plist-b))))
    (and (equal keys-a keys-b)
         (--all-p (equal (plist-get plist-a it) (plist-get plist-b it)) keys-a))))

(defun monitor--instance-equal (instance-a instance-b)
  "T if INSTANCE-A is equal (as a monitor instance) to INSTANCE-B."
  (let* ((args-a (monitor--instance-args instance-a))
         (args-b (monitor--instance-args instance-b)))
    (and (equal (monitor--instance-monitor instance-a) (monitor--instance-monitor instance-b))
         (monitor--plist-equal-p args-a args-b))))

(defun monitor--instance-get-arg (instance prop)
  "Return the value of INSTANCE's PROP property."
  (let ((args (monitor--instance-args instance)))
    (plist-get args prop)))

(defun monitor--instance-get (instance prop)
  "Return the value of INSTANCE's PROP property.

If INSTANCE does not provide PROP, use the associated monitor's."
  (let ((args (monitor--instance-args instance)))
    (if (plist-member args prop) (plist-get args prop)
      (monitor--decl-get (monitor--instance-monitor instance) prop))))

(defun monitor--instance-meta-plist (instance)
  "Return INSTANCE's meta property list."
  (plist-get instance :meta))

(defun monitor--instance-get-meta (instance prop)
  "Return the value of INSTANCE's PROP meta property."
  (let ((plist (monitor--instance-meta-plist instance)))
    (plist-get plist prop)))

(defun monitor--instance-put-meta (instance prop value)
  "Set the value of INSTANCE's meta property PROP to VALUE."
  (let ((plist (monitor--instance-meta-plist instance)))
    (plist-put plist prop value)))

(defun monitor--instance-run (instance prop &rest args)
  "Run INSTANCE's PROP function with ARGS as arguments.

Will not error if PROP does not represent a valid function."
  (let ((f (monitor--instance-get-arg instance prop)))
    (apply 'monitor--fn-run f args)))

(defun monitor--function-or-function-list-p (object)
  "Return T if OBJECT is a function or a list of functions."
  (or (functionp object) (and (listp object) (-all-p 'functionp object))))

(defun monitor--fn-run (fn &rest args)
  "Run FN with ARGS as arguments and return the result.

If FN is a list of functions, then run each element with ARGS as arguments and
return a list of the results."
  (unless (monitor--function-or-function-list-p fn)
    (signal 'wrong-type-argument `(monitor--function-or-function-list-p ,fn)))
  (if (functionp fn) (apply fn args)
    (--map (apply it args) fn)))

;;;; Monitors

;;; Instance lists

(defun monitor--instance-list-add-instance (list instance)
  "Add to LIST the instance INSTANCE if it is not already present."
  (if (let ((-compare-fn 'monitor--instance-equal))
        (-contains-p list instance)) list (push instance list)))

(defun monitor--instance-list-remove-instance (list instance)
  "Remove from LIST the monitor instance INSTANCE."
  (--reject (monitor--instance-equal it instance) list))

;;; Instance alists

(defun monitor--instance-alist-instances (alist key)
  "Return the instances in ALIST associated with KEY."
  (cdr (assoc key alist)))

(defun monitor--instance-alist-keys (alist)
  "Return the keys of ALIST."
  (-map 'car alist))

(defun monitor--instance-alist-update-instances (alist key instances)
  "Replace the instances in ALIST at KEY with INSTANCES.

Add a new element to ALIST if there isn't already one with key KEY.
If INSTANCES is NIL then remove the element at KEY entirely."
  (let ((existing (assoc key alist)))
    (if instances
        (if existing (setf (cdr existing) instances)
          (push (cons key instances) alist))
      (setq alist (--reject (equal (car it) key) alist)))
    alist))

(defun monitor--instance-alist-add-instance (alist key instance)
  "In ALIST add at KEY the instance INSTANCE if it is not already present."
  (let ((instances (monitor--instance-alist-instances alist key)))
    (monitor--instance-alist-update-instances
     alist key (monitor--instance-list-add-instance instances instance))))

(defun monitor--instance-alist-remove-instance (alist key instance)
  "Remove from ALIST at KEY the instance INSTANCE if it is present."
  (monitor--instance-alist-update-instances alist key
                                            (--reject (monitor--instance-equal it instance)
                                                      (monitor--instance-alist-instances alist key))))

(define-monitor 'base nil
  "Base monitor which should be used as the parent for new, sparse monitors."
  :enable nil
  :disable nil)

(define-monitor 'trigger 'base
  "Monitor that supports instantaneous triggering."
  :trigger 'monitor--trigger-trigger
  :validate 'monitor--trigger-validate)

(defun monitor--trigger-trigger (instance &rest args)
  "Run the :trigger function of INSTANCE with ARGS as arguments."
  (apply 'monitor--instance-run instance :trigger args))

(defun monitor--trigger-validate (instance)
  "Validate INSTANCE."
  (monitor--instance-require-option instance :trigger))

(defvar monitor--hook-instances nil
  "Instances of the 'hook monitor, along with their hooks.")

(define-monitor 'hook 'trigger
  "Monitor for triggering on hooks."
  :enable 'monitor--hook-enable
  :disable 'monitor--hook-disable
  :create 'monitor--hook-create
  :destroy 'monitor--hook-destroy
  :validate 'monitor--hook-validate)

(defun monitor--hook-run-instances (monitor hook)
  "Run MONITOR's instances for HOOK."
  (--each (monitor--instance-alist-instances monitor--hook-instances hook)
    (monitor-run-monitor-option monitor :trigger it)))

(defun monitor--hook-enable (monitor)
  "Enable MONITOR."
  (--each (monitor--instance-alist-keys monitor--hook-instances)
    (add-hook it (lambda () (monitor--hook-run-instances monitor it)))))

(defun monitor--hook-disable (monitor)
  "Disable MONITOR."
  (--each (monitor--instance-alist-keys monitor--hook-instances)
    (remove-hook it (lambda () (monitor--hook-run-instances monitor it)))))

(defun monitor--hook-create (instance)
  "Create INSTANCE."
  (setq monitor--hook-instances
        (monitor--instance-alist-add-instance monitor--hook-instances
                                              (monitor--instance-get-arg instance :hook)
                                              instance)))

(defun monitor--hook-destroy (instance)
  "Destroy INSTANCE."
  (setq monitor--hook-instances
        (monitor--instance-alist-remove-instance monitor--hook-instances
                                                 (monitor--instance-get-arg instance :hook)
                                                 instance)))

(defun monitor--hook-validate (instance)
  "Validate INSTANCE."
  (monitor--instance-require-option instance :hook))

(define-monitor 'expression-value 'trigger
  "Monitor expression values."
  :check 'monitor--expression-value-check
  :validate 'monitor--expression-value-validate)

(defun monitor--expression-value-check (instance)
  "Check INSTANCE."
  (-let* ((expr (monitor--instance-get-arg instance :expr))
          (old (monitor--instance-get-meta instance :value))
          (new (eval expr)))
    (when (monitor--expression-value-instantiated instance)
      (when (monitor--instance-run instance :pred old new)
        (monitor--instance-run instance :trigger)))
  (monitor--expression-value-update-value instance new)))

(defun monitor--expression-value-update-value (instance value)
  "Update INSTANCE's known (tracked) value to VALUE."
  (monitor--instance-put-meta instance :value value))

(defun monitor--expression-value-instantiated (instance)
  "T if an expression check has already been performed for INSTANCE."
  (plist-member (monitor--instance-meta-plist instance) :value))

(defun monitor--expression-value-validate (instance)
  "Validate INSTANCE."
  (monitor--instance-require-option instance :expr)
  (monitor--instance-require-option instance :pred))



(provide 'monitor)
;;; monitor.el ends here
