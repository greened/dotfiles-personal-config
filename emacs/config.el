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

  ;; Prefixes: list order is the C-u dispatch index (release = no prefix,
  ;; debug = one C-u).
  (setq mirv-prefix-plist-list '("release" "debug"))

  (setq mirv-transform-plist-list '((:name "clang" :func identity)
				    (:name "gcc" :func upcase)))

  (setq mirv-project-dir "mirv-project")
  (setq mirv-root-list '("/home/dag/src"))

  (setq mirv-project-descriptor
	`(:project-dir ,mirv-project-dir
		       :root-list ,mirv-root-list
		       :key-files ("repositories.manifest")))

  (setq mirv-hydra-heads
        (quite-define-project
         (list :git-name git-mirv-name :name "mirv"
               :descriptor mirv-project-descriptor :prefix-key "M" :target "all"
               :commands command-plist-list :prefixes mirv-prefix-plist-list
               :transforms mirv-transform-plist-list
               :command-prefix "/bin/bash -c '. /usr/share/virtualenvwrapper/virtualenvwrapper.sh; workon mirv;"
               :command-postfix "-- --force'")))

  (setq mirv-build-hydra-heads (append mirv-hydra-heads))

  ;; Create build hydra.
  (eval `(defhydra mirv-hydra-build (:color blue :hint nil)
	   ,@(append
	      mirv-build-hydra-heads)))

  (define-key quite-command-map (kbd "Mh")
		   (lambda () (interactive) (mirv-hydra-build/body))))


(with-eval-after-load 'quite
  ;; Every one of these is a shell project: quite runs the command's
  ;; :shell-command and nothing else.  They have a single build flavor, so none
  ;; declares :prefixes or :transforms -- the lone flavor is named by :target
  ;; and there are no C-u variants.  Two commands each, deliberately: `build'
  ;; and `check' are the verbs gaffer drives (`quite-run-repo' looks them up by
  ;; :command), and for a repo whose whole check is one script they are the same
  ;; script.
  (dolist (p '(("gaffer"          "f" ("gaffer.el" "check.sh"))
               ("prevue"          "v" ("prevue.el" "check.sh"))
               ("gazette"         "z" ("gazette.el" "check.sh"))
               ("quarry"          "q" ("quarry.el" "check.sh"))
               ("slack-attention" "a" ("check.sh"))))
    (let ((name (nth 0 p)) (key (nth 1 p)) (files (nth 2 p)))
      (quite-define-project
       (list :name name
             :build-architecture 'shell
             :descriptor (list :project-dir name
                               :root-list '("/Users/dag/projects")
                               :key-files files)
             :prefix-key key
             :target name
             :commands '((:name "build" :command "build" :key "b"
                                :shell-command "./check.sh")
                         (:name "check" :command "check" :key "k"
                                :shell-command "./check.sh"))))
      (quite-register-repo (concat "greened/" name)
                           :project name
                           :build-target name
                           :test-target name)))

  ;; quite builds with Cask and a Makefile rather than a ./check.sh, and cask
  ;; lives under ~/.cask on the build host, so it needs its own commands.
  ;; `make deps' populates the Cask sandbox in a fresh worktree first.
  (quite-define-project
   (list :name "quite"
         :build-architecture 'shell
         :descriptor '(:project-dir "quite"
                       :root-list ("/Users/dag/projects")
                       :key-files ("quite.el" "Cask"))
         :prefix-key "t"
         :target "quite"
         :commands '((:name "build" :command "build" :key "b"
                            :shell-command "PATH=$HOME/.cask/bin:$PATH make deps compile")
                     (:name "check" :command "check" :key "k"
                            :shell-command "PATH=$HOME/.cask/bin:$PATH make test"))))
  (quite-register-repo "greened/quite"
                       :project "quite" :build-target "quite" :test-target "quite")

  ;; The Python packages build with hatch.  Building the distribution is
  ;; deliberately NOT the build verb: it writes dist/ into the worktree, and
  ;; those artifacts are untracked, so they would surface as noise in every
  ;; later worktree review.  Creating the environment is idempotent, leaves
  ;; nothing behind, and still fails when the environment cannot be built --
  ;; which is what a build gate is for.
  (dolist (p '(("git-project" "j") ("git-project-core-plugins" "P")))
    (let ((name (nth 0 p)) (key (nth 1 p)))
      (quite-define-project
       (list :name name
             :build-architecture 'shell
             :descriptor (list :project-dir name
                               :root-list '("/Users/dag/projects")
                               :key-files '("pyproject.toml"))
             :prefix-key key
             :target name
             :commands '((:name "build" :command "build" :key "b"
                                :shell-command "hatch env create")
                         (:name "check" :command "check" :key "k"
                                :shell-command "hatch run test"))))
      (quite-register-repo (concat "greened/" name)
                           :project name
                           :build-target name
                           :test-target name))))

;;; gaffer: how my personal repos publish.  Every one of them is a quite
;;; project (the block above), so none needs a `gaffer-repo-build-backends'
;;; override any more -- gaffer's global `quite' backend, which the work overlay
;;; pins, now reaches them through quite itself.  One mechanism per repo.
;;;
;;; What they DO need is a publish strategy.  Without one the default resolution
;;; reaches its last clause -- no PR number, not listed here, branch is not the
;;; default branch -- and picks `open-pr', which would open a pull request on
;;; repos that have never had one.  They all land the same way: fast-forward the
;;; default branch.

;;; The dotfiles repos land the same way, and are listed here for the same
;;; reason: without an entry the default resolution sees a dev branch that is
;;; not the default branch and picks `open-pr', which would open a pull request
;;; on repos that have never had one.  The work overlay adds its own, since
;;; naming it here would put the employer in a public repo.
(with-eval-after-load 'gaffer
  (dolist (repo '("greened/gaffer" "greened/prevue" "greened/gazette"
                  "greened/quarry" "greened/slack-attention" "greened/quite"
                  "greened/git-project" "greened/git-project-core-plugins"
                  "greened/dotfiles-public" "greened/dotfiles-personal-config"
                  "greened/dotfiles-personal-secret"))
    (setf (alist-get repo gaffer-repo-publish-strategies nil nil #'equal)
          'ff-merge)))

;;; Build and test the dotfiles repos with their own scripts rather than the
;;; fleet-wide backend, which is a build tool that has never heard of them.
;;;
;;; Wired because a repo with no build backend can NEVER satisfy the `built'
;;; gate: gaffer requires the `:build-ok' artifact to be PRESENT, an absent one
;;; reads as unverified, and leaving the stage then takes a human override every
;;; single time.  A routine override is how a gate stops meaning anything, and
;;; there is real work to check here -- byte-compiling the local packages caught
;;; a live error the tests missed.
;;;
;;; The two overlays that genuinely have nothing to build are still stuck, since
;;; there is no way to declare that; see the per-repo-stage-configuration todo.
(with-eval-after-load 'gaffer
  (setf (alist-get "greened/dotfiles-public" gaffer-repo-build-backends
                   nil nil #'equal)
        '(:build-backend shell :build-command "./check.sh build"
          :test-backend  shell :test-command  "./check.sh test"))
  ;; This repo has no elisp of its own to compile -- its content is the git hook
  ;; chain -- so only the test half is real work.  The selftest covers the
  ;; scrub's shape rules and its literal-term builder.
  ;;
  ;; The build command is a deliberate stand-in, and states as much when it
  ;; runs.  An ABSENT `:build-backend' would fall back to the fleet-wide one,
  ;; which is a build tool that knows nothing about this repo, so the choice is
  ;; not between this and nothing -- it is between saying "nothing to build" out
  ;; loud and running something meaningless.  Replace it with a declared
  ;; no-build once gaffer can express one.
  (setf (alist-get "greened/dotfiles-personal-config" gaffer-repo-build-backends
                   nil nil #'equal)
        '(:build-backend shell
          :build-command "echo 'nothing to build: hook scripts and config only'"
          :test-backend  shell
          :test-command  "git/hooks/scrub-selftest.sh")))

;;; Calendars for the agenda.  The package is declared in the public base; what
;;; belongs here is which calendars to read.
;;;
;;; The address is a `pass' entry read through a lambda rather than a string,
;;; per the token-provider pattern the other packages use: a Google secret
;;; calendar address is a credential -- it grants read access to the whole
;;; calendar to anyone holding it -- so it must not sit in a repo, public or
;;; not.  The lambda defers the lookup to fetch time, so a rotated address is
;;; picked up without restarting Emacs.
;;;
;;; The work calendar is not here.  It goes in the work overlay once it has a
;;; published iCalendar address, and joins this same alist.

(with-eval-after-load 'agenda-feeds
  (setq agenda-feeds-calendars
        (list (cons 'personal
                    (lambda ()
                      (auth-source-pass-get
                       'secret
                       "calendar.google.com/greened.obbligato.org/ics-url"))))))

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
