;; -*- lexical-binding: t -*-
;;
;; Personal (non-sensitive) overlay.  Loaded after the public base config.
;; Holds personal-but-shareable configuration: my own C style, the MIRV
;; project build hydra, and the LLVM / C++ standards mailing-list saved
;; searches.  Nothing here is sensitive or identity-bearing; that lives in
;; the private (secret) overlay.

;;; org-jira: install the package generically.  Employer-specific
;;; configuration (Jira URL, JQL, store-link advice) lives in a private
;;; overlay via `with-eval-after-load'.

(use-package org-jira
  :ensure t
  :requires (org)
  :config
  (require 'org-jira))

;;; cc-mode: my personal C style and its guesser entries.

(with-eval-after-load 'cc-styles
  (defconst my-c-style
    '((c-tab-always-indent        . t)
      (c-comment-only-line-offset . 4)
      (c-basic-offset . 2)
      (c-hanging-braces-alist . ((brace-list-open after)
				 (brace-entry-open after)
				 (class-open after)
				 (inline-open after)
				 (statement-cont)
				 (substatement-open after)
				 (block-open after)
				 (block-close . c-snug-do-while)
				 (statement-case-open after)
				 (substatement-open after)
				 (namespace-open after)
				 (extern-lang-open after)
				 (inexpr-class-open after)
				 (inexpr-class-close before)))
      (c-hanging-colons-alist . ((case-label after)
				 (access-label after)
				 (label after)
				 (member-init-intro before)
				 (inher-intro before)))
      (c-cleanup-list . (empty-defun-braces
			 defun-close-semi
			 list-close-comma
			 compact-empty-funcall
			 scope-operator))
      (c-offsets-alist . ((string . -1000)
			  (c . c-lineup-C-comments)
			  (defun-open . 0)
			  (defun-close . 0)
			  (defun-block-intro . +)
			  (class-open . 0)
			  (class-close . 0)
			  (inline-open . 0)
			  (inline-close . 0)
			  (func-decl-cont . +)
			  (knr-argdecl-intro . +)
			  (knr-argdecl . 0)
			  (topmost-intro . 0)
			  (topmost-intro-cont . 0)
			  (member-init-intro . ++)
			  (member-init-cont . +)
			  (inher-intro . ++)
			  (inher-cont . +)
			  (block-open . 0)
			  (block-close . 0)
			  (brace-list-open . 0)
			  (brace-list-close . 0)
			  (brace-list-intro . +)
			  (brace-list-entry . 0)
			  (brace-entry-open . +)
			  (statement . 0)
			  (statement-cont . +)
			  (statement-block-intro . +)
			  (statement-case-intro . +)
			  (statement-case-open . 0)
			  (substatement . +)
			  (substatement-open . 0)
			  (case-label . 0)
			  (access-label . -)
			  (label . -1000)
			  (do-while-closure . 0)
			  (else-clause . 0)
			  (catch-clause . 0)
			  (comment-intro . 0)
			  (arglist-intro . +)
			  (arglist-cont . 0)
			  (arglist-cont-nonempty . c-lineup-arglist)
			  (arglist-close . c-lineup-close-paren)
			  (stream-op . +)
			  (inclass . +)
			  (cpp-macro . -1000)
			  (cpp-macro-cont . 0)
			  (friend . 0)
			  (objc-method-intro . +)
			  (objc-method-args-cont . 0)
			  (objc-method-call-cont . +)
			  (extern-lang-open . 0)
			  (extern-lang-close . 0)
			  (inextern-lang . +)
			  (namespace-open . 0)
			  (namespace-close . 0)
			  (innamespace . +)
			  (module-open . 0)
			  (module-close . 0)
			  (inmodule . +)
			  (composition-open . 0)
			  (composition-close . 0)
			  (incomposition . +)
			  (template-args-cont . +)
			  (inlambda . +)
			  (lambda-intro-cont . +)
			  (inexpr-statement . +)
			  (inexpr-class . +))))
    "My personal C Style")
  (c-add-style "my-c-style" my-c-style)

  ;; MIRV (personal project) C style, inheriting my-c-style.
  (defconst mirv-c-style
    '("my-c-style")
    "MIRV C Style")
  (c-add-style "mirv-c-style" mirv-c-style))

(with-eval-after-load 'cc-mode
  (add-to-list 'my-c-styles-alist
	       '(".*/.*mirv/.*\\.[ch]$" . "mirv-c-style")))

;;; quite: MIRV build hydra.

(with-eval-after-load 'quite
  (setq git-mirv-name "mirv")

  (setq mirv-prefix-plist-list '((:name "release" :prefix 0)
				 (:name "debug" :prefix 1)))

  (setq mirv-transform-plist-list '((:name "clang" :func identity)
				    (:name "gcc" :func upcase)))

  (setq mirv-project-dir "mirv-project")
  (setq mirv-root-list '("/home/dag/src"))

  (setq mirv-project-descriptor
	`(:project-dir ,mirv-project-dir
		       :root-list ,mirv-root-list
		       :key-files ("repositories.manifest")))

  (setq mirv-hydra-heads (compose-project git-mirv-name
					  "mirv"
					  mirv-project-descriptor
					  "M"
					  "all"
					  command-plist-list
					  mirv-prefix-plist-list
					  mirv-transform-plist-list
					  "/bin/bash -c '. /usr/share/virtualenvwrapper/virtualenvwrapper.sh; workon mirv;"
					  "-- --force'"))

  (setq mirv-build-hydra-heads (append mirv-hydra-heads))

  ;; Create build hydra.
  (eval `(defhydra mirv-hydra-build (:color blue :hint nil)
	   ,@(append
	      mirv-build-hydra-heads)))

  (global-set-key  (kbd "C-c ph")
		   (lambda () (interactive) (mirv-hydra-build/body))))

;;; Notmuch: LLVM project and C++ standards mailing-list saved searches.

(with-eval-after-load 'notmuch
  (my-notmuch-add-search "llvm-feedback" "f" "tag:llvm-feedback and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-iropt" "I" "tag:llvm-ir-opt and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-infrastructure" "F" "tag:llvm-infrastructure and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-beginners" "b" "tag:llvm-beginners and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-jobs" "j" "tag:llvm-jobs and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-announce" "a" "tag:llvm-announce and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-codegen" "g" "tag:llvm-codegen and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-community" "g" "tag:llvm-community and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-project" "g" "tag:llvm-project and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-github" "g" "tag:llvm-github and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-dev" "l" "tag:llvm-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-commits" "L" "tag:llvm-commits and not tag:deleted and not tag:trash" 'unthreaded)
  (my-notmuch-add-search "cfe-dev" "c" "tag:cfe-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "cfe-commits" "C" "tag:cfe-commits and not tag:deleted and not tag:trash" 'unthreaded)
  (my-notmuch-add-search "flang-dev" "F" "tag:flang-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "libcxx-dev" "x" "tag:libcxx-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "lldb-dev" "B" "tag:lldb-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "openmp-dev" "o" "tag:openmp-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "mlir-dev" "c" "tag:mlir-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "std-proposals" "P" "tag:std-proposals and tag:unread and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "std-discussion" "d" "tag:std-discussion and tag:unread and not tag:deleted and not tag:trash" 'tree))
