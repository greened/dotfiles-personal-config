;;; release-tests.el --- Tests for the release helpers in config.el  -*- lexical-binding: t; -*-

;; config.el is a configuration, not a package, and loading it needs gaffer
;; and the rest of the setup. So these tests read only the named defuns and
;; defvars out of it and evaluate those.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst release-tests--config
  (expand-file-name "../config.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun release-tests--load (name)
  "Evaluate the top-level defun or defvar NAME from config.el."
  (with-temp-buffer
    (insert-file-contents release-tests--config)
    (goto-char (point-min))
    (catch 'found
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (memq (car-safe form) '(defun defvar))
                         (eq (cadr form) name))
                (throw 'found (eval form t)))))
        (end-of-file (error "No defun or defvar %s in config.el" name))))))

(dolist (name '(dag/release--changelog-top
                dag/release--changelog-refusal
                dag/release--child-env
                dag/release--git!
                dag/release--bump
                dag/release--pass
                dag/release--step
                dag/release--existing-tag
                dag/release--undo
                dag/release--version-p
                dag/release-pypi
                dag/gaffer-release-pypi))
  (release-tests--load name))

(defconst release-tests--changelog "\
ChangeLog
=========
`Unreleased`_
-------------

`0.0.41`_ - 2026-10-06
----------------------
Removed
.......
- Something.

`0.0.40`_ - 2026-10-05
----------------------
")

(ert-deftest release-changelog-top-reads-the-first-release ()
  (should (equal (dag/release--changelog-top release-tests--changelog)
                 '("0.0.41" . "2026-10-06"))))

(ert-deftest release-changelog-top-skips-unreleased ()
  (should (equal (dag/release--changelog-top
                  "`Unreleased`_\n-----\n\n`1.2.3`_ - 2026-01-02\n")
                 '("1.2.3" . "2026-01-02"))))

(ert-deftest release-changelog-top-needs-a-date ()
  (should-not (dag/release--changelog-top "`Unreleased`_\n`1.2.3`_\n")))

(ert-deftest release-changelog-top-ignores-a-mention-mid-line ()
  (should-not (dag/release--changelog-top
               "- see `0.0.1`_ - 2026-01-02 for the old one\n")))

(ert-deftest release-changelog-top-empty ()
  (should-not (dag/release--changelog-top "")))

(ert-deftest release-changelog-refusal-passes-this-version-today ()
  (should-not (dag/release--changelog-refusal
               (cons 0 release-tests--changelog) "0.0.41" "2026-10-06"
               "/clone/")))

(ert-deftest release-changelog-refusal-wrong-version ()
  (should (string-match-p "heads 0.0.41 - 2026-10-06, not 0.0.42"
                          (dag/release--changelog-refusal
                           (cons 0 release-tests--changelog)
                           "0.0.42" "2026-10-06" "/clone/"))))

(ert-deftest release-changelog-refusal-stale-date ()
  (should (string-match-p "not 0.0.41 - 2026-10-07"
                          (dag/release--changelog-refusal
                           (cons 0 release-tests--changelog)
                           "0.0.41" "2026-10-07" "/clone/"))))

(ert-deftest release-changelog-refusal-no-heading ()
  (should (string-match-p "heads no release"
                          (dag/release--changelog-refusal
                           (cons 0 "`Unreleased`_\n") "0.0.41" "2026-10-06"
                           "/clone/"))))

(ert-deftest release-changelog-refusal-missing-file ()
  (should (string-match-p "cannot read docs/changelog.rst: fatal"
                          (dag/release--changelog-refusal
                           (cons 128 "fatal: path does not exist")
                           "0.0.41" "2026-10-06" "/clone/"))))

(ert-deftest release-changelog-refusal-undated-names-changelog-py ()
  (should (string-match-p
           "Run \\./changelog\\.py --version 0\\.0\\.42 in /clone/, land it"
           (dag/release--changelog-refusal
            (cons 0 release-tests--changelog) "0.0.42" "2026-10-06"
            "/clone/"))))

;; changelog.py refuses a version the file already has, so it is not the fix.
(ert-deftest release-changelog-refusal-stale-date-asks-for-a-redate ()
  (let ((why (dag/release--changelog-refusal
              (cons 0 release-tests--changelog) "0.0.41" "2026-10-07"
              "/clone/")))
    (should (string-match-p "Redate the 0\\.0\\.41 heading in /clone/" why))
    (should-not (string-match-p "changelog\\.py" why))))

;;; Tests dag/release-pypi against a fake clone. Every git, uv and pass call
;;; goes to a stub, so no real command runs and no real token is read.

(defvar gaffer-repo-release-strategies)
(defvar gaffer-release-tag-pattern)
(defvar gaffer--hosts-down)

;; Built at load time so the token is never in this file. ERT visits the file
;; after a failure, and the token test would then find it in a buffer.
(defconst release-tests--token (concat "fake-token-" "for-the-release-tests"))
(defconst release-tests--sha "0123456789abcdef0123456789abcdef01234567")

(defvar release-tests--calls nil
  "Every stubbed call, newest first.")
(defvar release-tests--prompts nil
  "The default each tag prompt offered, newest first.")
(defvar release-tests--last-tag "v0.1.1"
  "What describe finds, or nil for a clone where describe fails.")
(defvar release-tests--tags ""
  "What a bare `tag --list' prints.")
(defvar release-tests--publish-status 0)
(defvar release-tests--push-status 0)
(defvar release-tests--remote-sha release-tests--sha
  "What origin/master resolves to.")
(defvar release-tests--ancestor-status 0
  "The exit status of `merge-base --is-ancestor'.")

(defun release-tests--git (&rest args)
  "Answer git ARGS as a clone at `release-tests--remote-sha'.
Its last tag is `release-tests--last-tag' and its changelog heads 0.1.2
dated today."
  (push (cons 'git args) release-tests--calls)
  (pcase args
    (`("rev-parse" "--git-dir") '(0 . ".git"))
    (`("rev-parse" "HEAD") (cons 0 release-tests--sha))
    (`("rev-parse" "origin/master") (cons 0 release-tests--remote-sha))
    (`("merge-base" "--is-ancestor" . ,_)
     (cons release-tests--ancestor-status ""))
    (`("rev-parse" "--verify" "--quiet" ,rev)
     (let ((short (string-remove-suffix "^{commit}" rev)))
       (if (and (>= (length short) 7)
                (string-prefix-p short release-tests--sha))
           (cons 0 release-tests--sha)
         '(1 . ""))))
    (`("describe" . ,_)
     (if release-tests--last-tag
         (cons 0 release-tests--last-tag)
       '(128 . "fatal: No names found, cannot describe anything.")))
    (`("rev-list" . ,_) '(0 . "2"))
    (`("show" . ,_)
     (cons 0 (format "`Unreleased`_\n-----\n\n`0.1.2`_ - %s\n"
                     (format-time-string "%F"))))
    (`("tag" "--list") (cons 0 release-tests--tags))
    (`("tag" "--list" . ,_) '(0 . ""))
    (`("push" . ,_) (cons release-tests--push-status "rejected"))
    (`("worktree" "remove" "--force" ,dir)
     (delete-directory dir t)
     '(0 . ""))
    (`(,(or "status" "fetch" "merge-base" "check-ref-format" "tag" "worktree")
       . ,_)
     '(0 . ""))
    (_ (error "Unexpected git %S" args))))

(defun release-tests--run (buffer program &rest args)
  "Answer PROGRAM ARGS for pass and uv, logging the child environment.
The pass answer goes into BUFFER."
  (push (list 'run program args dag/release--child-env) release-tests--calls)
  (pcase (cons program args)
    (`("pass" "show" ,_)
     (with-current-buffer buffer
       (insert release-tests--token "\n"))
     0)
    (`("uv" "build")
     (make-directory "dist" t)
     (let ((jka-compr-inhibit t))
       (dolist (file '("pkg-0.1.2-py3-none-any.whl" "pkg-0.1.2.tar.gz"))
         (write-region "" nil (expand-file-name file "dist") nil 'silent)))
     0)
    (`("uv" "publish" . ,_) release-tests--publish-status)
    (_ (error "Unexpected run %s %S" program args))))

(defmacro release-tests--with-clone (&rest body)
  "Run BODY with every external call of `dag/release-pypi' stubbed."
  (declare (indent 0))
  `(let ((release-tests--calls nil)
         (release-tests--prompts nil)
         (gaffer-repo-release-strategies '(("greened/pkg" . pypi)))
         (gaffer-release-tag-pattern "v*")
         (gaffer--hosts-down (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'dag/release--git) #'release-tests--git)
               ((symbol-function 'dag/release--run) #'release-tests--run)
               ((symbol-function 'gaffer--repo-path)
                (lambda (_repo) temporary-file-directory))
               ((symbol-function 'executable-find)
                (lambda (&rest _) "/usr/bin/uv"))
               ((symbol-function 'read-string)
                (lambda (_prompt default &rest _)
                  (push default release-tests--prompts)
                  default))
               ((symbol-function 'y-or-n-p)
                (lambda (prompt) (error "Unexpected question %s" prompt))))
       ,@body)))

(defun release-tests--log ()
  "The stubbed calls, oldest first."
  (reverse release-tests--calls))

(defun release-tests--git-args ()
  "The argument list of every git call, oldest first."
  (mapcar #'cdr (seq-filter (lambda (c) (eq (car c) 'git))
                            (release-tests--log))))

(defun release-tests--runs ()
  "Each run as (PROGRAM ARGS ENV), oldest first."
  (mapcar #'cdr (seq-filter (lambda (c) (eq (car c) 'run))
                            (release-tests--log))))

(defun release-tests--publish-p (call)
  "Return non-nil when logged CALL is the uv publish."
  (and (eq (car call) 'run) (equal (nth 1 call) "uv")
       (equal (car (nth 2 call)) "publish")))

(ert-deftest release-pypi-tags-then-uploads-then-pushes ()
  (release-tests--with-clone
    (should (equal (dag/release-pypi "greened/pkg" nil "0123456") "v0.1.2"))
    (let* ((log (release-tests--log))
           (tag (cl-position (list 'git "tag" "v0.1.2" release-tests--sha)
                             log :test #'equal))
           (upload (cl-position-if #'release-tests--publish-p log))
           (push (cl-position '(git "push" "origin" "v0.1.2") log
                              :test #'equal)))
      (should (and tag upload push))
      (should (< tag upload push)))))

(ert-deftest release-pypi-token-only-in-the-publish-environment ()
  (release-tests--with-clone
    (dag/release-pypi "greened/pkg" nil "0123456")
    (let ((leaks (lambda (args)
                   (seq-some (lambda (a)
                               (string-search release-tests--token a))
                             args))))
      (should-not (seq-some leaks (release-tests--git-args)))
      (dolist (run (release-tests--runs))
        (should-not (funcall leaks (nth 1 run)))
        (should (equal (nth 2 run)
                       (and (equal (nth 0 run) "uv")
                            (equal (car (nth 1 run)) "publish")
                            (list (concat "UV_PUBLISH_TOKEN="
                                          release-tests--token))))))
      (should (seq-some (lambda (run) (nth 2 run)) (release-tests--runs))))
    ;; The pass buffer is killed, so no live buffer holds the token.
    (should-not (seq-some (lambda (b)
                            (with-current-buffer b
                              (string-search release-tests--token
                                             (buffer-string))))
                          (buffer-list)))))

(ert-deftest release-pypi-failed-upload-deletes-the-tag ()
  (release-tests--with-clone
    (let* ((release-tests--publish-status 1)
           (err (should-error (dag/release-pypi "greened/pkg" nil "0123456"))))
      (should-not (string-search release-tests--token
                                 (error-message-string err)))
      (should (member '("tag" "-d" "v0.1.2") (release-tests--git-args)))
      (should-not (assoc "push" (release-tests--git-args))))))

(ert-deftest release-pypi-failed-push-keeps-the-tag ()
  (release-tests--with-clone
    (let ((release-tests--push-status 1))
      (should-error (dag/release-pypi "greened/pkg" nil "0123456"))
      (should (cl-some #'release-tests--publish-p (release-tests--log)))
      (should-not (member '("tag" "-d" "v0.1.2") (release-tests--git-args))))))

(ert-deftest release-pypi-prompt-bumps-the-last-tag ()
  (release-tests--with-clone
    (dag/release-pypi "greened/pkg" nil "0123456")
    (should (equal release-tests--prompts '("v0.1.2")))
    (should (member (list "rev-list" "--count"
                          (concat "v0.1.1.." release-tests--sha))
                    (release-tests--git-args)))))

;; The answer is the changelog's version, so the rest of the release runs.
(ert-deftest release-pypi-prompt-seeds-a-repo-with-no-tags ()
  (release-tests--with-clone
    (let ((release-tests--last-tag nil)
          (asked nil))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt default &rest _)
                   (push (cons prompt default) asked)
                   "v0.1.2")))
        (should (equal (dag/release-pypi "greened/pkg" nil "0123456")
                       "v0.1.2")))
      (should (equal (mapcar #'cdr asked) '("v0.1.0")))
      (should (string-match-p "(2 commits, no earlier tag, 2 stay parked)"
                              (car (car asked))))
      (should (member (list "rev-list" "--count" release-tests--sha)
                      (release-tests--git-args))))))

(ert-deftest release-pypi-describe-failure-with-tags-still-refuses ()
  (release-tests--with-clone
    (let ((release-tests--last-tag nil)
          (release-tests--tags "v0.1.1"))
      (should (string-match-p
               "git describe finds none"
               (error-message-string
                (should-error (dag/release-pypi "greened/pkg" nil "0123456")))))
      (should-not release-tests--prompts))))

;; An older last tag makes the bump differ from the given version, so the
;; test can tell which one the prompt offered.
(ert-deftest release-pypi-prompt-offers-the-given-version ()
  (dolist (version '("v0.1.2" "0.1.2"))
    (release-tests--with-clone
      (let ((release-tests--last-tag "v0.0.9"))
        (dag/release-pypi "greened/pkg" version "0123456")
        (should (equal (list version release-tests--prompts)
                       (list version '("v0.1.2"))))))))

(ert-deftest release-pypi-refuses-before-any-git-call ()
  (pcase-dolist (`(,repo ,commit) '(("greened/other" "0123456")
                                    ("greened/pkg" "--all")
                                    ("greened/pkg" "")
                                    ("greened/pkg" nil)))
    (release-tests--with-clone
      (should-error (dag/release-pypi repo nil commit))
      (should (equal (list repo commit release-tests--calls)
                     (list repo commit nil))))))

(ert-deftest release-pypi-refuses-an-unknown-commit-before-tagging ()
  (release-tests--with-clone
    (let ((err (should-error (dag/release-pypi "greened/pkg" nil "fedcba9"))))
      (should (string-match-p "has no commit fedcba9"
                              (error-message-string err)))
      (should-not (assoc "tag" (release-tests--git-args)))
      (should-not release-tests--prompts)
      (should-not (release-tests--runs)))))

(ert-deftest release-pypi-refuses-a-clone-behind-origin-before-tagging ()
  (release-tests--with-clone
    (let* ((release-tests--remote-sha "fedcba9876543210fedcba9876543210fedcba98")
           (err (should-error (dag/release-pypi "greened/pkg" nil "0123456"))))
      (should (string-match-p "is not at origin/master"
                              (error-message-string err)))
      (should-not (assoc "tag" (release-tests--git-args)))
      (should-not release-tests--prompts)
      (should-not (release-tests--runs)))))

(ert-deftest release-pypi-refuses-a-commit-off-the-head-before-tagging ()
  (release-tests--with-clone
    (let* ((release-tests--ancestor-status 1)
           (err (should-error (dag/release-pypi "greened/pkg" nil "0123456"))))
      (should (string-match-p "is not an ancestor of the head"
                              (error-message-string err)))
      (should-not (assoc "tag" (release-tests--git-args)))
      (should-not release-tests--prompts)
      (should-not (release-tests--runs)))))

(defmacro release-tests--with-handler (&rest body)
  "Run BODY with gaffer's item accessors stubbed over plists.
Calls to `dag/release-pypi' are logged in `release-tests--calls'."
  (declare (indent 0))
  `(let ((release-tests--calls nil))
     (cl-letf (((symbol-function 'gaffer-item-repo)
                (lambda (item) (plist-get item :repo)))
               ((symbol-function 'gaffer--release-sha)
                (lambda (item) (plist-get item :sha)))
               ((symbol-function 'dag/release-pypi)
                (lambda (&rest args) (push args release-tests--calls) "v0.1.2")))
       ,@body)))

(ert-deftest release-handler-cuts-at-the-item-commit ()
  (release-tests--with-handler
    (should (equal (dag/gaffer-release-pypi
                    (list :repo "greened/pkg" :sha release-tests--sha) 'pypi)
                   "v0.1.2"))
    (should (equal release-tests--calls
                   (list (list "greened/pkg" nil release-tests--sha))))))

(ert-deftest release-handler-refuses-another-strategy ()
  (release-tests--with-handler
    (should-error (dag/gaffer-release-pypi
                   (list :repo "greened/pkg" :sha release-tests--sha) 'other))
    (should-not release-tests--calls)))

(ert-deftest release-handler-refuses-an-item-with-no-landed-commit ()
  (release-tests--with-handler
    (should-error (dag/gaffer-release-pypi (list :repo "greened/pkg") 'pypi))
    (should-not release-tests--calls)))

;;; release-tests.el ends here
