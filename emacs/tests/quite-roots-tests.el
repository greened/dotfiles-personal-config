;;; quite-roots-tests.el --- Tests for the per-host quite roots in config.el  -*- lexical-binding: t; -*-

;; config.el is a configuration, not a package, and loading it needs quite and
;; the rest of the setup. So these tests read only the named forms out of it
;; and evaluate those.

(require 'ert)
(require 'seq)

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

(defmacro quite-roots-tests--on (type login &rest body)
  "Run BODY as if on a machine of `system-type' TYPE with login LOGIN."
  (declare (indent 2))
  `(let ((system-type ,type) (user-login-name ,login)) ,@body))

(ert-deftest quite-roots-mac ()
  (quite-roots-tests--on 'darwin "dag"
    (should (equal (dag/quite-roots) '("/Users/dag/projects")))))

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

;;; quite-roots-tests.el ends here
