;;; quite-roots-tests.el --- Tests for the per-host quite roots in config.el  -*- lexical-binding: t; -*-

;; config.el is a configuration, not a package, and loading it needs quite and
;; the rest of the setup. So these tests read only the named forms out of it
;; and evaluate those.

(require 'ert)
(require 'seq)
(require 'cl-lib)

(defconst quite-roots-tests--config
  (expand-file-name "../config.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun quite-roots-tests--load (kind name)
  "Evaluate the top-level KIND form (`defun' or `defvar') NAME from config.el."
  (with-temp-buffer
    (insert-file-contents quite-roots-tests--config)
    (goto-char (point-min))
    (catch 'found
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) kind) (eq (cadr form) name))
                (throw 'found (eval form t)))))
        (end-of-file (error "No %s %s in config.el" kind name))))))

(quite-roots-tests--load 'defvar 'dag/quite-host-roots)
(quite-roots-tests--load 'defun 'dag/quite-roots)
(quite-roots-tests--load 'defun 'dag/quite-descriptor)
(quite-roots-tests--load 'defun 'dag/quite-overlay-descriptor)

(defmacro quite-roots-tests--on (type login &rest body)
  "Run BODY as if on a machine of `system-type' TYPE with login LOGIN."
  (declare (indent 2))
  `(let ((system-type ,type) (user-login-name ,login)) ,@body))

(ert-deftest quite-roots-mac ()
  (quite-roots-tests--on 'darwin "dag"
    (should (equal (dag/quite-roots) '("/Users/dag/projects" "~/lib")))))

(ert-deftest quite-roots-linux ()
  (quite-roots-tests--on 'gnu/linux "someone"
    (should (equal (dag/quite-roots) '("~/projects" "~/lib")))))

(ert-deftest quite-roots-linux-never-gets-the-mac-roots ()
  (quite-roots-tests--on 'gnu/linux "dag"
    (should (equal (dag/quite-roots) '("~/projects" "~/lib")))))

(ert-deftest quite-roots-unknown-host-has-none ()
  (quite-roots-tests--on 'darwin "someone"
    (should-not (dag/quite-roots)))
  (quite-roots-tests--on 'windows-nt "dag"
    (should-not (dag/quite-roots))))

(ert-deftest quite-roots-first-match-wins ()
  (let ((dag/quite-host-roots
         (list (list 'a (lambda () t) '("/a"))
               (list 'b (lambda () t) '("/b")))))
    (should (equal (dag/quite-roots) '("/a")))))

(ert-deftest quite-roots-descriptor-reads-the-host-roots ()
  (quite-roots-tests--on 'gnu/linux "someone"
    (should (equal (plist-get (dag/quite-descriptor "x" '("check.sh"))
                              :root-list)
                   '("~/projects" "~/lib")))))

(ert-deftest quite-roots-descriptor-lists-the-umbrella-worktree-after ()
  (let ((d (dag/quite-descriptor "x" '("x.el" "check.sh"))))
    (should (equal (plist-get d :project-dir) "x"))
    (should (equal (plist-get d :key-files)
                   '("x.el" "check.sh" "main/x.el" "main/check.sh")))))

(ert-deftest quite-roots-descriptor-names-another-default-worktree ()
  (should (equal (plist-get (dag/quite-descriptor "x" '("Cask") "master")
                            :key-files)
                 '("Cask" "master/Cask"))))

;;; The dotfiles descriptors, run through quite's own root search. quite is
;;; not installed under -Q, so these load it from QUITE_DIR, or else from
;;; ~/projects/quite/master or main. A spec fails when quite does not load,
;;; since a silent skip hides a broken descriptor. QUITE_DIR=none skips them.

(defconst quite-roots-tests--quite-dir
  (let ((env (getenv "QUITE_DIR")))
    (cond ((equal env "none") 'none)
          ((and env (not (equal env ""))) (expand-file-name env))
          (t (seq-find (lambda (d) (file-exists-p (expand-file-name "quite.el" d)))
                       (mapcar #'expand-file-name
                               '("~/projects/quite/master"
                                 "~/projects/quite/main"))))))
  "The quite checkout to load, `none' to skip, or nil when none was found.")

(defvar quite-roots-tests--quite-error nil
  "Why quite did not load, or nil.")

(cond ((eq quite-roots-tests--quite-dir 'none)
       (message "*** QUITE_DIR=none: SKIPPING the quite root-search specs ***"))
      ((null quite-roots-tests--quite-dir)
       (setq quite-roots-tests--quite-error
             "no quite checkout at ~/projects/quite/master or main"))
      (t
       (condition-case err
           (let ((load-path (cons quite-roots-tests--quite-dir load-path)))
             (require 'quite))
         (error
          (setq quite-roots-tests--quite-error
                (format "quite did not load from %s: %s"
                        quite-roots-tests--quite-dir
                        (error-message-string err)))))))

(defun quite-roots-tests--need-quite ()
  "Skip when QUITE_DIR is none, and fail when quite did not load."
  (when (eq quite-roots-tests--quite-dir 'none)
    (ert-skip "QUITE_DIR=none"))
  (when quite-roots-tests--quite-error
    (ert-fail (concat quite-roots-tests--quite-error
                      ". Set QUITE_DIR to a checkout, or to none to skip"))))

(ert-deftest quite-roots-overlay-descriptor-shape ()
  (let ((d (dag/quite-overlay-descriptor "pc" "emacs/config.el")))
    (should (equal (plist-get d :project-dir) "dotfiles-wt"))
    (should (equal (plist-get d :key-files)
                   '("emacs/config.el"
                     "../dotfiles-overlays/pc/emacs/config.el")))))

(defmacro quite-roots-tests--in-tree (&rest body)
  "Run BODY with `lib' bound to a scratch copy of the dotfiles layout.
The host roots name only that copy."
  (declare (indent 0))
  `(let* ((top (make-temp-file "quite-roots-tests" t))
          (lib (expand-file-name "lib" top))
          (dag/quite-host-roots (list (list 'test (lambda () t) (list lib)))))
     (unwind-protect
         (progn
           (dolist (f '("dotfiles/main/install.sh" "dotfiles/main/check.sh"
                        "dotfiles/wt/install.sh" "dotfiles/wt/emacs/x.el"
                        "dotfiles-overlays/personal-config/check.sh"
                        "dotfiles-overlays/personal-config/emacs/config.el"
                        "dotfiles-overlays/other/check.sh"
                        "dotfiles-overlays/other/emacs/other.el"
                        "dotfiles-wt/pc-x/check.sh"
                        "dotfiles-wt/pc-x/emacs/config.el"
                        "dotfiles-wt/pc-x/git/hooks/h.sh"
                        "dotfiles-wt/other-x/check.sh"
                        "dotfiles-wt/other-x/emacs/other.el"))
             (let ((path (expand-file-name f lib)))
               (make-directory (file-name-directory path) t)
               (write-region "" nil path)))
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p top (buffer-file-name b)))
           (kill-buffer b)))
       (delete-directory top t))))

(defun quite-roots-tests--build-dir (descriptor file)
  "Return the directory quite runs DESCRIPTOR's commands in.
FILE is the file the invoking buffer visits, or nil for a buffer visiting
none."
  (let ((resolve
         (lambda ()
           (let* ((keys (plist-get descriptor :key-files))
                  (root (quite-project-find-project
                         (plist-get descriptor :project-dir) nil
                         (plist-get descriptor :root-list) keys)))
             (buffer-local-value
              'default-directory
              (quite-project-find-key-files-buffer root keys))))))
    (if file
        (with-current-buffer (find-file-noselect file) (funcall resolve))
      (with-temp-buffer (funcall resolve)))))

(ert-deftest quite-roots-overlay-worktree-builds-itself ()
  (quite-roots-tests--need-quite)
  (quite-roots-tests--in-tree
    (should (equal (quite-roots-tests--build-dir
                    (dag/quite-overlay-descriptor "personal-config"
                                                  "emacs/config.el")
                    (expand-file-name "dotfiles-wt/pc-x/git/hooks/h.sh" lib))
                   (expand-file-name "dotfiles-wt/pc-x/emacs/" lib)))))

(ert-deftest quite-roots-overlay-other-worktree-builds-the-main-checkout ()
  (quite-roots-tests--need-quite)
  (quite-roots-tests--in-tree
    (let ((main (expand-file-name "dotfiles-overlays/personal-config/emacs/"
                                  lib))
          (d (dag/quite-overlay-descriptor "personal-config"
                                           "emacs/config.el")))
      (should (equal (quite-roots-tests--build-dir
                      d (expand-file-name "dotfiles-wt/other-x/emacs/other.el"
                                          lib))
                     main))
      (should (equal (quite-roots-tests--build-dir d nil) main))
      (should (equal (quite-roots-tests--build-dir
                      d (expand-file-name "dotfiles-overlays/personal-config/check.sh"
                                          lib))
                     main)))))

(ert-deftest quite-roots-overlay-ignores-a-base-worktree ()
  (quite-roots-tests--need-quite)
  (quite-roots-tests--in-tree
    (should (equal (quite-roots-tests--build-dir
                    (dag/quite-overlay-descriptor "personal-config"
                                                  "emacs/config.el")
                    (expand-file-name "dotfiles/wt/emacs/x.el" lib))
                   (expand-file-name "dotfiles-overlays/personal-config/emacs/"
                                     lib)))))

(ert-deftest quite-roots-dotfiles-base-ignores-an-overlay-worktree ()
  (quite-roots-tests--need-quite)
  (quite-roots-tests--in-tree
    (let ((d (dag/quite-descriptor "dotfiles" '("install.sh"))))
      (should (equal (quite-roots-tests--build-dir
                      d (expand-file-name "dotfiles/wt/emacs/x.el" lib))
                     (expand-file-name "dotfiles/wt/" lib)))
      (should (equal (quite-roots-tests--build-dir
                      d (expand-file-name "dotfiles-wt/pc-x/emacs/config.el"
                                          lib))
                     (expand-file-name "dotfiles/main/" lib))))))

;;; The dotfiles projects read `dag/quite-dotfiles-env' when config.el
;;; defines them.

(defun quite-roots-tests--find (form pred)
  "Return the first subform of FORM satisfying PRED, or nil."
  (cond ((funcall pred form) form)
        ((consp form) (or (quite-roots-tests--find (car form) pred)
                          (quite-roots-tests--find (cdr form) pred)))))

(defun quite-roots-tests--config-subform (pred)
  "Return the first form in config.el, at any depth, satisfying PRED."
  (with-temp-buffer
    (insert-file-contents quite-roots-tests--config)
    (goto-char (point-min))
    (catch 'found
      (condition-case nil
          (while t
            (let ((hit (quite-roots-tests--find (read (current-buffer)) pred)))
              (when hit (throw 'found hit))))
        (end-of-file (error "No matching form in config.el"))))))

(defun quite-roots-tests--project (name)
  "Return the project plist config.el gives quite for NAME."
  (eval (quite-roots-tests--config-subform
         (lambda (f) (and (eq (car-safe f) 'list)
                          (equal (plist-get (cdr f) :name) name))))
        t))

(defun quite-roots-tests--load-env ()
  "Load quite, then `dag/quite-dotfiles-env' from config.el."
  (quite-roots-tests--need-quite)
  (quite-roots-tests--load 'defvar 'dag/quite-dotfiles-env))

(defun quite-roots-tests--line (name command)
  "Return the line NAME's COMMAND runs, with NAME defined now."
  (let* ((project (quite-roots-tests--project name))
         (cmd (seq-find (lambda (c) (equal (plist-get c :command) command))
                        (plist-get project :commands)))
         (build (quite-build-command (plist-get project :build-architecture)
                                     cmd project))
         line)
    (cl-letf (((symbol-function 'compile) (lambda (l) (setq line l))))
      (funcall build nil nil nil nil nil))
    line))

(ert-deftest quite-roots-dotfiles-env-defaults-empty ()
  (quite-roots-tests--load-env)
  (let ((dag/quite-dotfiles-env ""))
    (should (equal (quite-roots-tests--line "dotfiles" "check")
                   "./check.sh test"))
    (should (equal (quite-roots-tests--line "personal-config" "build")
                   "top=$(git rev-parse --show-toplevel) && cd \"$top\" && ./check.sh build"))))

(ert-deftest quite-roots-dotfiles-env-leads-both-lines ()
  (quite-roots-tests--load-env)
  (let ((dag/quite-dotfiles-env "export A=b;"))
    (should (equal (quite-roots-tests--line "dotfiles" "check")
                   "export A=b; ./check.sh test"))
    (should (equal (quite-roots-tests--line "personal-config" "check")
                   "export A=b; top=$(git rev-parse --show-toplevel) && cd \"$top\" && ./check.sh test"))))

;;; quite-roots-tests.el ends here
