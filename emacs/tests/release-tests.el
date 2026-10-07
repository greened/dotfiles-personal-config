;;; release-tests.el --- Tests for the release helpers in config.el  -*- lexical-binding: t; -*-

;; config.el is a configuration, not a package, and loading it needs gaffer
;; and the rest of the setup. So these tests read only the named defuns out of
;; it and evaluate those.

(require 'ert)

(defconst release-tests--config
  (expand-file-name "../config.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun release-tests--load-defun (name)
  "Evaluate the top-level defun NAME from config.el."
  (with-temp-buffer
    (insert-file-contents release-tests--config)
    (goto-char (point-min))
    (catch 'found
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) 'defun) (eq (cadr form) name))
                (throw 'found (eval form t)))))
        (end-of-file (error "No defun %s in config.el" name))))))

(release-tests--load-defun 'dag/release--changelog-top)
(release-tests--load-defun 'dag/release--changelog-refusal)

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
               (cons 0 release-tests--changelog) "0.0.41" "2026-10-06")))

(ert-deftest release-changelog-refusal-wrong-version ()
  (should (string-match-p "heads 0.0.41 - 2026-10-06, not 0.0.42"
                          (dag/release--changelog-refusal
                           (cons 0 release-tests--changelog)
                           "0.0.42" "2026-10-06"))))

(ert-deftest release-changelog-refusal-stale-date ()
  (should (string-match-p "not 0.0.41 - 2026-10-07"
                          (dag/release--changelog-refusal
                           (cons 0 release-tests--changelog)
                           "0.0.41" "2026-10-07"))))

(ert-deftest release-changelog-refusal-no-heading ()
  (should (string-match-p "heads no release"
                          (dag/release--changelog-refusal
                           (cons 0 "`Unreleased`_\n") "0.0.41" "2026-10-06"))))

(ert-deftest release-changelog-refusal-missing-file ()
  (should (string-match-p "cannot read docs/changelog.rst: fatal"
                          (dag/release--changelog-refusal
                           (cons 128 "fatal: path does not exist")
                           "0.0.41" "2026-10-06"))))

;;; release-tests.el ends here
